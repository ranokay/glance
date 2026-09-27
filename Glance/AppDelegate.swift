import Cocoa
import GlanceKit
import UserNotifications

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, DockIconVisibilityUpdating {
	private var mainWindowController: NSWindowController?
	private var statusItem: NSStatusItem?
	private let openWithBridgeServer = OpenWithBridgeServer()
	private let previewSettingsServer = PreviewSettingsServer()

	func applicationWillFinishLaunching(_: Notification) {
		openWithBridgeServer.start()
		previewSettingsServer.start()
	}

	func applicationDidFinishLaunching(_: Notification) {
		setUpStatusItem()
		cacheMainWindowController()
		AppSettingsStore.shared.migrateStandardDefaultsIfNeeded()

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(windowDidBecomeMain),
			name: NSWindow.didBecomeMainNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(windowWillClose),
			name: NSWindow.willCloseNotification,
			object: nil
		)

		updateDockIconVisibility()
		UNUserNotificationCenter.current().delegate = self
		checkForUpdatesIfDue()
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

	private func makeStatusMenu() -> NSMenu {
		let menu = NSMenu()
		menu.addItem(NSMenuItem(
			title: "Open Glance",
			action: #selector(openMainWindow(_:)),
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
	private func openMainWindow(_: Any?) {
		NSApp.activate()

		if let window = existingMainWindow() {
			window.deminiaturize(nil)
			window.makeKeyAndOrderFront(nil)
			return
		}

		let storyboard = NSStoryboard(name: "Main", bundle: nil)
		if let windowController = storyboard.instantiateInitialController() as? NSWindowController {
			mainWindowController = windowController
			windowController.showWindow(nil)
			windowController.window?.makeKeyAndOrderFront(nil)
		}
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
		SettingsWC.shared.showSettingsWindow()
		SettingsWC.shared.checkForUpdatesButton.performClick(nil)
	}

	private func checkForUpdatesIfDue() {
		Task { @MainActor in
			let center = UNUserNotificationCenter.current()
			_ = try? await center.requestAuthorization(options: [.alert])
			let current =
				Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
			let service = UpdateCheckService(
				settings: AppSettingsStore.shared,
				currentVersion: current,
				fetch: UpdateCheckService.liveFetcher(),
				notified: { version, url in
					let center = UNUserNotificationCenter.current()
					let settings = await center.notificationSettings()
					guard settings.authorizationStatus == .authorized else {
						return
					}
					let content = UNMutableNotificationContent()
					content.title = "Glance \(version) available"
					content.body = "Update now opens the release page."
					content.userInfo = ["url": url.absoluteString]
					let request = UNNotificationRequest(
						identifier: version,
						content: content,
						trigger: nil
					)
					try? await center.add(request)
				}
			)
			_ = await service.checkIfDue()
		}
	}

	@objc
	private func quitGlance(_: Any?) {
		NSApp.terminate(nil)
	}

	private func existingMainWindow() -> NSWindow? {
		if let window = mainWindowController?.window {
			return window
		}

		cacheMainWindowController()
		return mainWindowController?.window
	}

	private func cacheMainWindowController() {
		guard mainWindowController?.window == nil else {
			return
		}

		mainWindowController = NSApp.windows.first {
			$0.contentViewController is ViewController
		}?.windowController
	}

	// MARK: - Dock Icon Visibility

	/// Shows the dock icon when any window is visible, hides it when all windows
	/// are closed (only when the "Hide Dock icon" setting is enabled).
	func updateDockIconVisibility() {
		guard AppSettingsStore.shared.hideDockIcon else {
			NSApp.setActivationPolicy(.regular)
			return
		}

		let hasVisibleWindows = NSApp.windows.contains {
			$0.isVisible && !($0.className.contains("NSStatusBar"))
		}
		NSApp.setActivationPolicy(hasVisibleWindows ? .regular : .accessory)
	}

	@objc
	private func windowDidBecomeMain(_: Notification) {
		updateDockIconVisibility()
	}

	@objc
	private func windowWillClose(_: Notification) {
		// Defer so the closing window is no longer visible when we check
		Task { @MainActor [weak self] in
			self?.updateDockIconVisibility()
		}
	}
}

extension AppDelegate: UNUserNotificationCenterDelegate {
	nonisolated func userNotificationCenter(
		_: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		let urlString = response.notification.request.content.userInfo["url"] as? String
		let url = urlString.flatMap(URL.init(string:)) ?? AppLinks.releases
		DispatchQueue.main.async {
			url.open()
		}
		completionHandler()
	}
}
