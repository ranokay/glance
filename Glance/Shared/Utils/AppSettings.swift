import Foundation

struct PreviewAppearancePreferences: Equatable {
	static let defaultFontSize = 14.0
	static let minimumFontSize = 9.0
	static let maximumFontSize = 32.0
	static let `default` = PreviewAppearancePreferences(
		fontFamily: nil,
		fontSize: defaultFontSize,
		wrapsLines: false
	)

	let fontFamily: String?
	let fontSize: Double
	let wrapsLines: Bool

	func stylesheet(availableFontFamilies: [String]) -> String {
		var bodyDeclarations = ["font-size: \(fontSize)px;"]
		if
			let fontFamily,
			let availableFontFamily = availableFontFamilies.first(where: {
				$0.caseInsensitiveCompare(fontFamily) == .orderedSame
			})
		{
			let escapedFontFamily = Self.escapeCSSString(availableFontFamily)
			bodyDeclarations
				.append("--font-family-sans-serif: \"\(escapedFontFamily)\", sans-serif;")
			bodyDeclarations.append("--font-family-monospace: \"\(escapedFontFamily)\", monospace;")
		}

		let whiteSpace = wrapsLines ? "pre-wrap" : "pre"
		let overflowWrap = wrapsLines ? "anywhere" : "normal"
		let wordBreak = wrapsLines ? "break-word" : "normal"

		return """
		body {
			\(bodyDeclarations.joined(separator: "\n\t"))
		}

		pre,
		pre code,
		pre > code {
			white-space: \(whiteSpace);
			overflow-wrap: \(overflowWrap);
			word-break: \(wordBreak);
		}
		"""
	}

	private static func escapeCSSString(_ value: String) -> String {
		value.unicodeScalars.reduce(into: "") { result, scalar in
			switch scalar.value {
				case 0x22, 0x3C, 0x5C, 0x7F:
					result += "\\\(String(scalar.value, radix: 16)) "
				case 0x00 ... 0x1F:
					result += "\\\(String(scalar.value, radix: 16)) "
				default:
					result.unicodeScalars.append(scalar)
			}
		}
	}
}

struct AppSettingsStore {
	static let sharedDefaultsSuiteName = "group.com.chamburr.glance"

	nonisolated(unsafe) static let sharedDefaults: UserDefaults = {
		guard let defaults = UserDefaults(suiteName: sharedDefaultsSuiteName) else {
			fatalError(
				"Failed to create UserDefaults with app group suite '\(sharedDefaultsSuiteName)'. Check that the app group is correctly configured."
			)
		}
		return defaults
	}()

	nonisolated(unsafe) static let shared = AppSettingsStore(
		defaults: sharedDefaults,
		standardDefaults: .standard
	)

	private static let hideDockIconKey = "hideDockIcon"
	static let previewFontFamilyKey = "previewFontFamily"
	static let previewFontSizeKey = "previewFontSize"
	static let previewLineWrappingKey = "previewLineWrapping"
	static let flacWaveformEnabledKey = "flacWaveformEnabled"
	private static let standardDefaultsMigrationKey = "didMigrateStandardDefaults"
	private static let previewDefaultsMigrationKey = "didMigratePreviewDefaults"

	private let defaults: UserDefaults
	private let standardDefaults: UserDefaults?

	init(defaults: UserDefaults, standardDefaults: UserDefaults? = nil) {
		self.defaults = defaults
		self.standardDefaults = standardDefaults
	}

	var hideDockIcon: Bool {
		get { defaults.bool(forKey: Self.hideDockIconKey) }
		nonmutating set {
			defaults.set(newValue, forKey: Self.hideDockIconKey)
		}
	}

	var previewFontFamily: String? {
		get {
			guard let value = defaults.string(forKey: Self.previewFontFamilyKey)?
				.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
			else {
				return nil
			}
			return value
		}
		nonmutating set {
			guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
			      !value.isEmpty
			else {
				defaults.removeObject(forKey: Self.previewFontFamilyKey)
				return
			}
			defaults.set(value, forKey: Self.previewFontFamilyKey)
		}
	}

	var previewFontSize: Double {
		get {
			guard
				let storedValue = defaults.object(forKey: Self.previewFontSizeKey) as? NSNumber,
				storedValue.doubleValue.isFinite,
				(Self.minimumPreviewFontSize ... Self.maximumPreviewFontSize)
				.contains(storedValue.doubleValue)
			else {
				return PreviewAppearancePreferences.defaultFontSize
			}
			return storedValue.doubleValue
		}
		nonmutating set {
			guard newValue.isFinite else {
				defaults.removeObject(forKey: Self.previewFontSizeKey)
				return
			}
			defaults.set(
				min(max(newValue, Self.minimumPreviewFontSize), Self.maximumPreviewFontSize),
				forKey: Self.previewFontSizeKey
			)
		}
	}

	var previewLineWrapping: Bool {
		get { defaults.bool(forKey: Self.previewLineWrappingKey) }
		nonmutating set { defaults.set(newValue, forKey: Self.previewLineWrappingKey) }
	}

	var flacWaveformEnabled: Bool {
		get { defaults.object(forKey: Self.flacWaveformEnabledKey) as? Bool ?? true }
		nonmutating set { defaults.set(newValue, forKey: Self.flacWaveformEnabledKey) }
	}

	var previewAppearance: PreviewAppearancePreferences {
		PreviewAppearancePreferences(
			fontFamily: previewFontFamily,
			fontSize: previewFontSize,
			wrapsLines: previewLineWrapping
		)
	}

