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
	/// Max size of files to render
	let maxFileSize = 10_000_000 // 10 MB

	/// Bundle ID of the containing app. When the app isn't running, the QL extension
	/// declines to preview and lets macOS fall back to the system handler.
	private static let containingAppBundleID = "com.chamburr.Glance"

	let stats = Stats()
	var nestedPreviewProvider: NestedPreviewProviding = DefaultNestedPreviewProvider()
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
	private var baseStatusText = ""
	private var statusResetTask: Task<Void, Never>?

	override func loadView() {
		view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		setUpView()
	}

	private func setUpView() {
		// Draw border around previews, in similar style to macOS's default previews
		view.wantsLayer = true
		view.layer?.borderWidth = 1
		view.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor

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
				lessThanOrEqualTo: utilityBarView.trailingAnchor,
				constant: -8
			),
		])
	}

	/// Function responsible for generating file previews. It's called for previews in Finder,
	/// Spotlight, Quick Look and any other UI elements which implement the API.
	nonisolated func preparePreviewOfFile(
		at fileUrl: URL,
		completionHandler handler: @escaping @Sendable (Error?) -> Void
	) {
		DispatchQueue.main.async {
			// Only preview files when the containing app is running
			if NSRunningApplication.runningApplications(
				withBundleIdentifier: Self.containingAppBundleID
			).isEmpty {
				Log.general.info("Glance app is not running, declining preview")
				let error = NSError(
					domain: "com.chamburr.Glance.QLPlugin",
					code: 1,
					userInfo: [NSLocalizedDescriptionKey: "Glance app is not running"]
				)
				handler(error)
				return
			}

			// Read information about the file to preview
			var file: File
			do {
				file = try File(url: fileUrl)
			} catch {
				Log.general.error(
					"Could not obtain information about file \(fileUrl.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				handler(error)
				return
			}

			// Skip preview if the file is too large
			if !file.isDirectory, !file.isArchive, file.size > self.maxFileSize {
				// Log error and fall back to default preview (by calling the completion handler
				// with the error)
				let error = PreviewError.fileSizeError(path: file.path)
				Log.general
					.error(
						"Skipping file preview: \(error.localizedDescription, privacy: .private)"
					)
				handler(error)
				return
			}

			// Render file preview
			Log.general.info("Generating preview for file \(file.path, privacy: .private)")
			do {
				try self.previewFile(file: file)
			} catch {
				// Log error and fall back to default preview (by calling the completion handler
				// with the error)
				Log.general.error(
					"Could not generate preview for file \(file.path, privacy: .private): \(error.localizedDescription, privacy: .private)"
				)
				handler(error)
				return
			}

			// Hide preview loading spinner
			handler(nil)
		}
	}

	/// Generates a preview of the selected file and adds the corresponding child view controller.
	func previewFile(file: File) throws {
		// Initialize `PreviewVC` for the file type
		if let previewInitializerType = PreviewVCFactory.getPreviewInitializer(
			fileURL: file.url,
			isDirectory: file.isDirectory
		) {
			// Generate file preview
			let previewInitializer = previewInitializerType.init()
			let previewVC = try previewInitializer.createPreviewVC(file: file)

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
		guard let statusProvider = previewVC as? PreviewStatusProviding else {
			setBaseStatus("")
			return
		}
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

	private func showNestedPreview(for node: FileTreeNode) {
		guard nestedPreviewController == nil, let folderPreviewController else {
			return
		}
		do {
			let previewVC = try nestedPreviewProvider.makePreviewController(for: node)
			folderPreviewController.view.isHidden = true
			nestedPreviewController = previewVC
			currentPreviewController = previewVC
			show(previewVC)
			backButton.isHidden = false
		} catch {
			Log.general.error(
				"Could not generate nested preview for \(node.name, privacy: .private): \(error.localizedDescription, privacy: .private)"
			)
			showTransientError("Couldn’t preview \(node.name)")
		}
	}

	@objc
	func showFolderPreview() {
		guard let nestedPreviewController, let folderPreviewController else {
			return
		}
		nestedPreviewController.view.removeFromSuperview()
		nestedPreviewController.removeFromParent()
		self.nestedPreviewController = nil
		currentPreviewController = folderPreviewController
		folderPreviewController.view.isHidden = false
		backButton.isHidden = true
	}

	private func clearPreviewControllers() {
		statusResetTask?.cancel()
		for child in children {
			child.view.removeFromSuperview()
			child.removeFromParent()
		}
		currentPreviewController = nil
		topLevelPreviewController = nil
		folderPreviewController = nil
		nestedPreviewController = nil
		selectedFolderNode = nil
	}
}

extension MainVC: OutlinePreviewInteractionDelegate {
	func outlinePreview(_: OutlinePreviewVC, didSelect node: FileTreeNode?) {
		selectedFolderNode = node
	}

	func outlinePreview(_: OutlinePreviewVC, requestPreviewOf node: FileTreeNode) {
		showNestedPreview(for: node)
	}
}
