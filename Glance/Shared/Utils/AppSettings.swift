import Foundation

public struct PreviewAppearancePreferences: Equatable, Sendable {
	public static let defaultFontSize = 14.0
	public static let minimumFontSize = 9.0
	public static let maximumFontSize = 32.0
	public static let `default` = PreviewAppearancePreferences(
		fontFamily: nil,
		fontSize: defaultFontSize,
		wrapsLines: false
	)

	public let fontFamily: String?
	public let fontSize: Double
	public let wrapsLines: Bool

	public init(fontFamily: String?, fontSize: Double, wrapsLines: Bool) {
		self.fontFamily = fontFamily
		self.fontSize = fontSize
		self.wrapsLines = wrapsLines
	}

	public func stylesheet(availableFontFamilies: [String]) -> String {
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

/// One bridge round trip serves every preference the Quick Look extension
/// needs at once (waveform toggle + preview appearance).
public struct PreviewPreferenceSnapshot: Sendable, Equatable {
	public let waveformEnabled: Bool
	public let appearance: PreviewAppearancePreferences

	public init(waveformEnabled: Bool, appearance: PreviewAppearancePreferences) {
		self.waveformEnabled = waveformEnabled
		self.appearance = appearance
	}

	public static let `default` = PreviewPreferenceSnapshot(
		waveformEnabled: true,
		appearance: .default
	)
}

public struct AppSettingsStore {
	public static let sharedDefaultsSuiteName = "group.com.chamburr.glance"
	nonisolated(unsafe) static let sharedDefaults: UserDefaults = {
		guard let defaults = UserDefaults(suiteName: sharedDefaultsSuiteName) else {
			fatalError(
				"Failed to create UserDefaults with app group suite '\(sharedDefaultsSuiteName)'. Check that the app group is correctly configured."
			)
		}
		return defaults
	}()

	public nonisolated(unsafe) static let shared = AppSettingsStore(
		defaults: sharedDefaults,
		standardDefaults: .standard
	)

	public static let previewFontFamilyKey = "previewFontFamily"
	public static let previewFontSizeKey = "previewFontSize"
	public static let previewLineWrappingKey = "previewLineWrapping"
	public static let flacWaveformEnabledKey = "flacWaveformEnabled"
	// Legacy seed for Sparkle's own persisted check preference; Settings
	// writes go to Sparkle from now on and this key is only read once.
	public static let autoUpdateCheckEnabledKey = "autoUpdateCheckEnabled"
	private static let previewDefaultsMigrationKey = "didMigratePreviewDefaults"

	private let defaults: UserDefaults
	private let standardDefaults: UserDefaults?

	public init(defaults: UserDefaults, standardDefaults: UserDefaults? = nil) {
		self.defaults = defaults
		self.standardDefaults = standardDefaults
	}

	public var previewFontFamily: String? {
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

	public var previewFontSize: Double {
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

	public var previewLineWrapping: Bool {
		get { defaults.bool(forKey: Self.previewLineWrappingKey) }
		nonmutating set { defaults.set(newValue, forKey: Self.previewLineWrappingKey) }
	}

	public var flacWaveformEnabled: Bool {
		get { defaults.object(forKey: Self.flacWaveformEnabledKey) as? Bool ?? true }
		nonmutating set { defaults.set(newValue, forKey: Self.flacWaveformEnabledKey) }
	}

	public var autoUpdateCheckEnabled: Bool {
		get { defaults.object(forKey: Self.autoUpdateCheckEnabledKey) as? Bool ?? true }
		nonmutating set { defaults.set(newValue, forKey: Self.autoUpdateCheckEnabledKey) }
	}

	public var previewAppearance: PreviewAppearancePreferences {
		PreviewAppearancePreferences(
			fontFamily: previewFontFamily,
			fontSize: previewFontSize,
			wrapsLines: previewLineWrapping
		)
	}

	public func resetPreviewAppearance() {
		defaults.removeObject(forKey: Self.previewFontFamilyKey)
		defaults.removeObject(forKey: Self.previewFontSizeKey)
		defaults.removeObject(forKey: Self.previewLineWrappingKey)
	}

	public func migrateStandardDefaultsIfNeeded() {
		guard let standardDefaults else {
			return
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

/// Serializes preferences over the cross-process notification bridge
/// (main app and Quick Look extension). Visible to tests for wire-format pins.
public enum PreviewSettingsBridge {
	static let request = Notification.Name("com.chamburr.Glance.PreviewSettings.request")
	static let response = Notification.Name("com.chamburr.Glance.PreviewSettings.response")
	public static let familySentinel = "-"

	public static func response(
		for requestID: UUID,
		snapshot: PreviewPreferenceSnapshot
	) -> String {
		let family = snapshot.appearance.fontFamily ?? Self.familySentinel
		let encodedFamily = family == Self.familySentinel
			? family
			: family.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? family
		return [
			requestID.uuidString,
			snapshot.waveformEnabled ? "1" : "0",
			encodedFamily,
			"\(snapshot.appearance.fontSize)",
			snapshot.appearance.wrapsLines ? "1" : "0",
		].joined(separator: "|")
	}

	public static func decode(_ value: String) -> (UUID, PreviewPreferenceSnapshot)? {
		let parts = value.split(separator: "|", omittingEmptySubsequences: false)
		guard parts.count == 5, let requestID = UUID(uuidString: String(parts[0])) else {
			return nil
		}
		guard parts[1] == "0" || parts[1] == "1" else {
			return nil
		}
		var fontFamily: String?
		let encodedFamily = String(parts[2])
		if encodedFamily != Self.familySentinel {
			guard let decoded = encodedFamily.removingPercentEncoding, !decoded.isEmpty else {
				return nil
			}
			fontFamily = decoded
		}
		guard
			let fontSize = Double(String(parts[3])),
			fontSize.isFinite,
			(PreviewAppearancePreferences.minimumFontSize ... PreviewAppearancePreferences
				.maximumFontSize)
			.contains(fontSize),
			parts[4] == "0" || parts[4] == "1"
		else {
			return nil
		}
		let snapshot = PreviewPreferenceSnapshot(
			waveformEnabled: parts[1] == "1",
			appearance: PreviewAppearancePreferences(
				fontFamily: fontFamily,
				fontSize: fontSize,
				wrapsLines: parts[4] == "1"
			)
		)
		return (requestID, snapshot)
	}
}

/// The main app owns preferences; the unsigned Quick Look extension has a separate sandbox.
@MainActor
public final class PreviewSettingsServer {
	private let settingsStore: AppSettingsStore
	private let notificationCenter: OpenWithBridgeNotifying
	private var observer: NSObjectProtocol?

	public init(
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

	public func start() {
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
						snapshot: PreviewPreferenceSnapshot(
							waveformEnabled: settingsStore.flacWaveformEnabled,
							appearance: settingsStore.previewAppearance
						)
					)
				)
			}
	}
}

/// Only non-sensitive display preferences cross this unauthenticated local notification channel.
@MainActor
public final class PreviewSettingsClient {
	public static let shared = PreviewSettingsClient()

	private struct PendingRequest {
		let observer: NSObjectProtocol
		let timeoutTask: Task<Void, Never>
		let continuation: CheckedContinuation<PreviewPreferenceSnapshot, Never>
	}

	private let notificationCenter: OpenWithBridgeNotifying
	private let timeout: Duration
	private var pendingRequests = [UUID: PendingRequest]()

	public init(
		notificationCenter: OpenWithBridgeNotifying = SystemOpenWithBridgeNotificationCenter(),
		timeout: Duration = .milliseconds(300)
	) {
		self.notificationCenter = notificationCenter
		self.timeout = timeout
	}

	public func flacWaveformEnabled() async -> Bool {
		await snapshot().waveformEnabled
	}

	public func appearancePreferences() async -> PreviewAppearancePreferences {
		await snapshot().appearance
	}

	private func snapshot() async -> PreviewPreferenceSnapshot {
		let requestID = UUID()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(returning: .default)
					return
				}
				let observer = notificationCenter.addObserver(
					forName: PreviewSettingsBridge.response
				) { [weak self] value in
					guard
						let (responseID, snapshot) = PreviewSettingsBridge.decode(value),
						responseID == requestID
					else {
						return
					}
					self?.finish(requestID: requestID, snapshot: snapshot)
				}
				let timeout = timeout
				let timeoutTask = Task { @MainActor [weak self] in
					try? await Task.sleep(for: timeout)
					guard !Task.isCancelled else {
						return
					}
					self?.finish(requestID: requestID, snapshot: .default)
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
				self?.finish(requestID: requestID, snapshot: .default)
			}
		}
	}

	private func finish(requestID: UUID, snapshot: PreviewPreferenceSnapshot) {
		guard let request = pendingRequests.removeValue(forKey: requestID) else {
			return
		}
		notificationCenter.removeObserver(request.observer)
		request.timeoutTask.cancel()
		request.continuation.resume(returning: snapshot)
	}
}
