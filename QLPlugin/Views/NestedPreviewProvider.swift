import AVKit
import Cocoa
import GlanceKit
import QuickLookUI
import UniformTypeIdentifiers

enum NestedPreviewError: LocalizedError {
	case missingFileURL(name: String)
	case nativePreviewUnavailable(name: String)
	case nonNavigableItem(name: String)

	var errorDescription: String? {
		switch self {
			case let .missingFileURL(name):
				"No source URL is available for \(name)"
			case let .nativePreviewUnavailable(name):
				"The native preview for \(name) is unavailable"
			case let .nonNavigableItem(name):
				"\(name) cannot be previewed from this folder"
		}
	}
}

enum NestedPreviewRoute {
	case glance(Preview.Type)
	case media
	case native
}

@MainActor
protocol NestedPreviewProviding {
	func makePreviewController(for node: FileTreeNode) async throws -> PreviewVC
}

@MainActor
struct DefaultNestedPreviewProvider: NestedPreviewProviding {
	func makePreviewController(for node: FileTreeNode) async throws -> PreviewVC {
		guard let fileURL = node.fileURL else {
			throw NestedPreviewError.missingFileURL(name: node.name)
		}
		guard !node.isSymbolicLink, !node.isDirectory || node.isPackage else {
			throw NestedPreviewError.nonNavigableItem(name: node.name)
		}

		switch route(for: node) {
			case let .glance(previewType):
				let file = try File(url: fileURL)
				try PreviewPolicy.validateFileSize(file)
				return try await previewType.init().createPreviewVC(file: file)
			case .media:
				let showsWaveform = PreviewSupport.getPreviewFileType(fileURL: fileURL) == .flac
					? await PreviewSettingsClient.shared.flacWaveformEnabled()
					: false
				return AVPlayerPreviewVC(fileURL: fileURL, showsWaveform: showsWaveform)
			case .native:
				let previewVC = NativePreviewVC(fileURL: fileURL)
				previewVC.loadViewIfNeeded()
				guard previewVC.previewView != nil else {
					throw NestedPreviewError.nativePreviewUnavailable(name: node.name)
				}
				return previewVC
		}
	}

	func route(for node: FileTreeNode) -> NestedPreviewRoute {
		guard !node.isPackage, let fileURL = node.fileURL else {
			return .native
		}

		let contentType = node.contentTypeIdentifier.flatMap(UTType.init)
		let isPlayableMedia = PreviewSupport.getPreviewFileType(fileURL: fileURL) == .flac
			|| contentType?.conforms(to: .movie) == true
			|| contentType?.conforms(to: .audio) == true
		if isPlayableMedia {
			return .media
		}

		let isNativeMedia = contentType?.conforms(to: .image) == true
			|| contentType?.conforms(to: .pdf) == true
		if isNativeMedia {
			return .native
		}

		guard let registryEntry = SupportedPreviewRegistry.entry(matching: fileURL),
		      let previewType = PreviewVCFactory.getPreviewInitializer(fileURL: fileURL)
		else {
			return .native
		}
		let isExplicitGlanceType = registryEntry.id != "code.other-source-text"
		let isTextType = contentType?.conforms(to: .text) == true
		return isExplicitGlanceType || isTextType ? .glance(previewType) : .native
	}
}

final class NativePreviewVC: NSViewController, PreviewVC {
	let fileURL: URL
	private(set) var previewView: QLPreviewView?

	init(fileURL: URL) {
		self.fileURL = fileURL
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		guard let previewView = QLPreviewView(frame: view.bounds, style: .compact) else {
			return
		}
		previewView.autoresizingMask = [.height, .width]
		previewView.shouldCloseWithWindow = false
		previewView.previewItem = fileURL as NSURL
		view.addSubview(previewView)
		self.previewView = previewView
	}

	func tearDown() {
		if previewView?.window != nil {
			previewView?.close()
		}
		previewView = nil
	}
}

final class AVPlayerPreviewVC: NSViewController, PreviewVC {
	let fileURL: URL
	let showsWaveform: Bool
	private(set) var playerView: AVPlayerView?
	private(set) var player: AVPlayer?
	private(set) var waveformView: FLACWaveformView?
	private weak var observedWindow: NSWindow?
	private var playbackTimeObserver: Any?
	private var waveformAnalysisTask: Task<[Float], Error>?
	private var waveformPresentationTask: Task<Void, Never>?
	private var isFLAC: Bool {
		fileURL.pathExtension.lowercased() == "flac"
	}

