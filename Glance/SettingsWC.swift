import Cocoa
import GlanceKit
import ServiceManagement

private final class SettingsDocumentView: NSView {
	override var isFlipped: Bool {
		true
	}
}

@MainActor
protocol LoginItemManaging {
	var status: SMAppService.Status { get }
	func register() throws
	func unregister() throws
	func openSystemSettings()
}

private struct MainAppLoginItem: LoginItemManaging {
	var status: SMAppService.Status {
		SMAppService.mainApp.status
	}

	func register() throws {
		try SMAppService.mainApp.register()
	}

	func unregister() throws {
		try SMAppService.mainApp.unregister()
	}

	func openSystemSettings() {
		SMAppService.openSystemSettingsLoginItems()
	}
}

enum SettingsPane: Int, CaseIterable {
	case general
	case appearance
	case audio
	case updates
	case about

	var title: String {
		switch self {
			case .general:
				"General"
			case .appearance:
				"Appearance"
			case .audio:
				"Audio"
			case .updates:
				"Updates"
			case .about:
				"About"
		}
	}

	var subtitle: String {
		switch self {
			case .general:
				"Glance lives in the menu bar. The Dock icon appears only while a window is open."
			case .appearance:
				"Applied to new code, Markdown, and notebook previews."
			case .audio:
				"FLAC playback stays available either way."
			case .updates:
				"Signed by Sparkle, downloaded and installed inside Glance."
			case .about:
				"All-in-one Quick Look."
		}
	}

	var symbolName: String {
		switch self {
			case .general:
				"slider.horizontal.3"
			case .appearance:
				"textformat.size"
			case .audio:
				"waveform"
			case .updates:
				"arrow.triangle.2.circlepath"
			case .about:
				"info.circle"
		}
	}

	var keywords: String {
		switch self {
			case .general:
				"start login menu bar dock launch"
			case .appearance:
				"font type size wrap lines preview appearance"
			case .audio:
				"flac waveform sound playback"
			case .updates:
				"update sparkle check download install release notes"
			case .about:
				"about version credits privacy github license links"
		}
	}
}

final class SettingsWC: NSWindowController {
	static let shared = SettingsWC(
		settingsStore: .shared,
		fontFamilies: NSFontManager.shared.availableFontFamilies,
	)

	let fontFamilyPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
	let fontSizeField = NSTextField(frame: .zero)
	let lineWrappingSwitch = NSSwitch(frame: .zero)
	let flacWaveformSwitch = NSSwitch(frame: .zero)
	let resetAppearanceButton = NSButton(
		title: "Reset",
		target: nil,
		action: nil,
	)
	let updateStatusLabel = NSTextField(wrappingLabelWithString: "Never checked.")
	let checkForUpdatesButton = NSButton(
		title: "Check for Updates",
		target: nil,
		action: nil,
	)
	let installUpdateButton = NSButton(
		title: "Install and Relaunch",
		target: nil,
		action: nil,
	)
	let autoUpdateSwitch = NSSwitch(frame: .zero)
	let startAtLoginSwitch = NSSwitch(frame: .zero)
	let loginItemStatusLabel = NSTextField(wrappingLabelWithString: "")
	let openLoginItemsButton = NSButton(
		title: "Open Login Items",
		target: nil,
		action: nil,
	)
	let sidebarTableView = NSTableView(frame: .zero)
	let settingsSearchField = NSSearchField(frame: .zero)
	let noResultsLabel = NSTextField(wrappingLabelWithString: "No settings match your search.")

	private let settingsStore: AppSettingsStore
	private let loginItem: any LoginItemManaging
	private let fontFamilies: [String]
	private let aboutLinkURLs = [
		AppLinks.website,
		AppLinks.license,
		AppLinks.credits,
		AppLinks.privacy,
	]
	private(set) var aboutLinkButtons: [NSButton] = []
	private let fontSizeStepper = NSStepper()
	private let specimenView = PreviewSpecimenView()
	private let contentContainer = NSView()
	private var paneScrollViews: [SettingsPane: NSScrollView] = [:]
	private var paneViews: [SettingsPane: NSView] = [:]
	private var visiblePanes = SettingsPane.allCases
	private var loginItemIssueRow: SettingsRowView?
	private(set) var selectedPane = SettingsPane.general

	var activePaneScrollView: NSScrollView? {
		paneScrollViews[selectedPane]
	}

	init(
		settingsStore: AppSettingsStore,
		fontFamilies: [String],
		loginItem: any LoginItemManaging = MainAppLoginItem(),
	) {
		self.settingsStore = settingsStore
		self.loginItem = loginItem
		self.fontFamilies = Array(Set(fontFamilies)).sorted {
			$0.localizedCaseInsensitiveCompare($1) == .orderedAscending
		}

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false,
		)
		window.title = "Settings"
		window.titleVisibility = .hidden
		window.isReleasedWhenClosed = false
		window.minSize = NSSize(width: 560, height: 480)
		window.center()
		WindowAppearance.apply(to: window)
		WindowAppearance.hideMinimizeAndZoomButtons(on: window)
		WindowAppearance.track(window)

