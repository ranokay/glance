import AppKit
import XCTest

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
			PreviewAppearancePreferences(fontFamily: "Menlo", fontSize: 18, wrapsLines: true)
		)
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
			standardDefaults: standardDefaults
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
			fontFamilies: ["Helvetica", "Menlo"]
		)

		controller.syncState()

		XCTAssertEqual(controller.fontFamilyPopUpButton.titleOfSelectedItem, "Menlo")
		XCTAssertEqual(controller.fontSizeField.doubleValue, 16)
		XCTAssertEqual(controller.lineWrappingCheckbox.state, .on)

		controller.fontFamilyPopUpButton.selectItem(withTitle: "Helvetica")
		controller.fontFamilyPopUpButton.sendAction(
			controller.fontFamilyPopUpButton.action,
			to: controller.fontFamilyPopUpButton.target
		)
		controller.fontSizeField.doubleValue = 19
		controller.fontSizeField.sendAction(
			controller.fontSizeField.action,
			to: controller.fontSizeField.target
		)
		controller.lineWrappingCheckbox.performClick(nil)

		XCTAssertEqual(store.previewFontFamily, "Helvetica")
		XCTAssertEqual(store.previewFontSize, 19)
		XCTAssertFalse(store.previewLineWrapping)

		controller.resetAppearanceButton.performClick(nil)

		XCTAssertEqual(store.previewAppearance, .default)
		XCTAssertEqual(controller.fontFamilyPopUpButton.indexOfSelectedItem, 0)
		XCTAssertEqual(
			controller.fontSizeField.doubleValue,
			PreviewAppearancePreferences.defaultFontSize
		)
		XCTAssertEqual(controller.lineWrappingCheckbox.state, .off)
	}

	func testSettingsWindowCanonicalizesPersistedFontFamilyCasing() throws {
		let (store, suiteName) = try makeSettingsStore()
		defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
		store.previewFontFamily = "menlo"
		let controller = SettingsWC(settingsStore: store, fontFamilies: ["Menlo"])

		controller.syncState()

		XCTAssertEqual(controller.fontFamilyPopUpButton.titleOfSelectedItem, "Menlo")
	}

	func testWindowAppearanceUsesOneAdaptiveMaterialBackground() throws {
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
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
			1
		)
		XCTAssertEqual(firstMaterialView.material, .underWindowBackground)
		XCTAssertEqual(firstMaterialView.blendingMode, .behindWindow)
		XCTAssertEqual(firstMaterialView.state, .followsWindowActiveState)
	}

	func testSupportedFilesWindowContainsEveryStructuredSection() throws {
		let controller = SupportedFilesWC()
		let window = try XCTUnwrap(controller.window)

		XCTAssertTrue(window.styleMask.contains(.resizable))
		XCTAssertGreaterThanOrEqual(window.minSize.width, 420)
		XCTAssertGreaterThanOrEqual(window.minSize.height, 300)
		XCTAssertEqual(
			controller.sectionsStackView.arrangedSubviews.count,
			SupportedFilesWC.sections.count
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
				"Folders",
			]
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Tab-separated Values" }?.details,
			".tab, .tsv"
		)
		XCTAssertEqual(
			SupportedFilesWC.sections.first { $0.title == "Folders" }?.details,
			"Lazy trees with icons, thumbnails, 500-item pages, and Back navigation"
		)
	}

	func testSupportedFileDetailsWrapAndExposeAccessibilityLabels() throws {
		let controller = SupportedFilesWC()
		let labels = controller.sectionsStackView.arrangedSubviews
			.flatMap(allTextFields(in:))
		let sourceDetails = try XCTUnwrap(labels.first {
			$0.identifier?.rawValue == "SupportedFiles.Source Code.Details"
		})

		XCTAssertEqual(sourceDetails.maximumNumberOfLines, 0)
		XCTAssertEqual(sourceDetails.alignment, .center)
		XCTAssertEqual(sourceDetails.accessibilityLabel(), sourceDetails.stringValue)
	}

	private func allTextFields(in view: NSView) -> [NSTextField] {
		let directTextFields = view.subviews.compactMap { $0 as? NSTextField }
		return directTextFields + view.subviews.flatMap(allTextFields(in:))
	}

	private func makeSettingsStore() throws -> (AppSettingsStore, String) {
		let suiteName = "GlanceTests.Settings.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defaults.removePersistentDomain(forName: suiteName)
		return (AppSettingsStore(defaults: defaults), suiteName)
	}
}
