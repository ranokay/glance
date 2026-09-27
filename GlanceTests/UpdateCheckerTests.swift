import GlanceKit
import XCTest

private final class TestBox<T>: @unchecked Sendable {
	var value: T

	init(_ value: T) {
		self.value = value
	}
}

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
		let url =
			try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
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
		store.lastUpdateCheckDate = Date(timeIntervalSince1970: 1000)
		store.lastNotifiedUpdateVersion = "v9.9.9"
		XCTAssertFalse(store.autoUpdateCheckEnabled)
		XCTAssertEqual(store.lastUpdateCheckDate, Date(timeIntervalSince1970: 1000))
		XCTAssertEqual(store.lastNotifiedUpdateVersion, "v9.9.9")
	}

	func testServiceNotifiesOncePerVersionAndGatesDaily() async throws {
		let suiteName = "GlanceTests.UpdateService.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AppSettingsStore(defaults: defaults)
		let url =
			try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
		let release = GitHubRelease(
			tagName: "v9.9.9",
			htmlURL: url,
			draft: false,
			prerelease: false
		)
		let fetchCount = TestBox(0)
		let notified = TestBox([String]())
		let service = UpdateCheckService(
			settings: store,
			currentVersion: "9.9.0",
			fetch: { _ in fetchCount.value += 1; return release },
			now: { Date() },
			notified: { version, _ in notified.value.append(version) }
		)
		let first = await service.checkNow()
		let second = await service.checkNow()
		XCTAssertEqual(first, .available(version: "v9.9.9", url: url))
		XCTAssertEqual(second, .available(version: "v9.9.9", url: url))
		XCTAssertEqual(fetchCount.value, 2)
		XCTAssertEqual(notified.value, ["v9.9.9"])
		let due = await service.checkIfDue()
		XCTAssertNil(due)
	}

	func testServiceFailureIsSilentAndRetryable() async throws {
		let suiteName = "GlanceTests.UpdateServiceFail.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AppSettingsStore(defaults: defaults)
		let notified = TestBox(0)
		let service = UpdateCheckService(
			settings: store,
			currentVersion: "9.9.0",
			fetch: { _ in throw URLError(.notConnectedToInternet) },
			now: { Date() },
			notified: { _, _ in notified.value += 1 }
		)
		let result = await service.checkNow()
		XCTAssertEqual(result, .unknown(message: "Couldn’t check just now."))
		XCTAssertEqual(notified.value, 0)
		XCTAssertNil(store.lastUpdateCheckDate)
	}

	func testDeniedNotificationStillReturnsAvailableState() async throws {
		let suiteName = "GlanceTests.UpdateNotifyDenied.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }
		let store = AppSettingsStore(defaults: defaults)
		let url =
			try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
		let release = GitHubRelease(
			tagName: "v9.9.9",
			htmlURL: url,
			draft: false,
			prerelease: false
		)
		let service = UpdateCheckService(
			settings: store,
			currentVersion: "9.9.0",
			fetch: { _ in release },
			now: { Date() },
			notified: { _, _ in }
		)
		let result = await service.checkNow()
		XCTAssertEqual(result, .available(version: "v9.9.9", url: url))
		XCTAssertEqual(store.lastNotifiedUpdateVersion, "v9.9.9")
	}

	func testUnparseableVersionsNeverNotify() throws {
		XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v9.9.9", currentVersion: ""))
		XCTAssertFalse(UpdateChecker.isNewer(latestTag: "not-a-version", currentVersion: "9.9.0"))
		let url =
			try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
		let good = GitHubRelease(tagName: "v9.9.9", htmlURL: url, draft: false, prerelease: false)
		XCTAssertEqual(
			UpdateChecker.state(latest: good, currentVersion: ""),
			.unknown(message: "Couldn’t check just now.")
		)
		let garbage = GitHubRelease(
			tagName: "not-a-version",
			htmlURL: url,
			draft: false,
			prerelease: false
		)
		XCTAssertEqual(
			UpdateChecker.state(latest: garbage, currentVersion: "9.9.0"),
			.unknown(message: "Couldn’t check just now.")
		)
	}
}
