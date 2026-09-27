import Foundation

public struct GitHubRelease: Decodable, Sendable, Equatable {
	public let tagName: String
	public let htmlURL: URL
	public let draft: Bool
	public let prerelease: Bool

	enum CodingKeys: String, CodingKey {
		case tagName = "tag_name"
		case htmlURL = "html_url"
		case draft
		case prerelease
	}

	public init(tagName: String, htmlURL: URL, draft: Bool, prerelease: Bool) {
		self.tagName = tagName
		self.htmlURL = htmlURL
		self.draft = draft
		self.prerelease = prerelease
	}
}

public enum UpdateState: Equatable, Sendable {
	case checking
	case upToDate
	case available(version: String, url: URL)
	case unknown(message: String)
}

public enum UpdateChecker {
	public static let latestReleaseURL = URL(
		string: "https://api.github.com/repos/ranokay/glance/releases/latest"
	)!
	public static let checkInterval: TimeInterval = 24 * 60 * 60

	public static func isNewer(latestTag: String, currentVersion: String) -> Bool {
		guard isValid(latestTag), isValid(currentVersion) else {
			return false
		}
		return compare(normalize(latestTag), normalize(currentVersion)) == .orderedDescending
	}

	public static func state(
		latest: GitHubRelease?,
		currentVersion: String
	) -> UpdateState {
		guard let latest else {
			return .unknown(message: "Couldn’t check just now.")
		}
		guard !latest.draft, !latest.prerelease else {
			return .upToDate
		}
		guard isValid(latest.tagName), isValid(currentVersion) else {
			return .unknown(message: "Couldn’t check just now.")
		}
		guard isNewer(latestTag: latest.tagName, currentVersion: currentVersion) else {
			return .upToDate
		}
		return .available(version: latest.tagName, url: latest.htmlURL)
	}

	private static func stripped(_ value: String) -> String {
		var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
		if tag.hasPrefix("v") || tag.hasPrefix("V") {
			tag = String(tag.dropFirst())
		}
		return tag
	}

	private static func isValid(_ value: String) -> Bool {
		let tag = stripped(value)
		guard !tag.isEmpty else {
			return false
		}
		return tag.split(separator: ".").allSatisfy { Int($0) != nil }
	}

	private static func normalize(_ value: String) -> [Int] {
		stripped(value).split(separator: ".").map { Int($0) ?? 0 }
	}

	private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
		for index in 0 ..< max(lhs.count, rhs.count) {
			let left = index < lhs.count ? lhs[index] : 0
			let right = index < rhs.count ? rhs[index] : 0
			if left < right {
				return .orderedAscending
			}
			if left > right {
				return .orderedDescending
			}
		}
		return .orderedSame
	}
}