		super.init(window: window)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(updateStatusDidChange),
			name: SparkleUpdateCenter.statusDidChangeNotification,
			object: nil,
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(windowWillClose),
			name: NSWindow.willCloseNotification,
			object: window,
		)

		setUpContent()
		syncState()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func showSettingsWindow() {
		syncState()
		showWindow(nil)
		if let window {
			WindowAppearance.bringToFront(window)
			window.makeFirstResponder(sidebarTableView)
		}
	}

	func selectPane(_ pane: SettingsPane) {
		if !visiblePanes.contains(pane) {
			settingsSearchField.stringValue = ""
			visiblePanes = SettingsPane.allCases
			sidebarTableView.reloadData()
		}
		selectedPane = pane
		noResultsLabel.isHidden = true
		for (pane, view) in paneViews {
			view.isHidden = pane != selectedPane
		}
		if
			let row = visiblePanes.firstIndex(of: pane),
			sidebarTableView.selectedRow != row
		{
			sidebarTableView.selectRowIndexes(
				IndexSet(integer: row),
				byExtendingSelection: false,
			)
		}
	}

	func showAboutPane() {
		selectPane(.about)
		showSettingsWindow()
	}

	// MARK: - Content Setup

	private func setUpContent() {
		guard let contentView = window?.contentView else {
			return
		}

		configureControls()

		let sidebar = makeSidebar()
		let divider = NSBox()
		divider.boxType = .custom
		divider.titlePosition = .noTitle
		divider.borderWidth = 0
		divider.cornerRadius = 0
		divider.fillColor = .separatorColor
		divider.translatesAutoresizingMaskIntoConstraints = false

		contentContainer.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(sidebar)
		contentView.addSubview(divider)
		contentView.addSubview(contentContainer)

		NSLayoutConstraint.activate([
			sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
			sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
			sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			sidebar.widthAnchor.constraint(equalToConstant: 190),
			divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
			divider.topAnchor.constraint(equalTo: contentView.topAnchor),
			divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
			divider.widthAnchor.constraint(equalToConstant: 1),
			contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
			contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
			contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
			contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
		])

		addPane(.general, content: generalPaneContent())
		addPane(.appearance, content: appearancePaneContent())
		addPane(.audio, content: audioPaneContent())
		addPane(.updates, content: updatesPaneContent())
		addPane(.about, content: aboutPaneContent())

		noResultsLabel.font = .systemFont(ofSize: 13)
		noResultsLabel.textColor = .secondaryLabelColor
		noResultsLabel.alignment = .center
		noResultsLabel.maximumNumberOfLines = 0
		noResultsLabel.isHidden = true
		noResultsLabel.setAccessibilityLabel("No settings match your search.")
		noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
		contentContainer.addSubview(noResultsLabel)
		NSLayoutConstraint.activate([
			noResultsLabel.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
			noResultsLabel.centerYAnchor.constraint(equalTo: contentContainer.centerYAnchor),
			noResultsLabel.widthAnchor.constraint(
				lessThanOrEqualTo: contentContainer.widthAnchor,
				constant: -60,
			),
		])

		selectPane(.general)
	}

	private func makeSidebar() -> NSView {
		let sidebar = NSVisualEffectView()
		sidebar.material = .sidebar
		sidebar.blendingMode = .behindWindow
		sidebar.state = .followsWindowActiveState
		sidebar.translatesAutoresizingMaskIntoConstraints = false

		sidebarTableView.identifier = NSUserInterfaceItemIdentifier("Settings.Sidebar")
		sidebarTableView.dataSource = self
		sidebarTableView.delegate = self
		sidebarTableView.headerView = nil
		sidebarTableView.rowHeight = 32
		sidebarTableView.intercellSpacing = NSSize(width: 0, height: 2)
		sidebarTableView.backgroundColor = .clear
		sidebarTableView.style = .plain
		sidebarTableView.selectionHighlightStyle = .none
		sidebarTableView.allowsEmptySelection = false
		sidebarTableView.allowsMultipleSelection = false
		sidebarTableView.focusRingType = .none
		sidebarTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
		sidebarTableView
			.addTableColumn(
				NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Settings.Pane")),
			)
		sidebarTableView.tableColumns[0].width = 170
		sidebarTableView.setAccessibilityLabel("Settings sections")
		sidebarTableView.reloadData()

		settingsSearchField.placeholderString = "Search"
		settingsSearchField.controlSize = .regular
		settingsSearchField.sendsSearchStringImmediately = true
		settingsSearchField.target = self
		settingsSearchField.action = #selector(settingsSearchChanged)
		settingsSearchField.setAccessibilityLabel("Search settings")
		settingsSearchField.translatesAutoresizingMaskIntoConstraints = false

		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = false
		scrollView.borderType = .noBorder
		scrollView.documentView = sidebarTableView
		scrollView.translatesAutoresizingMaskIntoConstraints = false

		sidebar.addSubview(settingsSearchField)
		sidebar.addSubview(scrollView)

		NSLayoutConstraint.activate([
			settingsSearchField.topAnchor.constraint(
				equalTo: sidebar.safeAreaLayoutGuide.topAnchor,
				constant: 10,
			),
			settingsSearchField.leadingAnchor.constraint(
				equalTo: sidebar.leadingAnchor,
				constant: 10,
			),
			settingsSearchField.trailingAnchor.constraint(
				equalTo: sidebar.trailingAnchor,
				constant: -10,
			),
			scrollView.topAnchor.constraint(equalTo: settingsSearchField.bottomAnchor, constant: 8),
			scrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
			scrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
			scrollView.bottomAnchor.constraint(
				equalTo: sidebar.safeAreaLayoutGuide.bottomAnchor,
				constant: -10,
			),
		])

		return sidebar
	}

	private func addPane(_ pane: SettingsPane, content: [NSView]) {
		let paneView = makePaneView(for: pane, content: content)
		contentContainer.addSubview(paneView)
		NSLayoutConstraint.activate([
			paneView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
			paneView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
			paneView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
			paneView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
		])
		paneViews[pane] = paneView
		paneView.isHidden = pane != selectedPane
	}

	private func makePaneView(for pane: SettingsPane, content: [NSView]) -> NSView {
		let container = NSView()
		container.translatesAutoresizingMaskIntoConstraints = false

		let titleLabel = NSTextField(labelWithString: pane.title)
		titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
		let subtitleLabel = NSTextField(wrappingLabelWithString: pane.subtitle)
		subtitleLabel.font = .systemFont(ofSize: 11.5)
		subtitleLabel.textColor = .secondaryLabelColor
		subtitleLabel.maximumNumberOfLines = 0
		let header = NSStackView(views: [titleLabel, subtitleLabel])
		header.orientation = .vertical
		header.alignment = .leading
		header.spacing = 4
		header.translatesAutoresizingMaskIntoConstraints = false
		subtitleLabel.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true

		let scrollView = makeContentScrollView(
			content: content,
			centersContent: pane == .about,
		)
		scrollView.identifier = NSUserInterfaceItemIdentifier("Settings.Pane.\(pane.rawValue)")
		paneScrollViews[pane] = scrollView

		container.addSubview(header)
		container.addSubview(scrollView)
		NSLayoutConstraint.activate([
			header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
			header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -26),
			header.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
			scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
			scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
		])
		return container
	}

	private func makeContentScrollView(
		content: [NSView],
		centersContent: Bool = false,
	) -> NSScrollView {
		let stack = NSStackView(views: content)
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		for view in content {
			view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}

		let documentView = SettingsDocumentView()
		documentView.translatesAutoresizingMaskIntoConstraints = false
		documentView.addSubview(stack)

		let scrollView = NSScrollView()
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.borderType = .noBorder
		scrollView.translatesAutoresizingMaskIntoConstraints = false
		scrollView.documentView = documentView

		var constraints = [
			documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
			documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
			documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
			documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
			stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 26),
			stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -26),
		]
		if centersContent {
			constraints += [
				documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
				stack.centerYAnchor.constraint(equalTo: documentView.centerYAnchor),
				stack.topAnchor.constraint(
					greaterThanOrEqualTo: documentView.topAnchor,
					constant: 20,
				),
				stack.bottomAnchor.constraint(
					lessThanOrEqualTo: documentView.bottomAnchor,
					constant: -20,
				),
			]
		} else {
			constraints += [
				stack.topAnchor.constraint(equalTo: documentView.topAnchor),
				stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
			]
		}
		NSLayoutConstraint.activate(constraints)

		return scrollView
	}

	private func configureControls() {
		startAtLoginSwitch.target = self
		startAtLoginSwitch.action = #selector(startAtLoginChanged)
		startAtLoginSwitch.setAccessibilityLabel("Start at Login")
		loginItemStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		loginItemStatusLabel.textColor = .secondaryLabelColor
		loginItemStatusLabel.maximumNumberOfLines = 0
		openLoginItemsButton.bezelStyle = .rounded
		openLoginItemsButton.controlSize = .small
		openLoginItemsButton.target = self
		openLoginItemsButton.action = #selector(openLoginItemsSettings)

		fontFamilyPopUpButton.addItem(withTitle: "System Default")
		fontFamilyPopUpButton.addItems(withTitles: fontFamilies)
		fontFamilyPopUpButton.target = self
		fontFamilyPopUpButton.action = #selector(fontFamilyChanged)
		fontFamilyPopUpButton.setAccessibilityLabel("Preview font family")
		fontFamilyPopUpButton.widthAnchor.constraint(
			greaterThanOrEqualToConstant: 200,
		).isActive = true

		let numberFormatter = NumberFormatter()
		numberFormatter.allowsFloats = false
		numberFormatter.minimum = NSNumber(value: PreviewAppearancePreferences.minimumFontSize)
		numberFormatter.maximum = NSNumber(value: PreviewAppearancePreferences.maximumFontSize)
		fontSizeField.formatter = numberFormatter
		fontSizeField.alignment = .right
		fontSizeField.target = self
		fontSizeField.action = #selector(fontSizeChanged)
		fontSizeField.setAccessibilityLabel("Preview font size")
		fontSizeField.widthAnchor.constraint(equalToConstant: 52).isActive = true

		fontSizeStepper.minValue = PreviewAppearancePreferences.minimumFontSize
		fontSizeStepper.maxValue = PreviewAppearancePreferences.maximumFontSize
		fontSizeStepper.increment = 1
		fontSizeStepper.target = self
		fontSizeStepper.action = #selector(fontSizeStepperChanged)
		fontSizeStepper.setAccessibilityLabel("Preview font size stepper")

		lineWrappingSwitch.target = self
		lineWrappingSwitch.action = #selector(lineWrappingChanged)
		lineWrappingSwitch.setAccessibilityLabel("Wrap long lines")
		flacWaveformSwitch.target = self
		flacWaveformSwitch.action = #selector(flacWaveformChanged)
		flacWaveformSwitch.setAccessibilityLabel("Show FLAC waveform")

		resetAppearanceButton.bezelStyle = .rounded
		resetAppearanceButton.target = self
		resetAppearanceButton.action = #selector(resetAppearance)

		checkForUpdatesButton.bezelStyle = .rounded
		checkForUpdatesButton.target = self
		checkForUpdatesButton.action = #selector(checkForUpdates)
		installUpdateButton.bezelStyle = .rounded
		installUpdateButton.bezelColor = .controlAccentColor
		installUpdateButton.target = self
		installUpdateButton.action = #selector(installUpdate)
		installUpdateButton.isHidden = true
		autoUpdateSwitch.target = self
		autoUpdateSwitch.action = #selector(autoUpdateChanged)
		autoUpdateSwitch.setAccessibilityLabel("Automatically check for updates")

		updateStatusLabel.font = .systemFont(ofSize: 12)
		updateStatusLabel.textColor = .secondaryLabelColor
		updateStatusLabel.maximumNumberOfLines = 0
	}

	private func generalPaneContent() -> [NSView] {
		let startRow = SettingsRowView(
			title: "Start at Login",
			subtitle: "Bring Glance back after you sign in.",
			control: startAtLoginSwitch,
			showsTopSeparator: false,
		)

		let issueContent = NSStackView(views: [loginItemStatusLabel, openLoginItemsButton])
		issueContent.orientation = .horizontal
		issueContent.alignment = .centerY
		issueContent.spacing = 12
		loginItemStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
		openLoginItemsButton.setContentHuggingPriority(.required, for: .horizontal)
		let issueRow = SettingsRowView(
			content: issueContent,
			showsTopSeparator: true,
		)
		issueRow.isHidden = true
		loginItemIssueRow = issueRow

		let card = SettingsCardView(rows: [startRow, issueRow])
		return [card]
	}

	private func appearancePaneContent() -> [NSView] {
		let fontRow = SettingsRowView(
			title: "Font",
			control: fontFamilyPopUpButton,
			showsTopSeparator: false,
		)
		let sizeControl = NSStackView(views: [fontSizeField, fontSizeStepper])
		sizeControl.orientation = .horizontal
		sizeControl.alignment = .centerY
		sizeControl.spacing = 6
		let sizeRow = SettingsRowView(
			title: "Size",
			control: sizeControl,
			showsTopSeparator: true,
		)
		let wrappingRow = SettingsRowView(
			title: "Wrap long lines",
			control: lineWrappingSwitch,
			showsTopSeparator: true,
		)
		let card = SettingsCardView(rows: [fontRow, sizeRow, wrappingRow])

		let resetRow = SettingsRowView(
			title: "Reset to Defaults",
			subtitle: "Back to system font, 14 pt, no wrapping.",
			control: resetAppearanceButton,
			showsTopSeparator: false,
		)
		let resetCard = SettingsCardView(rows: [resetRow])

		let hint = makeHint("Existing previews keep the appearance they opened with.")
		return [card, specimenView, resetCard, hint]
	}

	private func audioPaneContent() -> [NSView] {
		let row = SettingsRowView(
			title: "Show waveform",
			subtitle: "A waveform overview appears in new previews.",
			control: flacWaveformSwitch,
			showsTopSeparator: false,
		)
		let card = SettingsCardView(rows: [row])
		return [card]
	}

	private func updatesPaneContent() -> [NSView] {
		let actionSpacer = NSView()
		actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		actionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let actionRow = NSStackView(
			views: [actionSpacer, checkForUpdatesButton, installUpdateButton],
		)
		actionRow.orientation = .horizontal
		actionRow.alignment = .centerY
		actionRow.spacing = 8
		let statusContent = NSStackView(views: [updateStatusLabel, actionRow])
		statusContent.orientation = .vertical
		statusContent.alignment = .leading
		statusContent.spacing = 10
		updateStatusLabel.widthAnchor.constraint(equalTo: statusContent.widthAnchor).isActive = true
		actionRow.widthAnchor.constraint(equalTo: statusContent.widthAnchor).isActive = true
		let statusCard = SettingsCardView(content: statusContent)

		let autoRow = SettingsRowView(
			title: "Automatically check",
			subtitle: "Runs in the background.",
			control: autoUpdateSwitch,
			showsTopSeparator: false,
		)
		let autoCard = SettingsCardView(rows: [autoRow])

		let releaseNotesButton = NSButton(
			title: "Release notes",
			target: self,
			action: #selector(openReleaseNotes),
		)
		releaseNotesButton.bezelStyle = .inline
		releaseNotesButton.isBordered = false
		releaseNotesButton.contentTintColor = .linkColor
		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let footer = NSStackView(views: [spacer, releaseNotesButton])
		footer.orientation = .horizontal
		footer.alignment = .centerY
		footer.spacing = 8
		return [statusCard, autoCard, footer]
	}

	private func aboutPaneContent() -> [NSView] {
		let icon = NSImageView()
		icon.image = NSApp.applicationIconImage
		icon.imageScaling = .scaleProportionallyUpOrDown
		icon.translatesAutoresizingMaskIntoConstraints = false
		icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
		icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
		icon.setAccessibilityLabel("Glance")

		let name = NSTextField(labelWithString: "Glance")
		name.font = .systemFont(ofSize: 22, weight: .semibold)
		name.alignment = .center

		let versionLabel = NSTextField(
			labelWithString: "Version \(AppMetadata.versionLine)",
		)
		versionLabel.font = .systemFont(ofSize: 10, weight: .medium)
		versionLabel.textColor = .secondaryLabelColor
		versionLabel.translatesAutoresizingMaskIntoConstraints = false
		let versionBadge = NSBox()
		versionBadge.boxType = .custom
		versionBadge.titlePosition = .noTitle
		versionBadge.borderWidth = 0
		versionBadge.cornerRadius = 8
		versionBadge.fillColor = .controlBackgroundColor
		versionBadge.translatesAutoresizingMaskIntoConstraints = false
		versionBadge.addSubview(versionLabel)
		NSLayoutConstraint.activate([
			versionLabel.topAnchor.constraint(equalTo: versionBadge.topAnchor, constant: 3),
			versionLabel.leadingAnchor.constraint(equalTo: versionBadge.leadingAnchor, constant: 9),
			versionLabel.trailingAnchor.constraint(
				equalTo: versionBadge.trailingAnchor,
				constant: -9,
			),
			versionLabel.bottomAnchor.constraint(equalTo: versionBadge.bottomAnchor, constant: -3),
		])

		let meta = NSTextField(
			labelWithString: "macOS 26 · Apple silicon",
		)
		meta.font = .systemFont(ofSize: 10)
		meta.textColor = .secondaryLabelColor
		meta.alignment = .center

		let links = [
			aboutLinkButton("GitHub", symbol: "link", tag: 0),
			aboutLinkButton("License", symbol: "key", tag: 1),
			aboutLinkButton("Acknowledgements", symbol: "person.2", tag: 2),
			aboutLinkButton("Privacy", symbol: "hand.raised", tag: 3),
		]
		aboutLinkButtons = links
		let firstRow = NSStackView(views: [links[0], links[1]])
		firstRow.orientation = .horizontal
		firstRow.distribution = .fillEqually
		firstRow.spacing = 8
		let secondRow = NSStackView(views: [links[2], links[3]])
		secondRow.orientation = .horizontal
		secondRow.distribution = .fillEqually
		secondRow.spacing = 8
		let linkGrid = NSStackView(views: [firstRow, secondRow])
		linkGrid.orientation = .vertical
		linkGrid.alignment = .leading
		linkGrid.spacing = 8

		let copyright = NSTextField(labelWithString: AppMetadata.copyright)
		copyright.font = .systemFont(ofSize: 10)
		copyright.textColor = .secondaryLabelColor
		copyright.alignment = .center

		let content = NSStackView(views: [
			icon,
			name,
			versionBadge,
			meta,
			linkGrid,
			copyright,
		])
		content.orientation = .vertical
		content.alignment = .centerX
		content.spacing = 4
		content.setCustomSpacing(10, after: icon)
		content.setCustomSpacing(2, after: name)
		content.setCustomSpacing(8, after: versionBadge)
		content.setCustomSpacing(16, after: meta)
		content.setCustomSpacing(16, after: linkGrid)

		let container = NSView()
		container.translatesAutoresizingMaskIntoConstraints = false
		content.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			content.topAnchor.constraint(equalTo: container.topAnchor),
			content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
			firstRow.widthAnchor.constraint(equalTo: linkGrid.widthAnchor),
			secondRow.widthAnchor.constraint(equalTo: linkGrid.widthAnchor),
		])
		let preferredGridWidth = linkGrid.widthAnchor.constraint(equalToConstant: 340)
		preferredGridWidth.priority = .defaultHigh
		preferredGridWidth.isActive = true
		linkGrid.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
		return [container]
	}

	private func aboutLinkButton(_ title: String, symbol: String, tag: Int) -> NSButton {
		let button = NSButton(
			title: title,
			target: self,
			action: #selector(openAboutLink(_:)),
		)
		button.bezelStyle = .rounded
		button.image = NSImage(
			systemSymbolName: symbol,
			accessibilityDescription: nil,
		)
		button.imagePosition = .imageLeading
		button.tag = tag
		button.setAccessibilityLabel(title)
		return button
	}

	@objc
	private func openAboutLink(_ sender: NSButton) {
		guard aboutLinkURLs.indices.contains(sender.tag) else {
			return
		}
		aboutLinkURLs[sender.tag].open()
	}

	private func makeHint(_ text: String) -> NSTextField {
		let label = NSTextField(wrappingLabelWithString: text)
		label.font = .systemFont(ofSize: 11)
		label.textColor = .secondaryLabelColor
		label.maximumNumberOfLines = 0
		return label
	}

	private func syncSpecimen() {
		let appearance = settingsStore.previewAppearance
		specimenView.update(
			fontFamily: appearance.fontFamily,
			fontSize: appearance.fontSize,
			wrapsLines: appearance.wrapsLines,
		)
	}

	@objc
	private func settingsSearchChanged(_ sender: NSSearchField) {
		let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
			.localizedLowercase
		if query.isEmpty {
			visiblePanes = SettingsPane.allCases
		} else {
			visiblePanes = SettingsPane.allCases.filter { pane in
				searchableText(for: pane).contains(query)
			}
		}
		let paneToRestore = selectedPane
		sidebarTableView.reloadData()

		if visiblePanes.contains(paneToRestore) {
			selectPane(paneToRestore)
		} else if let first = visiblePanes.first {
			selectPane(first)
		} else {
			showNoResults()
		}
	}

	/// Search the actual labels and controls shown on each page so the index
	/// cannot drift from the UI. Page subtitles and keywords add synonyms.
	private func searchableText(for pane: SettingsPane) -> String {
		var parts = [pane.title, pane.subtitle, pane.keywords]
		if let view = paneViews[pane] {
			parts.append(contentsOf: textValues(in: view))
		}
		return parts.joined(separator: " ").localizedLowercase
	}

	private func textValues(in view: NSView) -> [String] {
		var values: [String] = []
		if let textField = view as? NSTextField, !textField.stringValue.isEmpty {
			values.append(textField.stringValue)
		}
		if let button = view as? NSButton, !button.title.isEmpty {
			values.append(button.title)
		}
		for subview in view.subviews {
			values.append(contentsOf: textValues(in: subview))
		}
		return values
	}

	private func showNoResults() {
		for view in paneViews.values {
			view.isHidden = true
		}
		noResultsLabel.isHidden = false
		sidebarTableView.deselectAll(nil)
	}

	// MARK: - State

	func syncState() {
		syncLoginItemState()
		if
			let fontFamily = settingsStore.previewFontFamily,
			let canonicalFontFamily = fontFamilyPopUpButton.itemTitles.first(where: {
				$0.caseInsensitiveCompare(fontFamily) == .orderedSame
			})
		{
			fontFamilyPopUpButton.selectItem(withTitle: canonicalFontFamily)
		} else {
			fontFamilyPopUpButton.selectItem(at: 0)
		}
		fontSizeField.doubleValue = settingsStore.previewFontSize
		fontSizeStepper.doubleValue = settingsStore.previewFontSize
		lineWrappingSwitch.state = settingsStore.previewLineWrapping ? .on : .off
		flacWaveformSwitch.state = settingsStore.flacWaveformEnabled ? .on : .off
		autoUpdateSwitch.state = SparkleUpdateCenter.shared.automaticChecksEnabled ? .on : .off
		checkForUpdatesButton.isEnabled = SparkleUpdateCenter.shared.canCheckForUpdates
		updateStatusLabel.stringValue = SparkleUpdateCenter.shared.statusText
		installUpdateButton.isHidden = !SparkleUpdateCenter.shared.installReady
		syncSpecimen()
	}

	@objc
	private func windowWillClose(_: Notification) {
		DispatchQueue.main.async {
			WindowAppearance.refreshActivationPolicy()
		}
	}

	@objc
	private func updateStatusDidChange(_ notification: Notification) {
		let userInfo = notification.userInfo ?? [:]
		if
			let statusText = userInfo["statusText"] as? String,
			let installReady = userInfo["installReady"] as? Bool
		{
			updateStatusLabel.stringValue = statusText
			installUpdateButton.isHidden = !installReady
		}
		if let canCheck = userInfo["canCheckForUpdates"] as? Bool {
			checkForUpdatesButton.isEnabled = canCheck
		}
	}

	private func syncLoginItemState(error: Error? = nil) {
		let status = loginItem.status
		startAtLoginSwitch.state = status == .enabled || status == .requiresApproval ? .on : .off
		let message = switch status {
			case .requiresApproval:
				"Allow Glance to start at login in System Settings."
			case .notFound:
				"The Glance login item is unavailable."
			case .enabled, .notRegistered:
				""
			@unknown default:
				"The Glance login item status is unknown."
		}
		loginItemStatusLabel.stringValue = error.map {
			"Couldn’t update Start at Login: \($0.localizedDescription)"
		} ?? message
		loginItemStatusLabel.isHidden = loginItemStatusLabel.stringValue.isEmpty
		openLoginItemsButton.isHidden = status != .requiresApproval && error == nil
		loginItemIssueRow?.isHidden =
			loginItemStatusLabel.isHidden && openLoginItemsButton.isHidden
	}

	@objc
	private func startAtLoginChanged(_ sender: NSSwitch) {
		do {
			if sender.state == .on {
				try loginItem.register()
			} else {
				try loginItem.unregister()
			}
			syncLoginItemState()
		} catch {
			syncLoginItemState(error: error)
		}
	}

	@objc
	private func openLoginItemsSettings(_: NSButton) {
		loginItem.openSystemSettings()
	}

	@objc
	private func fontFamilyChanged(_ sender: NSPopUpButton) {
		settingsStore.previewFontFamily = sender.indexOfSelectedItem == 0
			? nil
			: sender.titleOfSelectedItem
		syncSpecimen()
	}

	@objc
	private func fontSizeChanged(_ sender: NSTextField) {
		settingsStore.previewFontSize = sender.doubleValue
		fontSizeField.doubleValue = settingsStore.previewFontSize
		fontSizeStepper.doubleValue = settingsStore.previewFontSize
		syncSpecimen()
	}

	@objc
	private func fontSizeStepperChanged(_ sender: NSStepper) {
		settingsStore.previewFontSize = sender.doubleValue
		fontSizeField.doubleValue = settingsStore.previewFontSize
		syncSpecimen()
	}

	@objc
	private func lineWrappingChanged(_ sender: NSSwitch) {
		settingsStore.previewLineWrapping = sender.state == .on
		syncSpecimen()
	}

	@objc
	private func flacWaveformChanged(_ sender: NSSwitch) {
		settingsStore.flacWaveformEnabled = sender.state == .on
	}

	@objc
	private func resetAppearance(_: NSButton) {
		settingsStore.resetPreviewAppearance()
		syncState()
	}

	@objc
	private func checkForUpdates(_: NSButton) {
		SparkleUpdateCenter.shared.checkForUpdates()
	}

	@objc
	private func installUpdate(_: NSButton) {
		SparkleUpdateCenter.shared.installNow()
	}

	@objc
	private func autoUpdateChanged(_ sender: NSSwitch) {
		SparkleUpdateCenter.shared.setAutomaticChecksEnabled(sender.state == .on)
	}

	@objc
	private func openReleaseNotes(_: NSButton) {
		AppLinks.releases.open()
	}
}

