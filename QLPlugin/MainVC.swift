import Cocoa
import Quartz

final class PreviewBackgroundView: NSView {
	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override var wantsUpdateLayer: Bool {
		true
	}

	override func updateLayer() {
		let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		layer?.backgroundColor = isDark
			? NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1).cgColor
			: NSColor.white.cgColor
	}
}

enum PreviewError: Error {
	case fileSizeError(path: String)
}

extension PreviewError: LocalizedError {
	var errorDescription: String? {
		switch self {
			case let .fileSizeError(path):
				NSLocalizedString("File \(path) is too large to preview", comment: "")
		}
	}
}

class MainVC: NSViewController, QLPreviewingController {
	/// Bundle ID of the containing app. When the app isn't running, the QL extension
	/// declines to preview and lets macOS fall back to the system handler.
	private static let containingAppBundleID = "com.chamburr.Glance"

	let stats = Stats()
	var nestedPreviewProvider: NestedPreviewProviding = DefaultNestedPreviewProvider()
	var openWithService = OpenWithService()
	var containingAppIsRunning = {
		!NSRunningApplication.runningApplications(
			withBundleIdentifier: MainVC.containingAppBundleID
		).isEmpty
	}

	private(set) var currentPreviewController: PreviewVC?
	private(set) var topLevelPreviewController: PreviewVC?
	private(set) var folderPreviewController: OutlinePreviewVC?
	private(set) var nestedPreviewController: PreviewVC?
	private(set) var topLevelFile: File?
	private(set) var selectedFolderNode: FileTreeNode?
	private(set) var contentContainerView = NSView()
	private(set) var utilityBarView = NSView()
	private(set) var backButton = NSButton()
	private(set) var statusLabel = NSTextField(labelWithString: "")
	private(set) var openWithButton = NSPopUpButton()
	private(set) var openWithTargetURL: URL?
	private(set) var previewNavigationStack = [PreviewVC]()
	private var baseStatusText = ""
	private var utilityBarHeightConstraint: NSLayoutConstraint?
	private var nestedOpenWithTargetURL: URL?
	private var statusResetTask: Task<Void, Never>?
	private var previewPreparationTask: Task<Void, Error>?
	private var previewPreparationID: UUID?
	private var nestedPreviewTask: Task<Void, Never>?
	private weak var boundStatusProvider: (any PreviewStatusProviding)?

	override func loadView() {
		view = PreviewBackgroundView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setUpView()
	}

	private func setUpView() {
		contentContainerView.translatesAutoresizingMaskIntoConstraints = false
		utilityBarView.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(contentContainerView)
		view.addSubview(utilityBarView)
		let utilityBarHeightConstraint = utilityBarView.heightAnchor.constraint(equalToConstant: 0)
		self.utilityBarHeightConstraint = utilityBarHeightConstraint
		NSLayoutConstraint.activate([
			contentContainerView.topAnchor.constraint(equalTo: view.topAnchor),
			contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			contentContainerView.bottomAnchor.constraint(equalTo: utilityBarView.topAnchor),
			utilityBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			utilityBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			utilityBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			utilityBarHeightConstraint,
		])
		setUpUtilityBar()
	}

