import Foundation

private final class UserDefaultsBox: @unchecked Sendable {
	let defaults: UserDefaults

	init(defaults: UserDefaults) {
		self.defaults = defaults
	}
}

struct AppSettingsStore {
	static let sharedDefaultsSuiteName = "group.com.chamburr.glance"

	private static let sharedDefaultsBox = UserDefaultsBox(defaults: {
		guard let defaults = UserDefaults(suiteName: sharedDefaultsSuiteName) else {
			fatalError(
				"Failed to create UserDefaults with app group suite '\(sharedDefaultsSuiteName)'. Check that the app group is correctly configured."
			)
		}
		return defaults
	}())

	static var sharedDefaults: UserDefaults {
		sharedDefaultsBox.defaults
	}

	static let shared = AppSettingsStore(
		defaultsBox: sharedDefaultsBox,
		standardDefaultsBox: UserDefaultsBox(defaults: .standard)
	)

	private static let hideDockIconKey = "hideDockIcon"
	private static let standardDefaultsMigrationKey = "didMigrateStandardDefaults"

	private let defaultsBox: UserDefaultsBox
	private let standardDefaultsBox: UserDefaultsBox?

	private var defaults: UserDefaults {
		defaultsBox.defaults
	}

	private var standardDefaults: UserDefaults? {
		standardDefaultsBox?.defaults
	}

	init(defaults: UserDefaults, standardDefaults: UserDefaults? = nil) {
		self.init(
			defaultsBox: UserDefaultsBox(defaults: defaults),
			standardDefaultsBox: standardDefaults.map(UserDefaultsBox.init)
		)
	}

	private init(defaultsBox: UserDefaultsBox, standardDefaultsBox: UserDefaultsBox?) {
		self.defaultsBox = defaultsBox
		self.standardDefaultsBox = standardDefaultsBox
	}

	var hideDockIcon: Bool {
		get { defaults.bool(forKey: Self.hideDockIconKey) }
		nonmutating set {
			defaults.set(newValue, forKey: Self.hideDockIconKey)
		}
	}

	func migrateStandardDefaultsIfNeeded() {
		guard
			!defaults.bool(forKey: Self.standardDefaultsMigrationKey),
			let standardDefaults
		else { return }

		if
			defaults.object(forKey: Self.hideDockIconKey) == nil,
			standardDefaults.object(forKey: Self.hideDockIconKey) != nil {
			defaults.set(
				standardDefaults.bool(forKey: Self.hideDockIconKey),
				forKey: Self.hideDockIconKey
			)
		}

		defaults.set(true, forKey: Self.standardDefaultsMigrationKey)
	}
}