extension SettingsWC: NSTableViewDataSource, NSTableViewDelegate {
	func numberOfRows(in _: NSTableView) -> Int {
		visiblePanes.count
	}

	func tableView(
		_ tableView: NSTableView,
		viewFor _: NSTableColumn?,
		row: Int,
	) -> NSView? {
		let identifier = NSUserInterfaceItemIdentifier("Settings.Sidebar.Cell")
		let cell = tableView.makeView(withIdentifier: identifier, owner: self)
			as? SettingsSidebarCell ?? SettingsSidebarCell()
		cell.identifier = identifier
		cell.configure(pane: visiblePanes[row])
		return cell
	}

	func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
		SidebarSelectionRowView(frame: .zero)
	}

	func tableViewSelectionDidChange(_: Notification) {
		guard visiblePanes.indices.contains(sidebarTableView.selectedRow) else {
			return
		}
		selectPane(visiblePanes[sidebarTableView.selectedRow])
	}
}

private final class SettingsSidebarCell: NSTableCellView {
	private let iconView = NSImageView()
	private let titleLabel = NSTextField(labelWithString: "")

	init() {
		super.init(frame: .zero)
		iconView.translatesAutoresizingMaskIntoConstraints = false
		iconView.imageScaling = .scaleProportionallyDown
		iconView.contentTintColor = .secondaryLabelColor
		titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
		titleLabel.lineBreakMode = .byTruncatingTail
		titleLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(iconView)
		addSubview(titleLabel)
		imageView = iconView
		textField = titleLabel
		NSLayoutConstraint.activate([
			iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
			iconView.widthAnchor.constraint(equalToConstant: 16),
			iconView.heightAnchor.constraint(equalToConstant: 16),
			titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
			titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func configure(pane: SettingsPane) {
		titleLabel.stringValue = pane.title
		iconView.image = NSImage(
			systemSymbolName: pane.symbolName,
			accessibilityDescription: pane.title,
		)
		setAccessibilityLabel(pane.title)
	}

	override var backgroundStyle: NSView.BackgroundStyle {
		didSet {
			let isSelected = backgroundStyle == .emphasized
			titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
			iconView.contentTintColor = isSelected
				? .alternateSelectedControlTextColor
				: .secondaryLabelColor
		}
	}
}

private final class SettingsRowView: NSView {
	init(
		title: String,
		subtitle: String? = nil,
		control: NSView,
		showsTopSeparator: Bool,
	) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false

		let titleLabel = NSTextField(wrappingLabelWithString: title)
		titleLabel.font = .systemFont(ofSize: 13)
		titleLabel.maximumNumberOfLines = 0
		titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let labels = NSStackView(views: [titleLabel])
		labels.orientation = .vertical
		labels.alignment = .leading
		labels.spacing = 2
		labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		titleLabel.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor).isActive = true
		if let subtitle {
			let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
			subtitleLabel.font = .systemFont(ofSize: 10.5)
			subtitleLabel.textColor = .secondaryLabelColor
			subtitleLabel.maximumNumberOfLines = 0
			subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
			labels.addArrangedSubview(subtitleLabel)
			subtitleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
		}
		labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
		control.setContentHuggingPriority(.required, for: .horizontal)
		control.setContentCompressionResistancePriority(.required, for: .horizontal)
		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

		let row = NSStackView(views: [labels, spacer, control])
		row.orientation = .horizontal
		row.alignment = .centerY
		row.spacing = 0
		row.setCustomSpacing(16, after: labels)
		row.translatesAutoresizingMaskIntoConstraints = false
		addSubview(row)

		NSLayoutConstraint.activate([
			row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
			row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
			heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
		])

		if showsTopSeparator {
			addSeparator()
		}
	}

	init(content: NSView, showsTopSeparator: Bool) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			content.topAnchor.constraint(equalTo: topAnchor, constant: 9),
			content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
			heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
		])
		if showsTopSeparator {
			addSeparator()
		}
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private func addSeparator() {
		let separator = NSBox()
		separator.boxType = .separator
		separator.translatesAutoresizingMaskIntoConstraints = false
		addSubview(separator)
		NSLayoutConstraint.activate([
			separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			separator.heightAnchor.constraint(equalToConstant: 1),
			separator.topAnchor.constraint(equalTo: topAnchor),
		])
	}
}