	private func setUpUtilityBar() {
		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		utilityBarView.addSubview(separator)

		backButton = NSButton(title: "Back", target: self, action: #selector(showFolderPreview))
		backButton.bezelStyle = .inline
		backButton.image = NSImage(
			systemSymbolName: "chevron.backward",
			accessibilityDescription: nil
		)
		backButton.imagePosition = .imageLeading
		backButton.isHidden = true
		backButton.translatesAutoresizingMaskIntoConstraints = false
		utilityBarView.addSubview(backButton)

		statusLabel.alignment = .center
		statusLabel.textColor = .secondaryLabelColor
		statusLabel.lineBreakMode = .byTruncatingTail
		statusLabel.maximumNumberOfLines = 1
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		utilityBarView.addSubview(statusLabel)

		openWithButton = NSPopUpButton(frame: .zero, pullsDown: true)
		openWithButton.bezelStyle = .inline
		openWithButton.target = self
		openWithButton.action = #selector(openWithSelectionChanged(_:))
		openWithButton.translatesAutoresizingMaskIntoConstraints = false
		utilityBarView.addSubview(openWithButton)

		NSLayoutConstraint.activate([
			separator.topAnchor.constraint(equalTo: utilityBarView.topAnchor),
			separator.leadingAnchor.constraint(equalTo: utilityBarView.leadingAnchor),
			separator.trailingAnchor.constraint(equalTo: utilityBarView.trailingAnchor),
			backButton.leadingAnchor.constraint(equalTo: utilityBarView.leadingAnchor, constant: 8),
			backButton.centerYAnchor.constraint(equalTo: utilityBarView.centerYAnchor),
			statusLabel.centerXAnchor.constraint(equalTo: utilityBarView.centerXAnchor),
			statusLabel.centerYAnchor.constraint(equalTo: utilityBarView.centerYAnchor),
			statusLabel.leadingAnchor.constraint(
				greaterThanOrEqualTo: backButton.trailingAnchor,
				constant: 8
			),
			statusLabel.trailingAnchor.constraint(
				lessThanOrEqualTo: openWithButton.leadingAnchor,
				constant: -8
			),
			openWithButton.trailingAnchor.constraint(
				equalTo: utilityBarView.trailingAnchor,
				constant: -8
			),
			openWithButton.centerYAnchor.constraint(equalTo: utilityBarView.centerYAnchor),
		])
		refreshOpenWithMenu()
		updateChrome()
	}

	/// Function responsible for generating file previews. It's called for previews in Finder,
	/// Spotlight, Quick Look and any other UI elements which implement the API.
	nonisolated func preparePreviewOfFile(
		at fileUrl: URL,
		completionHandler handler: @escaping @Sendable (Error?) -> Void
	) {
		Task { @MainActor [weak self] in
			guard let self else {
				handler(CancellationError())
				return
			}
			startPreviewPreparation(at: fileUrl, completionHandler: handler)
		}
	}

	private func startPreviewPreparation(
		at fileURL: URL,
		completionHandler handler: @escaping @Sendable (Error?) -> Void
	) {
		previewPreparationTask?.cancel()
		let preparationID = UUID()
		previewPreparationID = preparationID
		let task = Task { @MainActor [weak self] in
			guard let self else {
				throw CancellationError()
			}
			try await preparePreview(at: fileURL)
		}
		previewPreparationTask = task
		Task { @MainActor [weak self] in
			do {
				try await task.value
				handler(nil)
			} catch is CancellationError {
				// Superseded requests still complete exactly once without asking Quick Look
				// to replace the newer preview with its fallback UI.
				handler(nil)
			} catch {
				handler(error)
			}
			if self?.previewPreparationID == preparationID {
				self?.previewPreparationTask = nil
				self?.previewPreparationID = nil
			}
		}
	}

	private func preparePreview(at fileURL: URL) async throws {
		guard containingAppIsRunning() else {
			Log.general.info("Glance app is not running, declining preview")
			throw NSError(
				domain: "com.chamburr.Glance.QLPlugin",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Glance app is not running"]
			)
		}

		let file: File
		do {
			file = try File(url: fileURL)
		} catch {
			Log.general.error(
				"Could not obtain information about file \(fileURL.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
		do {
			try PreviewPolicy.validateFileSize(file)
		} catch {
			Log.general
				.error("Skipping file preview: \(error.localizedDescription, privacy: .private)")
			throw error
		}

		Log.general.info("Generating preview for file \(file.path, privacy: .private)")
		do {
			try await previewFile(file: file)
		} catch {
			Log.general.error(
				"Could not generate preview for file \(file.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			throw error
		}
	}

	/// Generates a preview of the selected file and adds the corresponding child view controller.
	func previewFile(file: File) async throws {
		// Initialize `PreviewVC` for the file type
		if let previewInitializerType = PreviewVCFactory.getPreviewInitializer(
			fileURL: file.url,
			isDirectory: file.isDirectory
		) {
			// Generate file preview
			let previewInitializer = previewInitializerType.init()
			let previewVC = try await previewInitializer.createPreviewVC(file: file)
			try Task.checkCancellation()

			installTopLevelPreview(previewVC, file: file)

			// Update stats
			stats.increaseStatsCounts(fileExtension: file.url.pathExtension)
		} else {
			Log.general.info(
				"Skipping preview for file \(file.path, privacy: .private): File type not supported"
			)
			throw NSError(
				domain: "com.chamburr.Glance.QLPlugin",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "File type is not supported"]
			)
		}
	}

	func installTopLevelPreview(_ previewVC: PreviewVC, file: File) {
		clearPreviewControllers()
		topLevelFile = file
		topLevelPreviewController = previewVC
		currentPreviewController = previewVC
		previewNavigationStack = [previewVC]
		if file.isDirectory, let outlinePreview = previewVC as? OutlinePreviewVC {
			folderPreviewController = outlinePreview
			outlinePreview.interactionDelegate = self
		}
		nestedOpenWithTargetURL = nil
		bindStatus(to: previewVC)
		show(previewVC)
		updateOpenWithTarget()
	}

	private func show(_ previewVC: PreviewVC) {
		if previewVC.parent == nil {
			addChild(previewVC)
		}
		for child in children where child !== previewVC {
			child.view.isHidden = true
		}
		if previewVC.view.superview == nil {
			previewVC.view.translatesAutoresizingMaskIntoConstraints = false
			contentContainerView.addSubview(previewVC.view)
			NSLayoutConstraint.activate([
				previewVC.view.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
				previewVC.view.leadingAnchor
					.constraint(equalTo: contentContainerView.leadingAnchor),
				previewVC.view.trailingAnchor
					.constraint(equalTo: contentContainerView.trailingAnchor),
				previewVC.view.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
			])
		}
		previewVC.view.isHidden = false
	}

	private func bindStatus(to previewVC: PreviewVC) {
		boundStatusProvider?.previewStatusDidChange = nil
		boundStatusProvider = nil
		guard let statusProvider = previewVC as? PreviewStatusProviding else {
			setBaseStatus("")
			return
		}
		boundStatusProvider = statusProvider
		setBaseStatus(statusProvider.previewStatusText)
		statusProvider.previewStatusDidChange = { [weak self] status in
			self?.setBaseStatus(status)
		}
	}

	private func setBaseStatus(_ status: String) {
		baseStatusText = status
		setDisplayedStatus(status)
	}

	private func setDisplayedStatus(_ status: String) {
		statusLabel.stringValue = status
		statusLabel.toolTip = status.isEmpty ? nil : status
		statusLabel.setAccessibilityLabel(status)
		updateChrome()
	}

	private func showTransientError(_ message: String) {
		statusResetTask?.cancel()
		setDisplayedStatus(message)
		statusResetTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else {
				return
			}
			guard let self else {
				return
			}
			setDisplayedStatus(baseStatusText)
		}
	}

	private func updateOpenWithTarget() {
		let selectedFolderNodeIsOpenable = selectedFolderNode.map {
			!$0.isSymbolicLink && (!$0.isDirectory || $0.isPackage)
		} == true
		if currentPreviewController is OutlinePreviewVC,
		   let selectedFolderNode,
		   selectedFolderNodeIsOpenable {
			openWithTargetURL = selectedFolderNode.fileURL
		} else if previewNavigationStack.count > 1 {
			openWithTargetURL = nestedOpenWithTargetURL
		} else {
			openWithTargetURL = nil
		}
		refreshOpenWithMenu()
		updateChrome()
	}

	private func refreshOpenWithMenu() {
		let menu = NSMenu()
		menu.autoenablesItems = false
		let titleItem = NSMenuItem(title: "Open With…", action: nil, keyEquivalent: "")
		titleItem.isEnabled = false
		menu.addItem(titleItem)

		let applications = openWithTargetURL.map(openWithService.applications(for:)) ?? []
		if !applications.isEmpty {
			menu.addItem(.separator())
		}
		for application in applications {
			let menuItem = NSMenuItem(
				title: application.displayName,
				action: nil,
				keyEquivalent: ""
			)
			menuItem.isEnabled = true
			menuItem.representedObject = application.applicationURL as NSURL
			menuItem.image = application.icon.copy() as? NSImage
			menuItem.image?.size = NSSize(width: 16, height: 16)
			if application.isDefault {
				menuItem.state = .on
				menuItem.toolTip = "Default application"
			}
			menu.addItem(menuItem)
		}

		openWithButton.menu = menu
		openWithButton.isEnabled = openWithTargetURL != nil && !applications.isEmpty
		openWithButton.selectItem(at: 0)
	}

	private func updateChrome() {
		guard isViewLoaded else {
			return
		}
		let showsBack = previewNavigationStack.count > 1
		let showsStatus = !statusLabel.stringValue.isEmpty
		let showsOpenWith = openWithTargetURL != nil
		backButton.isHidden = !showsBack
		statusLabel.isHidden = !showsStatus
		openWithButton.isHidden = !showsOpenWith
		let showsUtilityBar = showsBack || showsStatus || showsOpenWith
		utilityBarView.isHidden = !showsUtilityBar
		utilityBarHeightConstraint?.constant = showsUtilityBar ? 32 : 0
	}

	@objc
	private func openWithSelectionChanged(_ sender: NSPopUpButton) {
		guard let applicationURL = sender.selectedItem?.representedObject as? URL else {
			return
		}
		openWithApplication(at: applicationURL)
	}

	func openWithApplication(at applicationURL: URL) {
		guard let fileURL = openWithTargetURL else {
			return
		}
		openWithService.open(fileURL: fileURL, with: applicationURL) { [weak self] error in
			guard let error else {
				return
			}
			let nsError = error as NSError
			Log.general.error(
				"Could not open \(fileURL.path, privacy: .private) with \(applicationURL.path, privacy: .private): \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(error.localizedDescription, privacy: .private)"
			)
			self?
				.showTransientError(
					"Couldn’t open with \(applicationURL.deletingPathExtension().lastPathComponent)"
				)
		}
	}

	private func showNestedPreview(for node: FileTreeNode, from source: OutlinePreviewVC) {
		guard currentPreviewController === source else {
			return
		}
		nestedPreviewTask?.cancel()
		nestedPreviewTask = Task { @MainActor [weak self] in
			do {
				guard let self else {
					return
				}
				let previewVC = try await nestedPreviewProvider.makePreviewController(for: node)
				try Task.checkCancellation()
				guard currentPreviewController === source else {
					return
				}
				pushPreview(previewVC, openWithTargetURL: node.fileURL)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not generate nested preview for \(node.name, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				self?.showTransientError("Couldn’t preview \(node.name)")
			}
		}
	}

	private func showDirectoryPreview(for node: FileTreeNode, from source: OutlinePreviewVC) {
		guard currentPreviewController === source else {
			return
		}
		nestedPreviewTask?.cancel()
		nestedPreviewTask = Task { @MainActor [weak self] in
			do {
				guard let self else {
					return
				}
				let previewVC = try await source.makeDirectoryPreview(for: node)
				try Task.checkCancellation()
				guard currentPreviewController === source else {
					return
				}
				pushPreview(previewVC, openWithTargetURL: nil)
			} catch is CancellationError {
				return
			} catch {
				Log.general.error(
					"Could not open folder \(node.name, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				self?.showTransientError("Couldn’t open \(node.name)")
			}
		}
	}

	private func pushPreview(_ previewVC: PreviewVC, openWithTargetURL: URL?) {
		if let outlinePreview = previewVC as? OutlinePreviewVC,
		   outlinePreview.isDirectoryBrowser {
			outlinePreview.interactionDelegate = self
			folderPreviewController = outlinePreview
			nestedPreviewController = nil
			selectedFolderNode = outlinePreview.selectedNode
		} else {
			nestedPreviewController = previewVC
			selectedFolderNode = nil
		}
		previewNavigationStack.append(previewVC)
		currentPreviewController = previewVC
		nestedOpenWithTargetURL = openWithTargetURL
		bindStatus(to: previewVC)
		show(previewVC)
		updateOpenWithTarget()
	}

	@objc
	func showFolderPreview() {
		nestedPreviewTask?.cancel()
		nestedPreviewTask = nil
		guard previewNavigationStack.count > 1,
		      let removedController = previewNavigationStack.popLast(),
		      let previousController = previewNavigationStack.last
		else {
			return
		}
		removedController.tearDown()
		removedController.view.removeFromSuperview()
		removedController.removeFromParent()
		currentPreviewController = previousController
		if let outlinePreview = previousController as? OutlinePreviewVC,
		   outlinePreview.isDirectoryBrowser {
			folderPreviewController = outlinePreview
			nestedPreviewController = nil
			selectedFolderNode = outlinePreview.selectedNode
		} else {
			folderPreviewController = nil
			nestedPreviewController = previousController
			selectedFolderNode = nil
		}
		nestedOpenWithTargetURL = nil
		bindStatus(to: previousController)
		show(previousController)
		updateOpenWithTarget()
	}

	private func clearPreviewControllers() {
		nestedPreviewTask?.cancel()
		nestedPreviewTask = nil
		statusResetTask?.cancel()
		boundStatusProvider?.previewStatusDidChange = nil
		boundStatusProvider = nil
		for child in children {
			(child as? PreviewVC)?.tearDown()
			child.view.removeFromSuperview()
			child.removeFromParent()
		}
		currentPreviewController = nil
		topLevelPreviewController = nil
		folderPreviewController = nil
		nestedPreviewController = nil
		previewNavigationStack.removeAll()
		topLevelFile = nil
		selectedFolderNode = nil
		nestedOpenWithTargetURL = nil
		openWithTargetURL = nil
		refreshOpenWithMenu()
		setBaseStatus("")
		updateChrome()
	}
}

extension MainVC: OutlinePreviewInteractionDelegate {
	func outlinePreview(_: OutlinePreviewVC, didSelect node: FileTreeNode?) {
		selectedFolderNode = node
		updateOpenWithTarget()
	}

	func outlinePreview(_ preview: OutlinePreviewVC, requestPreviewOf node: FileTreeNode) {
		showNestedPreview(for: node, from: preview)
	}

	func outlinePreview(_ preview: OutlinePreviewVC, requestNavigationInto node: FileTreeNode) {
		showDirectoryPreview(for: node, from: preview)
	}
}
