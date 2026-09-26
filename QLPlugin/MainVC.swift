import Cocoa
import GlanceKit
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

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
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

	var currentPreviewController: PreviewVC? {
		previewNavigationStack.last
	}

	var folderPreviewController: OutlinePreviewVC?
	var nestedPreviewController: PreviewVC?
	var topLevelFile: File?
	var selectedFolderNode: FileTreeNode?
	private(set) var contentContainerView = NSView()
	private(set) var utilityBarView = NSView()
	private(set) var backButton = NSButton()
	private(set) var statusLabel = NSTextField(labelWithString: "")
	private(set) var openWithButton = NSPopUpButton()
	var openWithTargetURL: URL?
	var previewNavigationStack = [PreviewVC]()
	var baseStatusText = ""
	private var utilityBarHeightConstraint: NSLayoutConstraint?
	var nestedOpenWithTargetURL: URL?
	var statusResetTask: Task<Void, Never>?
	var previewPreparationTask: Task<Void, Error>?
	var previewPreparationID: UUID?
	var nestedPreviewTask: Task<Void, Never>?
	weak var boundStatusProvider: (any PreviewStatusProviding)?

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

	func show(_ previewVC: PreviewVC) {
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

	func bindStatus(to previewVC: PreviewVC) {
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

	func setBaseStatus(_ status: String) {
		baseStatusText = status
		setDisplayedStatus(status)
	}

	func setDisplayedStatus(_ status: String) {
		statusLabel.stringValue = status
		statusLabel.toolTip = status.isEmpty ? nil : status
		statusLabel.setAccessibilityLabel(status)
		updateChrome()
	}

	func updateOpenWithTarget() {
		let selectedFolderNodeIsOpenable = selectedFolderNode.map {
			!$0.isSymbolicLink && (!$0.isDirectory || $0.isPackage)
		} == true
		if currentPreviewController is OutlinePreviewVC,
		   let selectedFolderNode,
		   selectedFolderNodeIsOpenable
		{
			openWithTargetURL = selectedFolderNode.fileURL
		} else if previewNavigationStack.count > 1 {
			openWithTargetURL = nestedOpenWithTargetURL
		} else {
			openWithTargetURL = nil
		}
		refreshOpenWithMenu()
		updateChrome()
	}

	func refreshOpenWithMenu() {
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

	func updateChrome() {
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