	func resetPreviewAppearance() {
		defaults.removeObject(forKey: Self.previewFontFamilyKey)
		defaults.removeObject(forKey: Self.previewFontSizeKey)
		defaults.removeObject(forKey: Self.previewLineWrappingKey)
	}

	func migrateStandardDefaultsIfNeeded() {
		guard let standardDefaults else {
			return
		}

		if !defaults.bool(forKey: Self.standardDefaultsMigrationKey) {
			if
				defaults.object(forKey: Self.hideDockIconKey) == nil,
				standardDefaults.object(forKey: Self.hideDockIconKey) != nil
			{
				defaults.set(
					standardDefaults.bool(forKey: Self.hideDockIconKey),
					forKey: Self.hideDockIconKey
				)
			}

			defaults.set(true, forKey: Self.standardDefaultsMigrationKey)
		}

		guard !defaults.bool(forKey: Self.previewDefaultsMigrationKey) else {
			return
		}

		for key in [
			Self.previewFontFamilyKey,
			Self.previewFontSizeKey,
			Self.previewLineWrappingKey,
		] where defaults.object(forKey: key) == nil {
			if let value = standardDefaults.object(forKey: key) {
				defaults.set(value, forKey: key)
			}
		}

		defaults.set(true, forKey: Self.previewDefaultsMigrationKey)
	}

	private static let minimumPreviewFontSize = PreviewAppearancePreferences.minimumFontSize
	private static let maximumPreviewFontSize = PreviewAppearancePreferences.maximumFontSize
}

private enum PreviewSettingsBridge {
	static let request = Notification.Name("com.chamburr.Glance.PreviewSettings.request")
	static let response = Notification.Name("com.chamburr.Glance.PreviewSettings.response")

	static func response(for requestID: UUID, enabled: Bool) -> String {
		"\(requestID.uuidString)|\(enabled ? "1" : "0")"
	}

	static func decodeResponse(_ value: String) -> (UUID, Bool)? {
		let parts = value.split(separator: "|", omittingEmptySubsequences: false)
		guard parts.count == 2, let requestID = UUID(uuidString: String(parts[0])) else {
			return nil
		}
		switch parts[1] {
			case "1":
				return (requestID, true)
			case "0":
				return (requestID, false)
			default:
				return nil
		}
	}
}

/// The main app owns preferences; the unsigned Quick Look extension has a separate sandbox.
@MainActor
final class PreviewSettingsServer {
	private let settingsStore: AppSettingsStore
	private let notificationCenter: OpenWithBridgeNotifying
	private var observer: NSObjectProtocol?

	init(
		settingsStore: AppSettingsStore = .shared,
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter()
	) {
		self.settingsStore = settingsStore
		self.notificationCenter = notificationCenter
	}

	isolated deinit {
		if let observer {
			notificationCenter.removeObserver(observer)
		}
	}

	func start() {
		guard observer == nil else {
			return
		}
		observer = notificationCenter
			.addObserver(forName: PreviewSettingsBridge.request) { [weak self] value in
				guard let self, let requestID = UUID(uuidString: value) else {
					return
				}
				notificationCenter.post(
					name: PreviewSettingsBridge.response,
					object: PreviewSettingsBridge.response(
						for: requestID,
						enabled: settingsStore.flacWaveformEnabled
					)
				)
			}
	}
}

/// Only a non-sensitive display preference crosses this unauthenticated local notification channel.
@MainActor
final class PreviewSettingsClient {
	static let shared = PreviewSettingsClient()

	private struct PendingRequest {
		let observer: NSObjectProtocol
		let timeoutTask: Task<Void, Never>
		let continuation: CheckedContinuation<Bool, Never>
	}

	private let notificationCenter: OpenWithBridgeNotifying
	private let timeout: Duration
	private var pendingRequests = [UUID: PendingRequest]()

	init(
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter(),
		timeout: Duration = .milliseconds(300)
	) {
		self.notificationCenter = notificationCenter
		self.timeout = timeout
	}

	func flacWaveformEnabled() async -> Bool {
		let requestID = UUID()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(returning: true)
					return
				}
				let observer = notificationCenter.addObserver(
					forName: PreviewSettingsBridge.response
				) { [weak self] value in
					guard let (responseID, enabled) = PreviewSettingsBridge.decodeResponse(value),
					      responseID == requestID
					else {
						return
					}
					self?.finish(requestID: requestID, enabled: enabled)
				}
				let timeout = timeout
				let timeoutTask = Task { @MainActor [weak self] in
					try? await Task.sleep(for: timeout)
					guard !Task.isCancelled else {
						return
					}
					self?.finish(requestID: requestID, enabled: true)
				}
				pendingRequests[requestID] = PendingRequest(
					observer: observer,
					timeoutTask: timeoutTask,
					continuation: continuation
				)
				notificationCenter.post(
					name: PreviewSettingsBridge.request,
					object: requestID.uuidString
				)
			}
		} onCancel: {
			Task { @MainActor [weak self] in
				self?.finish(requestID: requestID, enabled: true)
			}
		}
	}

	private func finish(requestID: UUID, enabled: Bool) {
		guard let request = pendingRequests.removeValue(forKey: requestID) else {
			return
		}
		notificationCenter.removeObserver(request.observer)
		request.timeoutTask.cancel()
		request.continuation.resume(returning: enabled)
	}
}
