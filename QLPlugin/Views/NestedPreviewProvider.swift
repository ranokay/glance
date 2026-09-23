import AVKit
import Cocoa
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
				return AVPlayerPreviewVC(fileURL: fileURL)
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
	private(set) var playerView: AVPlayerView?
	private(set) var player: AVPlayer?
	private(set) var waveformView: FLACWaveformView?
	private var waveformAnalysisTask: Task<[Float], Error>?
	private var waveformPresentationTask: Task<Void, Never>?

	init(fileURL: URL) {
		self.fileURL = fileURL
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
		if fileURL.pathExtension.lowercased() == "flac" {
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
		waveformPresentationTask?.cancel()
		waveformAnalysisTask?.cancel()
		waveformPresentationTask = nil
		waveformAnalysisTask = nil
		waveformView = nil
		player?.pause()
		player?.replaceCurrentItem(with: nil)
		playerView?.player = nil
		player = nil
		playerView = nil
	}
}
