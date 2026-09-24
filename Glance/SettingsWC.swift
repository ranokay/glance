import Cocoa
import ServiceManagement

@MainActor
protocol DockIconVisibilityUpdating: AnyObject {
	func updateDockIconVisibility()
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

final class SettingsWC: NSWindowController {
	static let shared = SettingsWC(
		settingsStore: .shared,
		fontFamilies: NSFontManager.shared.availableFontFamilies
	)

	let fontFamilyPopUpButton = NSPopUpButton()
	let fontSizeField = NSTextField()
	let lineWrappingCheckbox = NSButton(
		checkboxWithTitle: "Wrap long lines",
		target: nil,
		action: nil
	)
	let flacWaveformCheckbox = NSButton(
		checkboxWithTitle: "Show FLAC waveform",
		target: nil,
		action: nil
	)
	let resetAppearanceButton = NSButton(
		title: "Reset Preview Appearance",
		target: nil,
		action: nil
	)
	let startAtLoginCheckbox = NSButton(
		checkboxWithTitle: "Start at Login",
		target: nil,
		action: nil
	)
	let loginItemStatusLabel = NSTextField(labelWithString: "")
	let openLoginItemsButton = NSButton(
		title: "Open Login Items Settings…",
		target: nil,
		action: nil
	)

	private let settingsStore: AppSettingsStore
	private let loginItem: any LoginItemManaging
	private let fontFamilies: [String]
	private let fontSizeStepper = NSStepper()
	private let hideDockIconCheckbox = NSButton(
		checkboxWithTitle: "Hide Dock icon",
		target: nil,
		action: nil
	)

	init(
		settingsStore: AppSettingsStore,
		fontFamilies: [String],
		loginItem: any LoginItemManaging = MainAppLoginItem()
	) {
		self.settingsStore = settingsStore
		self.loginItem = loginItem
		self.fontFamilies = Array(Set(fontFamilies)).sorted {
			$0.localizedCaseInsensitiveCompare($1) == .orderedAscending
		}

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 440, height: 490),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.title = "Settings"
		window.isReleasedWhenClosed = false
		window.center()
		WindowAppearance.apply(to: window)

		super.init(window: window)

		setUpContent()
		syncState()
	}

