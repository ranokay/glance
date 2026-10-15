import Cocoa
import GlanceKit
import Sparkle

/// Owns the Sparkle updater for the main app.
///
/// Sparkle handles checking, downloading, EdDSA verification, installing, and
/// relaunching. This class mirrors the app-group "Automatically check for
/// updates" preference into Sparkle's own preferences and republishes progress
/// as notifications for the Settings window to display.
@MainActor
final class SparkleUpdateCenter: NSObject {
	static let shared = SparkleUpdateCenter()

	nonisolated static let statusDidChangeNotification = Notification.Name(
		"com.chamburr.Glance.updateStatusDidChange"
	)

	private static let statusTextKey = "statusText"
	private static let installReadyKey = "installReady"

	private var updater: SPUUpdater?

	private(set) var statusText = "Never checked."
	private(set) var installReady = false

	func start(autoChecksEnabled: Bool) {
		guard updater == nil else {
			return
		}

		let hostBundle = Bundle.main
		let userDriver = SPUStandardUserDriver(
			hostBundle: hostBundle,
			delegate: self
		)
		let newUpdater = SPUUpdater(
			hostBundle: hostBundle,
			applicationBundle: hostBundle,
			userDriver: userDriver,
			delegate: self
		)
		updater = newUpdater

		setAutomaticChecksEnabled(autoChecksEnabled)
		do {
			try newUpdater.start()
		} catch {
			Log.general.error("Sparkle updater failed to start: \(error.localizedDescription)")
		}
	}

	/// Applies the preference to both automatic behaviors: scheduled checks and
	/// background downloads. Turning it off stops both immediately.
	func setAutomaticChecksEnabled(_ enabled: Bool) {
		guard let updater else {
			return
		}
		updater.automaticallyChecksForUpdates = enabled
		updater.automaticallyDownloadsUpdates = enabled
	}

	func checkForUpdates() {
		guard let updater, updater.canCheckForUpdates else {
			return
		}
		setStatus("Checking…", installReady: installReady)
		updater.checkForUpdates()
	}

	/// Re-offers the pending update from Settings. Sparkle resuming a
	/// downloaded update surfaces "Install and Relaunch" in its dialog.
	func installNow() {
		checkForUpdates()
	}

	private func setStatus(_ text: String, installReady: Bool) {
		statusText = text
		self.installReady = installReady
		NotificationCenter.default.post(
			name: Self.statusDidChangeNotification,
			object: nil,
			userInfo: [
				Self.statusTextKey: text,
				Self.installReadyKey: installReady,
			]
		)
	}
}

extension SparkleUpdateCenter: SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
	func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
		setStatus("Glance \(item.displayVersionString) is available.", installReady: false)
	}

	func updaterDidNotFindUpdate(_: SPUUpdater) {
		setStatus("You’re up to date.", installReady: false)
	}

	func updater(_: SPUUpdater, willDownloadUpdate _: SUAppcastItem, with _: NSMutableURLRequest) {
		setStatus("Downloading update…", installReady: false)
	}

	func updater(_: SPUUpdater, didDownloadUpdate _: SUAppcastItem) {
		setStatus("Ready to install.", installReady: true)
	}

	func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error _: Error) {
		setStatus("Couldn’t download the update.", installReady: false)
	}

	func updater(_: SPUUpdater, didAbortWithError error: Error) {
		let nsError = error as NSError
		// Not finding an update (the common abort) and a user-cancelled install
		// are already reported through their own callbacks; only surface real
		// aborts as failure text.
		if nsError.domain == SUSparkleErrorDomain,
		   nsError.code == SUError.noUpdateError.rawValue
		{
			return
		}
		if nsError.code == SUError.installationCanceledError.rawValue {
			return
		}
		setStatus("Couldn’t check just now.", installReady: false)
	}
}
