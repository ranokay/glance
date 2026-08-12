import Cocoa
import Quartz

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
	private var baseStatusText = ""
	private var statusResetTask: Task<Void, Never>?
	private var previewPreparationTask: Task<Void, Error>?
	private var previewPreparationID: UUID?
	private var nestedPreviewTask: Task<Void, Never>?
	private weak var boundStatusProvider: (any PreviewStatusProviding)?

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
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
		NSLayoutConstraint.activate([
			contentContainerView.topAnchor.constraint(equalTo: view.topAnchor),
			contentContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			contentContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			contentContainerView.bottomAnchor.constraint(equalTo: utilityBarView.topAnchor),
			utilityBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			utilityBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			utilityBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
			utilityBarView.heightAnchor.constraint(equalToConstant: 32),
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

			installTopLevelPreview(previewVC, file: file)

			// Update stats
			stats.increaseStatsCounts(fileExtension: file.url.pathExtension)
		} else {
			Log.general.info(
				"Skipping preview for file \(file.path, privacy: .private): File type not supported"
			)
		}
	}

	func installTopLevelPreview(_ previewVC: PreviewVC, file: File) {
		clearPreviewControllers()
		topLevelFile = file
		topLevelPreviewController = previewVC
		currentPreviewController = previewVC
		if file.isDirectory, let outlinePreview = previewVC as? OutlinePreviewVC {
			folderPreviewController = outlinePreview
			outlinePreview.interactionDelegate = self
		}
		bindStatus(to: previewVC)
		show(previewVC)
		backButton.isHidden = true
		updateOpenWithTarget()
	}

	private func show(_ previewVC: PreviewVC) {
		if previewVC.parent == nil {
			addChild(previewVC)
		}
		previewVC.view.translatesAutoresizingMaskIntoConstraints = false
		contentContainerView.addSubview(previewVC.view)
		NSLayoutConstraint.activate([
			previewVC.view.topAnchor.constraint(equalTo: contentContainerView.topAnchor),
			previewVC.view.leadingAnchor.constraint(equalTo: contentContainerView.leadingAnchor),
			previewVC.view.trailingAnchor.constraint(equalTo: contentContainerView.trailingAnchor),
			previewVC.view.bottomAnchor.constraint(equalTo: contentContainerView.bottomAnchor),
		])
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
		statusLabel.stringValue = status
	}

	private func showTransientError(_ message: String) {
		statusResetTask?.cancel()
		statusLabel.stringValue = message
		statusResetTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else {
				return
			}
			guard let self else {
				return
			}
			statusLabel.stringValue = baseStatusText
		}
	}

	private func updateOpenWithTarget() {
		let selectedFolderNodeIsOpenable = selectedFolderNode.map {
			!$0.isSymbolicLink && (!$0.isDirectory || $0.isPackage)
		} == true
		if let topLevelFile, !topLevelFile.isDirectory {
			openWithTargetURL = topLevelFile.url
		} else if let selectedFolderNode, selectedFolderNodeIsOpenable {
			openWithTargetURL = selectedFolderNode.fileURL
		} else {
			openWithTargetURL = nil
		}
		refreshOpenWithMenu()
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

	private func showNestedPreview(for node: FileTreeNode) {
		guard nestedPreviewController == nil, let folderPreviewController else {
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
				folderPreviewController.view.isHidden = true
				nestedPreviewController = previewVC
				currentPreviewController = previewVC
				bindStatus(to: previewVC)
				show(previewVC)
				backButton.isHidden = false
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

	@objc
	func showFolderPreview() {
		nestedPreviewTask?.cancel()
		nestedPreviewTask = nil
		guard let nestedPreviewController, let folderPreviewController else {
			return
		}
		nestedPreviewController.tearDown()
		nestedPreviewController.view.removeFromSuperview()
		nestedPreviewController.removeFromParent()
		self.nestedPreviewController = nil
		currentPreviewController = folderPreviewController
		bindStatus(to: folderPreviewController)
		folderPreviewController.view.isHidden = false
		backButton.isHidden = true
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
		topLevelFile = nil
		selectedFolderNode = nil
		openWithTargetURL = nil
		refreshOpenWithMenu()
	}
}

extension MainVC: OutlinePreviewInteractionDelegate {
	func outlinePreview(_: OutlinePreviewVC, didSelect node: FileTreeNode?) {
		selectedFolderNode = node
		updateOpenWithTarget()
	}

	func outlinePreview(_: OutlinePreviewVC, requestPreviewOf node: FileTreeNode) {
		showNestedPreview(for: node)
	}
}
