import AppKit
import GlanceKit
import ServiceManagement
import XCTest

@MainActor
private final class StubLoginItem: LoginItemManaging {
	var status: SMAppService.Status = .notRegistered
	var registrationError: Error?
	var unregistrationError: Error?
	var registerCount = 0
	var unregisterCount = 0
	var openedSystemSettings = false

	func register() throws {
		registerCount += 1
		if let registrationError {
			throw registrationError
		}
		status = .enabled
	}

	func unregister() throws {
		unregisterCount += 1
		if let unregistrationError {
			throw unregistrationError
		}
		status = .notRegistered
	}

	func openSystemSettings() {
		openedSystemSettings = true
	}
}

@MainActor
final class WindowAppearanceTests: XCTestCase {
	func testPreviewAppearancePreferencesUseStableDefaultsAndPersistCustomValues() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

		XCTAssertEqual(store.previewAppearance, .default)

		store.previewFontFamily = "Menlo"
		store.previewFontSize = 18
		store.previewLineWrapping = true

		XCTAssertEqual(
			store.previewAppearance,
			PreviewAppearancePreferences(fontFamily: "Menlo", fontSize: 18, wrapsLines: true),
		)
	}

	func testFLACWaveformPreferenceDefaultsOnAndCanBeDisabled() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
		XCTAssertTrue(store.flacWaveformEnabled)

		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		XCTAssertEqual(controller.flacWaveformSwitch.state, .on)
		toggle(controller.flacWaveformSwitch)
		XCTAssertFalse(store.flacWaveformEnabled)
		controller.syncState()
		XCTAssertEqual(controller.flacWaveformSwitch.state, .off)
	}

	func testSettingsShowsSoftwareUpdateSection() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		controller.loadWindow()
		controller.selectPane(.updates)
		let labels = allTextFields(in: try XCTUnwrap(controller.window?.contentView))
		XCTAssertEqual(controller.selectedPane, .updates)
		XCTAssertTrue(labels.contains { $0.stringValue == "Updates" })
		XCTAssertTrue(labels.contains { $0.stringValue == "Automatically check" })
		XCTAssertNotNil(controller.checkForUpdatesButton)
		XCTAssertNotNil(controller.updateStatusLabel)
	}

	func testPreviewAppearancePreferencesRejectInvalidStoredValuesAndReset() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

		store.previewFontFamily = "Menlo"
		store.previewFontSize = .infinity
		store.previewLineWrapping = true

		XCTAssertEqual(store.previewFontFamily, "Menlo")
		XCTAssertEqual(store.previewFontSize, PreviewAppearancePreferences.default.fontSize)

		store.previewFontFamily = "Menlo"
		store.previewFontSize = 72
		store.resetPreviewAppearance()

		XCTAssertEqual(store.previewAppearance, .default)
	}

	func testPreviewAppearanceSettingsMigrateWithoutOverwritingSharedValues() throws {
		let sharedSuiteName = "GlanceTests.Shared.\(UUID().uuidString)"
		let standardSuiteName = "GlanceTests.Standard.\(UUID().uuidString)"
		let sharedDefaults = try XCTUnwrap(UserDefaults(suiteName: sharedSuiteName))
		let standardDefaults = try XCTUnwrap(UserDefaults(suiteName: standardSuiteName))
		defer {
			sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
			standardDefaults.removePersistentDomain(forName: standardSuiteName)
		}

		standardDefaults.set("Menlo", forKey: AppSettingsStore.previewFontFamilyKey)
		standardDefaults.set(17.0, forKey: AppSettingsStore.previewFontSizeKey)
		standardDefaults.set(true, forKey: AppSettingsStore.previewLineWrappingKey)
		sharedDefaults.set(15.0, forKey: AppSettingsStore.previewFontSizeKey)
		let store = AppSettingsStore(
			defaults: sharedDefaults,
			standardDefaults: standardDefaults,
		)

		store.migrateStandardDefaultsIfNeeded()

		XCTAssertEqual(store.previewFontFamily, "Menlo")
		XCTAssertEqual(store.previewFontSize, 15)
		XCTAssertTrue(store.previewLineWrapping)
	}

	func testSettingsWindowEditsAndResetsPreviewAppearance() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		store.previewFontFamily = "Menlo"
		store.previewFontSize = 16
		store.previewLineWrapping = true
		let controller = SettingsWC(
			settingsStore: store,
			fontFamilies: ["Helvetica", "Menlo"],
		)

		controller.syncState()

		XCTAssertEqual(controller.fontFamilyPopUpButton.titleOfSelectedItem, "Menlo")
		XCTAssertEqual(controller.fontSizeField.doubleValue, 16)
		XCTAssertEqual(controller.lineWrappingSwitch.state, .on)

		controller.fontFamilyPopUpButton.selectItem(withTitle: "Helvetica")
		controller.fontFamilyPopUpButton.sendAction(
			controller.fontFamilyPopUpButton.action,
			to: controller.fontFamilyPopUpButton.target,
		)
		controller.fontSizeField.doubleValue = 19
		controller.fontSizeField.sendAction(
			controller.fontSizeField.action,
			to: controller.fontSizeField.target,
		)
		toggle(controller.lineWrappingSwitch)

		XCTAssertEqual(store.previewFontFamily, "Helvetica")
		XCTAssertEqual(store.previewFontSize, 19)
		XCTAssertFalse(store.previewLineWrapping)

		controller.resetAppearanceButton.performClick(nil)

		XCTAssertEqual(store.previewAppearance, .default)
		XCTAssertEqual(controller.fontFamilyPopUpButton.indexOfSelectedItem, 0)
		XCTAssertEqual(
			controller.fontSizeField.doubleValue,
			PreviewAppearancePreferences.defaultFontSize,
		)
		XCTAssertEqual(controller.lineWrappingSwitch.state, .off)
	}

	func testSettingsWindowCanonicalizesPersistedFontFamilyCasing() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		store.previewFontFamily = "menlo"
		let controller = SettingsWC(settingsStore: store, fontFamilies: ["Menlo"])

		controller.syncState()

		XCTAssertEqual(controller.fontFamilyPopUpButton.titleOfSelectedItem, "Menlo")
	}

	func testSettingsControlsRemainReachableAtMinimumWindowSize() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		let loginItem = StubLoginItem()
		let controller = SettingsWC(
			settingsStore: store,
			fontFamilies: ["Menlo"],
			loginItem: loginItem,
		)
		let window = try XCTUnwrap(controller.window)
		window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
		loginItem.status = .requiresApproval
		controller.syncState()
		NotificationCenter.default.post(
			name: SparkleUpdateCenter.statusDidChangeNotification,
			object: nil,
			userInfo: ["statusText": "An update is ready to install.", "installReady": true],
		)
		let content = try XCTUnwrap(window.contentView)
		content.layoutSubtreeIfNeeded()

		let controlsByPane: [SettingsPane: [NSControl]] = [
			.general: [
				controller.startAtLoginSwitch,
				controller.loginItemStatusLabel,
				controller.openLoginItemsButton,
			],
			.appearance: [
				controller.fontFamilyPopUpButton,
				controller.fontSizeField,
				controller.lineWrappingSwitch,
				controller.resetAppearanceButton,
			],
			.audio: [controller.flacWaveformSwitch],
			.updates: [
				controller.checkForUpdatesButton,
				controller.installUpdateButton,
				controller.autoUpdateSwitch,
			],
		]

		for pane in SettingsPane.allCases {
			controller.selectPane(pane)
			content.layoutSubtreeIfNeeded()
			let scrollView = try XCTUnwrap(controller.activePaneScrollView)
			XCTAssertFalse(scrollView.isHidden)
			let viewport = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
			XCTAssertGreaterThan(viewport.width, 0)
			XCTAssertGreaterThan(viewport.height, 0)
			for control in controlsByPane[pane] ?? [] {
				XCTAssertFalse(control.isHidden, "Hidden control: \(control) in \(pane)")
				control.scrollToVisible(control.bounds)
				content.layoutSubtreeIfNeeded()
				let frame = control.convert(control.bounds, to: nil)
				XCTAssertTrue(
					viewport.insetBy(dx: -1, dy: -1).contains(frame),
					"Unreachable control: \(control) in \(pane)",
				)
				XCTAssertGreaterThanOrEqual(
					control.frame.height,
					control.intrinsicContentSize.height - 1,
				)
			}
		}

		controller.selectPane(.general)
		loginItem.status = .notRegistered
		controller.syncState()
		NotificationCenter.default.post(
			name: SparkleUpdateCenter.statusDidChangeNotification,
			object: nil,
			userInfo: ["statusText": "You’re up to date.", "installReady": false],
		)
		content.layoutSubtreeIfNeeded()
		XCTAssertTrue(controller.loginItemStatusLabel.isHidden)
		XCTAssertTrue(controller.openLoginItemsButton.isHidden)
		controller.selectPane(.updates)
		content.layoutSubtreeIfNeeded()
		XCTAssertTrue(controller.installUpdateButton.isHidden)
	}

	func testStartAtLoginRegistersAndUnregistersTheMainApp() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		let loginItem = StubLoginItem()
		let controller = SettingsWC(
			settingsStore: store,
			fontFamilies: [],
			loginItem: loginItem,
		)

		XCTAssertEqual(controller.startAtLoginSwitch.state, .off)
		toggle(controller.startAtLoginSwitch)
		XCTAssertEqual(loginItem.registerCount, 1)
		XCTAssertEqual(controller.startAtLoginSwitch.state, .on)

		toggle(controller.startAtLoginSwitch)
		XCTAssertEqual(loginItem.unregisterCount, 1)
		XCTAssertEqual(controller.startAtLoginSwitch.state, .off)
	}

	func testStartAtLoginReflectsSystemApprovalAndExternalChanges() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		let loginItem = StubLoginItem()
		let controller = SettingsWC(
			settingsStore: store,
			fontFamilies: [],
			loginItem: loginItem,
		)

		loginItem.status = .requiresApproval
		controller.syncState()
		XCTAssertEqual(controller.startAtLoginSwitch.state, .on)
		XCTAssertFalse(controller.loginItemStatusLabel.isHidden)
		XCTAssertFalse(controller.openLoginItemsButton.isHidden)
		controller.openLoginItemsButton.performClick(nil)
		XCTAssertTrue(loginItem.openedSystemSettings)

		loginItem.status = .notRegistered
		controller.syncState()
		XCTAssertEqual(controller.startAtLoginSwitch.state, .off)
		XCTAssertTrue(controller.loginItemStatusLabel.isHidden)
		XCTAssertTrue(controller.openLoginItemsButton.isHidden)
	}

	func testStartAtLoginFailuresRestoreTheSystemState() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		let loginItem = StubLoginItem()
		let controller = SettingsWC(
			settingsStore: store,
			fontFamilies: [],
			loginItem: loginItem,
		)
		loginItem.registrationError = NSError(domain: "GlanceTests", code: 1)
		toggle(controller.startAtLoginSwitch)
		XCTAssertEqual(controller.startAtLoginSwitch.state, .off)
		XCTAssertFalse(controller.loginItemStatusLabel.isHidden)
		XCTAssertFalse(controller.openLoginItemsButton.isHidden)

		loginItem.registrationError = nil
		loginItem.status = .enabled
		loginItem.unregistrationError = NSError(domain: "GlanceTests", code: 2)
		controller.syncState()
		toggle(controller.startAtLoginSwitch)
		XCTAssertEqual(controller.startAtLoginSwitch.state, .on)
		XCTAssertFalse(controller.loginItemStatusLabel.isHidden)
	}

	func testWindowAppearanceUsesOneAdaptiveMaterialBackground() throws {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false,
		)

		let firstMaterialView = try XCTUnwrap(WindowAppearance.apply(to: window))
		let secondMaterialView = try XCTUnwrap(WindowAppearance.apply(to: window))

		XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
		XCTAssertTrue(window.titlebarAppearsTransparent)
		XCTAssertFalse(window.isOpaque)
		XCTAssertEqual(window.backgroundColor, .clear)
		XCTAssertIdentical(firstMaterialView, secondMaterialView)
		XCTAssertEqual(
			window.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.count,
			1,
		)
		XCTAssertEqual(firstMaterialView.material, .underWindowBackground)
		XCTAssertEqual(firstMaterialView.blendingMode, .behindWindow)
		XCTAssertEqual(firstMaterialView.state, .followsWindowActiveState)
	}

	func testSupportedFilesWindowContainsEveryStructuredSection() throws {
		let controller = SupportedFilesWC()
		let window = try XCTUnwrap(controller.window)

		XCTAssertTrue(window.styleMask.contains(.resizable))
		XCTAssertGreaterThanOrEqual(window.minSize.width, 560)
		XCTAssertGreaterThanOrEqual(window.minSize.height, 380)
		XCTAssertEqual(
			controller.categoryTableView.numberOfRows,
			SupportedFilesWC.sections.count,
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.map(\.title),
			[
				"Audio",
				"Source Code",
				"Markdown",
				"Diagrams",
				"Archive",
				"E-books",
				"Jupyter Notebook",
				"Tab-separated Values",
				"Spreadsheet",
				"Database",
				"Structured Data",
				"Folders",
			],
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Tab-separated Values" }?.details,
			".tab, .tsv",
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Spreadsheet" }?.details,
			".xlsx • Values, dates, and every worksheet",
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Database" }?.details,
			".sqlite, .sqlite3, .db • Read-only tables with typed columns",
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Structured Data" }?.details,
			".json, .plist, .xml • Collapsible trees, typed values, and truncation notices",
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Folders" }?.details,
			"Lazy trees with icons, thumbnails, 500-item pages, and Back navigation",
		)
	}

	func testSupportedFilesDetailFollowsSelectionAndSearch() {
		let controller = SupportedFilesWC()
		controller.loadWindow()

		controller.selectSection(at: 1)
		XCTAssertEqual(controller.selectedSectionIndex, 1)
		XCTAssertEqual(controller.detailTitleLabel.stringValue, "Source Code")
		XCTAssertEqual(
			controller.detailSummaryLabel.stringValue,
			"Syntax highlighting for these and many more.",
		)
		XCTAssertEqual(controller.detailSummaryLabel.maximumNumberOfLines, 0)
		XCTAssertTrue(controller.formatsValueLabel.stringValue.contains(".swift"))
		XCTAssertEqual(controller.detailTitleLabel.accessibilityLabel(), "Source Code")
		XCTAssertEqual(
			controller.formatsValueLabel.accessibilityLabel(),
			SupportedFilesWC.sections[1].formats.joined(separator: ", "),
		)

		controller.selectSection(at: 11)
		XCTAssertEqual(controller.detailTitleLabel.stringValue, "Folders")
		XCTAssertTrue(controller.formatsValueLabel.stringValue.isEmpty)
		XCTAssertFalse(controller.isFormatsSectionVisible)

		controller.searchField.stringValue = "sql"
		controller.searchField.sendAction(
			controller.searchField.action,
			to: controller.searchField.target,
		)
		XCTAssertEqual(controller.categoryTableView.numberOfRows, 1)
		XCTAssertEqual(controller.selectedSectionIndex, 9)
		XCTAssertEqual(controller.detailTitleLabel.stringValue, "Database")

		controller.searchField.stringValue = "zzzz"
		controller.searchField.sendAction(
			controller.searchField.action,
			to: controller.searchField.target,
		)
		XCTAssertEqual(controller.categoryTableView.numberOfRows, 0)
		XCTAssertNil(controller.selectedSectionIndex)
		XCTAssertFalse(controller.emptyStateLabel.isHidden)
		XCTAssertFalse(controller.isDetailVisible)

		controller.searchField.stringValue = ""
		controller.searchField.sendAction(
			controller.searchField.action,
			to: controller.searchField.target,
		)
		XCTAssertEqual(controller.categoryTableView.numberOfRows, 12)
		XCTAssertEqual(controller.selectedSectionIndex, 0)
		XCTAssertTrue(controller.emptyStateLabel.isHidden)
		XCTAssertTrue(controller.isDetailVisible)
	}

	func testSettingsAboutPaneShowsIdentityAndLinks() throws {
		let store = try makeSettingsStore().0
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		controller.loadWindow()
		controller.selectPane(.about)

		XCTAssertEqual(controller.selectedPane, .about)
		let contentView = try XCTUnwrap(controller.window?.contentView)
		let labels = allTextFields(in: contentView).map(\.stringValue)
		XCTAssertTrue(labels.contains("Glance"))
		XCTAssertTrue(labels.contains { $0.contains(AppMetadata.version) })
		XCTAssertEqual(
			controller.aboutLinkButtons.map(\.title),
			["GitHub", "License", "Acknowledgements", "Privacy"],
		)
	}

	func testUtilityWindowsShowOnlyCloseButton() throws {
		let store = try makeSettingsStore().0
		let windows = [
			try XCTUnwrap(SettingsWC(settingsStore: store, fontFamilies: []).window),
			try XCTUnwrap(SupportedFilesWC().window),
		]
		for window in windows {
			XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden ?? true)
			if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
				XCTAssertTrue(minimizeButton.isHidden)
			}
			if let zoomButton = window.standardWindowButton(.zoomButton) {
				XCTAssertTrue(zoomButton.isHidden)
			}
		}
	}

	func testSettingsSearchMatchesVisibleLabelsAndShowsNoResults() throws {
		let store = try makeSettingsStore().0
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		controller.loadWindow()

		search(controller, "Start at Login")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, 1)
		XCTAssertEqual(controller.selectedPane, .general)

		search(controller, "Wrap long lines")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, 1)
		XCTAssertEqual(controller.selectedPane, .appearance)

		search(controller, "Automatically check")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, 1)
		XCTAssertEqual(controller.selectedPane, .updates)

		search(controller, "Acknowledgements")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, 1)
		XCTAssertEqual(controller.selectedPane, .about)

		search(controller, "does-not-exist")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, 0)
		XCTAssertFalse(controller.noResultsLabel.isHidden)
		XCTAssertEqual(controller.selectedPane, .about)

		search(controller, "")
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, SettingsPane.allCases.count)
		XCTAssertTrue(controller.noResultsLabel.isHidden)
		XCTAssertEqual(controller.selectedPane, .about)
		XCTAssertFalse(controller.activePaneScrollView?.isHidden ?? true)
	}

	private func search(_ controller: SettingsWC, _ query: String) {
		controller.settingsSearchField.stringValue = query
		controller.settingsSearchField.sendAction(
			controller.settingsSearchField.action,
			to: controller.settingsSearchField.target,
		)
	}

	private func toggle(_ control: NSSwitch) {
		control.state = control.state == .on ? .off : .on
		control.sendAction(control.action, to: control.target)
	}

	private func allTextFields(in view: NSView) -> [NSTextField] {
		let directTextFields = view.subviews.compactMap { $0 as? NSTextField }
		return directTextFields + view.subviews.flatMap(allTextFields(in:))
	}

	private func allButtons(in view: NSView) -> [NSButton] {
		let directButtons = view.subviews.compactMap { $0 as? NSButton }
		return directButtons + view.subviews.flatMap(allButtons(in:))
	}

	private func makeSettingsStore() throws -> (AppSettingsStore, String) {
		let suiteName = "GlanceTests.Settings.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defaults.removePersistentDomain(forName: suiteName)
		return (AppSettingsStore(defaults: defaults), suiteName)
	}

	func testSettingsDoesNotOfferDockIconToggle() throws {
		let store = try makeSettingsStore().0
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		controller.loadWindow()
		let contentView = try XCTUnwrap(controller.window?.contentView)
		let labels = allTextFields(in: contentView).map(\.stringValue)
		let buttons = allButtons(in: contentView).map(\.title)

		XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("Show Dock") })
		XCTAssertFalse(buttons.contains { $0.localizedCaseInsensitiveContains("Dock icon") })
	}

	func testSettingsWindowIsResizableWithSaneMinimumSize() throws {
		let store = try makeSettingsStore().0
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		let window = try XCTUnwrap(controller.window)

		XCTAssertTrue(window.styleMask.contains(.resizable))
		XCTAssertEqual(window.minSize, NSSize(width: 560, height: 480))
	}

	func testSettingsSidebarNavigatesEveryPane() throws {
		let store = try makeSettingsStore().0
		let controller = SettingsWC(settingsStore: store, fontFamilies: [])
		controller.loadWindow()

		XCTAssertEqual(controller.selectedPane, .general)
		XCTAssertEqual(controller.sidebarTableView.numberOfRows, SettingsPane.allCases.count)

		for pane in SettingsPane.allCases {
			controller.sidebarTableView.selectRowIndexes(
				IndexSet(integer: pane.rawValue),
				byExtendingSelection: false,
			)
			XCTAssertEqual(controller.selectedPane, pane)
			XCTAssertFalse(controller.activePaneScrollView?.isHidden ?? true)
		}
	}
}
