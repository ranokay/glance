import Cocoa

enum AppMetadata {
	static var version: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
	}

	static var build: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
	}

	static var versionLine: String {
		"\(version) (\(build))"
	}

	static var copyright: String {
		Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
			?? "Copyright © 2020–2026 Glance contributors."
	}
}

enum AppLinks {
	static let website = URL(string: "https://github.com/ranokay/glance")!
	static let releases = website.appendingPathComponent("releases")
	static let credits = URL(
		string: "https://github.com/ranokay/glance/blob/develop/Glance/Credits.rtf",
	)!
	static let license = URL(
		string: "https://github.com/ranokay/glance/blob/develop/LICENSE.md",
	)!
	static let privacy = URL(
		string: "https://github.com/ranokay/glance/blob/develop/PRIVACY.md",
	)!
}