	@available(*, unavailable)
	required init?(coder _: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	func showSettingsWindow() {
		syncState()
		NSApp.activate()
		showWindow(nil)
		window?.makeKeyAndOrderFront(nil)
	}

	// MARK: - Content Setup

	private func setUpContent() {
		guard let contentView = window?.contentView else {
			return
		}

		hideDockIconCheckbox.target = self
		hideDockIconCheckbox.action = #selector(hideDockIconChanged)
		startAtLoginCheckbox.target = self
		startAtLoginCheckbox.action = #selector(startAtLoginChanged)
		loginItemStatusLabel.textColor = .secondaryLabelColor
		loginItemStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		loginItemStatusLabel.maximumNumberOfLines = 0
		openLoginItemsButton.target = self
		openLoginItemsButton.action = #selector(openLoginItemsSettings)

		let dockDescriptionLabel = descriptionLabel(
			"The Dock icon is hidden when all windows are closed. Glance stays available from the menu bar."
		)

		fontFamilyPopUpButton.addItem(withTitle: "System Default")
		fontFamilyPopUpButton.addItems(withTitles: fontFamilies)
		fontFamilyPopUpButton.target = self
		fontFamilyPopUpButton.action = #selector(fontFamilyChanged)
		fontFamilyPopUpButton.setAccessibilityLabel("Preview font family")

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

		let fontSizeControl = NSStackView(views: [fontSizeField, fontSizeStepper])
		fontSizeControl.orientation = .horizontal
		fontSizeControl.alignment = .centerY
		fontSizeControl.spacing = 6

		lineWrappingCheckbox.target = self
		lineWrappingCheckbox.action = #selector(lineWrappingChanged)
		flacWaveformCheckbox.target = self
		flacWaveformCheckbox.action = #selector(flacWaveformChanged)

		resetAppearanceButton.bezelStyle = .rounded
		resetAppearanceButton.target = self
		resetAppearanceButton.action = #selector(resetAppearance)

		let appearanceGrid = NSGridView(views: [
			[formLabel("Font"), fontFamilyPopUpButton],
			[formLabel("Size"), fontSizeControl],
		])
		appearanceGrid.rowSpacing = 10
		appearanceGrid.columnSpacing = 12
		appearanceGrid.column(at: 0).xPlacement = .trailing
		appearanceGrid.column(at: 1).xPlacement = .fill
		appearanceGrid.translatesAutoresizingMaskIntoConstraints = false
		fontFamilyPopUpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
			.isActive = true

		let appearanceDescriptionLabel = descriptionLabel(
			"Changes apply to new code, Markdown, and Jupyter previews."
		)
		let waveformDescriptionLabel = descriptionLabel(
			"The waveform appears in new FLAC previews. Playback works either way."
		)

		let stackView = NSStackView(views: [
			sectionLabel("General"),
			hideDockIconCheckbox,
			dockDescriptionLabel,
			startAtLoginCheckbox,
			loginItemStatusLabel,
			openLoginItemsButton,
			separator(),
			sectionLabel("Preview Appearance"),
			appearanceGrid,
			lineWrappingCheckbox,
			appearanceDescriptionLabel,
			resetAppearanceButton,
			separator(),
			sectionLabel("Audio Previews"),
			flacWaveformCheckbox,
			waveformDescriptionLabel,
		])
		stackView.orientation = .vertical
		stackView.alignment = .leading
		stackView.spacing = 8
		stackView.setCustomSpacing(16, after: openLoginItemsButton)
		stackView.setCustomSpacing(12, after: appearanceDescriptionLabel)
		stackView.setCustomSpacing(16, after: resetAppearanceButton)
		stackView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(stackView)

		NSLayoutConstraint.activate([
			stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
			stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
			stackView.topAnchor.constraint(
				equalTo: contentView.safeAreaLayoutGuide.topAnchor,
				constant: 20
			),
			stackView.bottomAnchor.constraint(
				lessThanOrEqualTo: contentView.bottomAnchor,
				constant: -20
			),
			appearanceGrid.widthAnchor.constraint(equalTo: stackView.widthAnchor),
		])
	}

	// MARK: - State

	func syncState() {
		hideDockIconCheckbox.state = settingsStore.hideDockIcon ? .on : .off
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
		lineWrappingCheckbox.state = settingsStore.previewLineWrapping ? .on : .off
		flacWaveformCheckbox.state = settingsStore.flacWaveformEnabled ? .on : .off
	}

	@objc
	private func hideDockIconChanged(_ sender: NSButton) {
		settingsStore.hideDockIcon = sender.state == .on
		(NSApp.delegate as? DockIconVisibilityUpdating)?.updateDockIconVisibility()
	}

	private func syncLoginItemState(error: Error? = nil) {
		let status = loginItem.status
		startAtLoginCheckbox.state = status == .enabled || status == .requiresApproval ? .on : .off
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
	}

	@objc
	private func startAtLoginChanged(_ sender: NSButton) {
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
	}

	@objc
	private func fontSizeChanged(_ sender: NSTextField) {
		settingsStore.previewFontSize = sender.doubleValue
		fontSizeField.doubleValue = settingsStore.previewFontSize
		fontSizeStepper.doubleValue = settingsStore.previewFontSize
	}

	@objc
	private func fontSizeStepperChanged(_ sender: NSStepper) {
		settingsStore.previewFontSize = sender.doubleValue
		fontSizeField.doubleValue = settingsStore.previewFontSize
	}

	@objc
	private func lineWrappingChanged(_ sender: NSButton) {
		settingsStore.previewLineWrapping = sender.state == .on
	}

	@objc
	private func flacWaveformChanged(_ sender: NSButton) {
		settingsStore.flacWaveformEnabled = sender.state == .on
	}

	@objc
	private func resetAppearance(_: NSButton) {
		settingsStore.resetPreviewAppearance()
		syncState()
	}

	// MARK: - View Helpers

	private func sectionLabel(_ text: String) -> NSTextField {
		let textField = NSTextField(labelWithString: text)
		textField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
		return textField
	}

	private func formLabel(_ text: String) -> NSTextField {
		let textField = NSTextField(labelWithString: text)
		textField.alignment = .right
		return textField
	}

	private func descriptionLabel(_ text: String) -> NSTextField {
		let textField = NSTextField(labelWithString: text)
		textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
		textField.textColor = .secondaryLabelColor
		textField.lineBreakMode = .byWordWrapping
		textField.maximumNumberOfLines = 0
		return textField
	}

	private func separator() -> NSBox {
		let separator = NSBox()
		separator.boxType = .separator
		separator.widthAnchor.constraint(equalToConstant: 392).isActive = true
		return separator
	}
}
