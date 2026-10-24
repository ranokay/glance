import Cocoa
import GlanceKit

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
	private var statusItem: NSStatusItem?
	private let openWithBridgeServer = OpenWithBridgeServer()
	private let previewSettingsServer = PreviewSettingsServer()

	func applicationWillFinishLaunching(_: Notification) {
		NSApp.mainMenu = makeMainMenu()
		openWithBridgeServer.start()
		previewSettingsServer.start()
	}

	func applicationDidFinishLaunching(_: Notification) {
		setUpStatusItem()
		AppSettingsStore.shared.migrateStandardDefaultsIfNeeded()
		SparkleUpdateCenter.shared.start(
			autoChecksEnabled: AppSettingsStore.shared.autoUpdateCheckEnabled
		)
	}

	func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
		false
	}

	func application(_: NSApplication, open urls: [URL]) {
		for url in urls where openWithBridgeServer.canHandle(url) {
			openWithBridgeServer.handle(url)
		}
	}

	private func setUpStatusItem() {
		let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		statusItem.button?.image = NSImage(
			systemSymbolName: "eye",
			accessibilityDescription: "Glance"
		)
		statusItem.button?.image?.isTemplate = true
		statusItem.button?.toolTip = "Glance"
		statusItem.menu = makeStatusMenu()

		self.statusItem = statusItem
	}

	private func makeMainMenu() -> NSMenu {
		let mainMenu = NSMenu()

		let appMenuItem = NSMenuItem(title: "Glance", action: nil, keyEquivalent: "")
		let appMenu = NSMenu(title: "Glance")
		appMenu.addItem(NSMenuItem(
			title: "About Glance",
			action: #selector(openAbout(_:)),
			keyEquivalent: ""
		))
		appMenu.addItem(.separator())
		appMenu.addItem(NSMenuItem(
			title: "Settings\u{2026}",
			action: #selector(openSettingsWindow(_:)),
			keyEquivalent: ","
		))
		appMenu.addItem(.separator())
		appMenu.addItem(NSMenuItem(
			title: "Quit Glance",
			action: #selector(quitGlance(_:)),
			keyEquivalent: "q"
		))
		for item in appMenu.items where item.action != nil {
			item.target = self
		}
		appMenuItem.submenu = appMenu
		mainMenu.addItem(appMenuItem)

		let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
		let editMenu = NSMenu(title: "Edit")
		for (title, selector, key) in [
			("Undo", "undo:", "z"),
			("Redo", "redo:", "Z"),
			("Cut", "cut:", "x"),
			("Copy", "copy:", "c"),
			("Paste", "paste:", "v"),
			("Select All", "selectAll:", "a"),
		] {
			editMenu.addItem(NSMenuItem(
				title: title,
				action: Selector(selector),
				keyEquivalent: key
			))
		}
		editMenuItem.submenu = editMenu
		mainMenu.addItem(editMenuItem)

		let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
		let fileMenu = NSMenu(title: "File")
		fileMenu.addItem(NSMenuItem(
			title: "Close",
			action: #selector(NSWindow.performClose(_:)),
			keyEquivalent: "w"
		))
		fileMenuItem.submenu = fileMenu
		mainMenu.addItem(fileMenuItem)

		return mainMenu
	}

	private func makeStatusMenu() -> NSMenu {
		let menu = NSMenu()
		menu.addItem(NSMenuItem(
			title: "About Glance",
			action: #selector(openAbout(_:)),
			keyEquivalent: ""
		))
		menu.addItem(NSMenuItem(
			title: "Supported Files",
			action: #selector(openSupportedFilesWindow(_:)),
			keyEquivalent: ""
		))
		menu.addItem(NSMenuItem(
			title: "Open GitHub Repository",
			action: #selector(openWebsite(_:)),
			keyEquivalent: ""
		))
		menu.addItem(NSMenuItem(
			title: "Settings\u{2026}",
			action: #selector(openSettingsWindow(_:)),
			keyEquivalent: ""
		))
		menu.addItem(NSMenuItem(
			title: "Check for Updates…",
			action: #selector(checkForUpdates(_:)),
			keyEquivalent: ""
		))
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(
			title: "Quit Glance",
			action: #selector(quitGlance(_:)),
			keyEquivalent: "q"
		))

		for item in menu.items where item.action != nil {
			item.target = self
		}

		return menu
	}

	@objc
	private func openAbout(_: Any?) {
		NSApp.activate()
		NSApp.orderFrontStandardAboutPanel(nil)
	}

	@objc
	func openSupportedFilesWindow(_: Any?) {
		NSApp.activate()
		SupportedFilesWC.shared.showSupportedFilesWindow()
	}

	@objc
	func openWebsite(_: Any?) {
		AppLinks.website.open()
	}

	@objc
	func openLicense(_: Any?) {
		AppLinks.license.open()
	}

	@objc
	func openPrivacyPolicy(_: Any?) {
		AppLinks.privacyPolicy.open()
	}

	@objc
	func openFeedback(_: Any?) {
		AppLinks.feedback.open()
	}

	@objc
	func openSettingsWindow(_: Any?) {
		SettingsWC.shared.showSettingsWindow()
	}

	@objc
	private func checkForUpdates(_: Any?) {
		SparkleUpdateCenter.shared.checkForUpdates()
	}

	@objc
	private func quitGlance(_: Any?) {
		NSApp.terminate(nil)
	}
}

extension AppDelegate: NSMenuItemValidation {
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		guard menuItem.action == #selector(checkForUpdates(_:)) else {
			return true
		}
		return SparkleUpdateCenter.shared.canCheckForUpdates
	}
}
