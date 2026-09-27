import GlanceKit
import XCTest

final class UpdateCheckerTests: XCTestCase {
	func testNewerTagBeatsCurrentVersion() {
		XCTAssertTrue(UpdateChecker.isNewer(latestTag: "v9.9.9", currentVersion: "9.9.8"))
		XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v9.9.8", currentVersion: "9.9.8"))
	}

	func testNumericOrderingBeatsLexicographicOrdering() {
		XCTAssertTrue(UpdateChecker.isNewer(latestTag: "v9.9.10", currentVersion: "9.9.9"))
		XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v9.9.9", currentVersion: "9.9.10"))
		XCTAssertTrue(UpdateChecker.isNewer(latestTag: "V9.9.9", currentVersion: "9.9.8"))
	}

	func testDraftAndPrereleaseNeverNotify() throws {
		let url = try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
		let draft = GitHubRelease(tagName: "v9.9.9", htmlURL: url, draft: true, prerelease: false)
		let pre = GitHubRelease(tagName: "v9.9.9", htmlURL: url, draft: false, prerelease: true)
		XCTAssertEqual(UpdateChecker.state(latest: draft, currentVersion: "9.9.0"), .upToDate)
		XCTAssertEqual(UpdateChecker.state(latest: pre, currentVersion: "9.9.0"), .upToDate)
	}

	func testMissingPayloadIsUnknown() {
		XCTAssertEqual(
			UpdateChecker.state(latest: nil, currentVersion: "9.9.0"),
			.unknown(message: "Couldn’t check just now.")
		)
	}

	func testDecodesLatestReleasePayload() throws {
		let json = """
		{"tag_name":"v9.9.9","html_url":"https://github.com/ranokay/glance/releases/tag/v9.9.9","draft":false,"prerelease":false}
		""".data(using: .utf8)!
		let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
		XCTAssertEqual(release.tagName, "v9.9.9")
		XCTAssertEqual(
			UpdateChecker.state(latest: release, currentVersion: "9.9.0"),
			.available(version: "v9.9.9", url: release.htmlURL)
		)
	}

	func testUpdatePreferencesDefaultOnAndPersist() throws {
		let suiteName = "GlanceTests.UpdatePrefs.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AppSettingsStore(defaults: defaults)
		XCTAssertTrue(store.autoUpdateCheckEnabled)
		XCTAssertNil(store.lastUpdateCheckDate)
		XCTAssertNil(store.lastNotifiedUpdateVersion)
		store.autoUpdateCheckEnabled = false
		store.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_000)
		store.lastNotifiedUpdateVersion = "v9.9.9"
		XCTAssertFalse(store.autoUpdateCheckEnabled)
		XCTAssertEqual(store.lastUpdateCheckDate, Date(timeIntervalSince1970: 1_000))
		XCTAssertEqual(store.lastNotifiedUpdateVersion, "v9.9.9")
	}
}