private final class SettingsCardView: NSView {
	init(rows: [NSView]) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		setAccessibilityRole(.group)
		let stack = NSStackView(views: rows)
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 0
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		for row in rows {
			row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
		}
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	init(content: NSView) {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		setAccessibilityRole(.group)
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			content.topAnchor.constraint(equalTo: topAnchor, constant: 13),
			content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func draw(_: NSRect) {
		let path = NSBezierPath(
			roundedRect: bounds,
			xRadius: 10,
			yRadius: 10,
		)
		NSColor.labelColor.withAlphaComponent(0.06).setFill()
		path.fill()
	}
}

private final class PreviewSpecimenView: NSView {
	private let textField = NSTextField(wrappingLabelWithString: "")

	init() {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		setAccessibilityRole(.group)
		setAccessibilityLabel("Live preview specimen")

		let title = NSTextField(labelWithString: "Preview")
		title.font = .systemFont(ofSize: 9, weight: .semibold)
		title.textColor = .secondaryLabelColor
		let aa = NSTextField(labelWithString: "Aa")
		aa.font = NSFont(name: "Georgia-Italic", size: 10) ?? .systemFont(ofSize: 10)
		aa.textColor = .secondaryLabelColor
		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let header = NSStackView(views: [title, spacer, aa])
		header.orientation = .horizontal
		header.alignment = .centerY
		header.spacing = 8
		header.translatesAutoresizingMaskIntoConstraints = false

		textField.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
		textField.textColor = .labelColor
		textField.maximumNumberOfLines = 0
		textField.isSelectable = false
		textField.translatesAutoresizingMaskIntoConstraints = false

		addSubview(header)
		addSubview(textField)
		NSLayoutConstraint.activate([
			header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
			header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
			header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
			textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
			textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
			textField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
			textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
			heightAnchor.constraint(greaterThanOrEqualToConstant: 86),
		])
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func update(fontFamily: String?, fontSize: Double, wrapsLines: Bool) {
		let font = fontFamily.flatMap { family in
			NSFont(name: family, size: fontSize)
				?? NSFontManager.shared.font(
					withFamily: family,
					traits: [],
					weight: 5,
					size: fontSize,
				)
		} ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
		textField.font = font
		textField.cell?.wraps = wrapsLines
		textField.cell?.isScrollable = false
		textField.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
		textField.maximumNumberOfLines = 0
		textField.stringValue = "struct Eye {\n    let iris = \"blue\"\n}"
		needsDisplay = true
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		needsDisplay = true
	}

	override func draw(_: NSRect) {
		let path = NSBezierPath(
			roundedRect: bounds,
			xRadius: 8,
			yRadius: 8,
		)
		NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
		path.fill()
	}
}
