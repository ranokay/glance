import Cocoa
import GlanceKit
import Sparkle

/// Owns the Sparkle updater for the main app.
///
/// Sparkle handles checking, downloading, EdDSA verification, installing, and
/// relaunching, and persists its own "automatically check" / "automatically
/// download" preferences (which it may also change from its own update UI).
/// The app-group "Automatically check for updates" preference is only seeded
/// once, the first time Sparkle has no explicit preference yet. Progress is
/// republished as notifications for the Settings window to display.
@MainActor
final class SparkleUpdateCenter: NSObject {
	static let shared = SparkleUpdateCenter()

	nonisolated static let statusDidChangeNotification = Notification.Name(
		"com.chamburr.Glance.updateStatusDidChange"
	)

	private static let statusTextKey = "statusText"
	private static let installReadyKey = "installReady"
	private static let canCheckKey = "canCheckForUpdates"

	private var updater: SPUUpdater?
	private var canCheckObservation: NSKeyValueObservation?

	private(set) var statusText = "Never checked."
	private(set) var installReady = false
	private(set) var canCheckForUpdates = true

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

		migrateLegacyAutomaticChecks(autoChecksEnabled)
		canCheckObservation = newUpdater.observe(
			\.canCheckForUpdates,
			options: [.initial, .new]
		) { [weak self] observedUpdater, _ in
			// SPUUpdater mutates this property on the main thread only.
			MainActor.assumeIsolated {
				guard let self else {
					return
				}
				self.canCheckForUpdates = observedUpdater.canCheckForUpdates
				NotificationCenter.default.post(
					name: Self.statusDidChangeNotification,
					object: nil,
					userInfo: [
						Self.canCheckKey: self.canCheckForUpdates,
					]
				)
			}
		}
		do {
			try newUpdater.start()
		} catch {
			Log.general.error("Sparkle updater failed to start: \(error.localizedDescription)")
		}
	}

	/// Seeds Sparkle's persisted preference from the pre-Sparkle app-group
	/// preference exactly once: only when Sparkle has no explicit preference
	/// of its own yet. Afterwards Sparkle owns the value.
	private func migrateLegacyAutomaticChecks(_ legacyEnabled: Bool) {
		guard let updater, UserDefaults.standard.object(
			forKey: "SUEnableAutomaticChecks"
		) == nil else {
			return
		}
		updater.automaticallyChecksForUpdates = legacyEnabled
	}

	/// Writes the Settings checkbox to Sparkle's schedule preference only;
	/// background downloading has its own Sparkle-persisted preference.
	func setAutomaticChecksEnabled(_ enabled: Bool) {
		guard let updater else {
			return
		}
		updater.automaticallyChecksForUpdates = enabled
	}

	func checkForUpdates() {
		guard let updater, updater.canCheckForUpdates else {
			return
		}
		setStatus("Checking…", installReady: installReady)
		updater.checkForUpdates()
	}

	/// Sparkle's current scheduled-check preference; a plain read is fine
	/// because Settings only refreshes this when its window is shown.
	var automaticChecksEnabled: Bool {
		updater?.automaticallyChecksForUpdates ?? true
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
		// Download finished, but extraction/validation is still ahead; the
		// install button waits for didExtractUpdate.
	}

	func updater(_: SPUUpdater, willExtractUpdate _: SUAppcastItem) {
		setStatus("Preparing to install…", installReady: false)
	}

	func updater(_: SPUUpdater, didExtractUpdate _: SUAppcastItem) {
		// Extracted and signature-validated; the staged update can now be
		// resumed with an Install and Relaunch from Settings.
		setStatus("Ready to install.", installReady: true)
	}

	func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error _: Error) {
		setStatus("Couldn’t download the update.", installReady: false)
	}

	func userDidCancelDownload(_: SPUUpdater) {
		setStatus("Update canceled.", installReady: false)
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