	init(fileURL: URL, showsWaveform: Bool = AppSettingsStore.shared.flacWaveformEnabled) {
		self.fileURL = fileURL
		self.showsWaveform = showsWaveform
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = PreviewBackgroundView(frame: .zero)
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		let player = AVPlayer(url: fileURL)
		let playerView = AVPlayerView()
		playerView.controlsStyle = .inline
		playerView.player = player
		playerView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(playerView)
		let playerTopAnchor: NSLayoutYAxisAnchor
		if isFLAC, showsWaveform {
			let waveformView = FLACWaveformView(frame: .zero)
			waveformView.translatesAutoresizingMaskIntoConstraints = false
			view.addSubview(waveformView)
			NSLayoutConstraint.activate([
				waveformView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
				waveformView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
				waveformView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
				waveformView.heightAnchor.constraint(equalToConstant: 72),
			])
			self.waveformView = waveformView
			playerTopAnchor = waveformView.bottomAnchor
			startWaveformAnalysis()
		} else {
			playerTopAnchor = view.topAnchor
		}
		NSLayoutConstraint.activate([
			playerView.topAnchor.constraint(equalTo: playerTopAnchor),
			playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
		])
		self.player = player
		self.playerView = playerView
		if waveformView != nil {
			playbackTimeObserver = player.addPeriodicTimeObserver(
				forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
				queue: .main
			) { [weak self, weak player] time in
				Task { @MainActor [weak self, weak player] in
					guard let player else {
						return
					}
					self?.updateWaveformProgress(
						elapsed: time.seconds,
						duration: player.currentItem?.duration.seconds ?? .nan
					)
				}
			}
		}
	}

	override func viewDidAppear() {
		super.viewDidAppear()
		observePreviewWindow()
		if isFLAC, Self.shouldAutoplay(in: view.window) {
			player?.play()
		}
	}

	override func viewWillDisappear() {
		super.viewWillDisappear()
		player?.pause()
	}

	/// Finder hosts its preview sidebar in a normal-level window. Only a floating
	/// Quick Look preview should start audio without an explicit play action.
	static func shouldAutoplay(in window: NSWindow?) -> Bool {
		guard let window else {
			return false
		}
		return window.level.rawValue >= NSWindow.Level.floating.rawValue
	}

	private func observePreviewWindow() {
		guard let window = view.window, observedWindow !== window else {
			return
		}
		stopObservingPreviewWindow()
		observedWindow = window
		for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
			NotificationCenter.default.addObserver(
				self,
				selector: #selector(handlePreviewWindowChange),
				name: name,
				object: window
			)
		}
	}

	@objc
	func handlePreviewWindowChange(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else {
			return
		}
		if notification.name == NSWindow.willCloseNotification || !window.isVisible {
			player?.pause()
		}
	}

	private func stopObservingPreviewWindow() {
		guard let observedWindow else {
			return
		}
		for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
			NotificationCenter.default.removeObserver(self, name: name, object: observedWindow)
		}
		self.observedWindow = nil
	}

	func updateWaveformProgress(elapsed: Double, duration: Double) {
		guard elapsed.isFinite, duration.isFinite, duration > 0 else {
			return
		}
		waveformView?.progress = elapsed / duration
	}

	private func startWaveformAnalysis() {
		let fileURL = fileURL
		let analysisTask = Task.detached(priority: .utility) {
			try await FLACWaveformAnalyzer.envelope(for: fileURL)
		}
		waveformAnalysisTask = analysisTask
		waveformPresentationTask = Task { [weak self] in
			let amplitudes = await (try? analysisTask.value) ?? []
			guard !Task.isCancelled else {
				return
			}
			self?.waveformView?.isLoading = false
			self?.waveformView?.amplitudes = amplitudes
		}
	}

	func tearDown() {
		stopObservingPreviewWindow()
		waveformPresentationTask?.cancel()
		waveformAnalysisTask?.cancel()
		waveformPresentationTask = nil
		waveformAnalysisTask = nil
		waveformView = nil
		if let playbackTimeObserver {
			player?.removeTimeObserver(playbackTimeObserver)
			self.playbackTimeObserver = nil
		}
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		playerView?.player = nil
		player = nil
		playerView = nil
	}
}
