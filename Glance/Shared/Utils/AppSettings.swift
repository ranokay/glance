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
