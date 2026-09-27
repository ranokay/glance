# Update check via GitHub Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add launch+daily stable-release checks against GitHub Releases with Settings status, menu item, and one notification per version; Update now opens the release page.

**Architecture:** Pure `UpdateChecker` + `GitHubRelease` decoding in GlanceKit with injected fetch/date/notify seams; `AppSettingsStore` gains three keys; `SettingsWC`/`AppDelegate` own UI and scheduling only.

**Tech Stack:** Swift 6, AppKit, `URLSession`, `UserNotifications`, XCTest, `mise run test:xcode`.

**Spec:** `docs/superpowers/specs/2026-09-27-update-check-design.md`

## Global Constraints

- macOS 26 deployment target (`MACOSX_DEPLOYMENT_TARGET = 26.0`), Xcode 26, Apple silicon arm64 only, no x86_64.
- Ad-hoc signed, unsigned DMG story unchanged; no signing/entitlement/deployment-target changes.
- Sandbox already has `com.apple.security.network.client`; no new entitlements.
- Version/build literals (`1.6.2`, `22`) live only in `Glance.xcodeproj/project.pbxproj`, `README.md`, `AppStore/Listing/Description.txt`, `scripts/check-release-metadata.sh` — never in product code or unit tests; tests use fake versions like `9.9.9`.
- `mise run lint` (`swiftlint lint --strict`, `swiftformat --lint .`) must stay green.
- Only host contacted is `api.github.com`; no identifiers sent; background failures are silent.
- Follow existing patterns: `AppSettingsStore(defaults:standardDefaults:)` injection, isolated `UserDefaults(suiteName:)` per test, `@MainActor` for UI, `Sendable` for cross-actor types.

## Review Focus

- Tag `v9.9.9` vs installed `9.9.9` must notify; same version must not — covered in Task 1 compare tests.
- `1.6.10` must beat `1.6.2` numerically (not lexicographically) — covered in Task 1 ordering test.
- Draft or prerelease payloads must never notify even when newer — covered in Task 1 filter tests.
- API 403/429 or malformed JSON on manual check must show retryable status, never crash or notify — covered in Task 3 failure test.
- Notification permission denied must still update Settings/menu status — covered in Task 5 denied-notifier test.

---

## File structure

- Create `Glance/Shared/Utils/UpdateChecker.swift` (GlanceKit target): `GitHubRelease`, `UpdateState`, `UpdateChecker.isNewer`, `UpdateChecker.state`. Pure, no network.
- Create `Glance/Shared/Utils/UpdateCheckService.swift` (GlanceKit target): `UpdateCheckService` with injected fetch/date/notify, 24h due-gate, single-flight. No UI.
- Modify `Glance/Shared/Utils/AppSettings.swift`: three keys + accessors (`autoUpdateCheckEnabled` default true, `lastUpdateCheckDate`, `lastNotifiedUpdateVersion`).
- Modify `Glance/Utils/Menu.swift`: add `AppLinks.releases` fallback URL.
- Modify `Glance/SettingsWC.swift`: Software Update section (status label, Check button, Update Now button, auto checkbox).
- Modify `Glance/AppDelegate.swift`: `Check for Updates…` menu item + launch-time due check + `UNUserNotificationCenter` hook.
- Test `GlanceTests/UpdateCheckerTests.swift`: all pure, store, and service tests with fakes.
- Modify `Glance.xcodeproj/project.pbxproj`: register the two new GlanceKit source files.

Interfaces (exact names every task uses):

```swift
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public let tagName: String
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
}
public enum UpdateState: Equatable, Sendable {
    case checking
    case upToDate
    case available(version: String, url: URL)
    case unknown(message: String)
}
public enum UpdateChecker {
    public static func isNewer(latestTag: String, currentVersion: String) -> Bool
    public static func state(latest: GitHubRelease?, currentVersion: String) -> UpdateState
    public static let latestReleaseURL: URL
    public static let checkInterval: TimeInterval
}
extension AppSettingsStore {
    public var autoUpdateCheckEnabled: Bool { get nonmutating set }
    public var lastUpdateCheckDate: Date? { get nonmutating set }
    public var lastNotifiedUpdateVersion: String? { get nonmutating set }
}
public final class UpdateCheckService: Sendable {
    public init(
        settings: AppSettingsStore,
        currentVersion: String,
        fetch: @Sendable @escaping (URL) async throws -> GitHubRelease,
        now: @Sendable @escaping () -> Date,
        notified: @Sendable @escaping (String, URL) async -> Void
    )
    public func checkNow() async -> UpdateState
    public func checkIfDue() async -> UpdateState?
}
```

---

### Task 1: Pure checker + release decoding

**Files:**
- Create: `Glance/Shared/Utils/UpdateChecker.swift`
- Modify: `Glance.xcodeproj/project.pbxproj`
- Test: `GlanceTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: none.
- Produces: `GitHubRelease`, `UpdateState`, `UpdateChecker.isNewer`, `UpdateChecker.state`, `UpdateChecker.latestReleaseURL`, `UpdateChecker.checkInterval` for Tasks 2–5.

- [ ] **Step 1: Write the failing test**

```swift
import GlanceKit
import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testNewerTagBeatsCurrentVersion() {
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "v9.9.9", currentVersion: "9.9.8"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v9.9.8", currentVersion: "9.9.8"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise run test:xcode`
Expected: FAIL — `UpdateChecker` not defined (build error in `UpdateCheckerTests`).

- [ ] **Step 3: Write minimal implementation**

```swift
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
        compare(normalize(latestTag), normalize(currentVersion)) == .orderedDescending
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
        guard isNewer(latestTag: latest.tagName, currentVersion: currentVersion) else {
            return .upToDate
        }
        return .available(version: latest.tagName, url: latest.htmlURL)
    }

    private static func normalize(_ value: String) -> [Int] {
        var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("v") || tag.hasPrefix("V") {
            tag = String(tag.dropFirst())
        }
        return tag.split(separator: ".").map { Int($0) ?? 0 }
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
```

- [ ] **Step 4: Register the file in the GlanceKit target**

Run: `grep -n "AppSettings.swift in Sources" Glance.xcodeproj/project.pbxproj`
Expected: one line like `60CE09000000000000000106 /* AppSettings.swift in Sources */`.

Add two entries mirroring that pattern (new IDs `60CE09000000000000000108` and `60CE09000000000000000109`): a `PBXBuildFile` line next to `...0106`, a `PBXFileReference` line next to the `AppSettings.swift` file reference, add the filename to the `Utils` group children, and add both build files to the GlanceKit `PBXSourcesBuildPhase` list. Verify with: `grep -n "UpdateChecker.swift" Glance.xcodeproj/project.pbxproj` showing 4 hits.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 6: Add ordering, prefix, draft, and decode coverage**

```swift
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
    XCTAssertEqual(UpdateChecker.state(latest: release, currentVersion: "9.9.0"), .available(version: "v9.9.9", url: release.htmlURL))
}
```

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add "Glance/Shared/Utils/UpdateChecker.swift" "Glance.xcodeproj/project.pbxproj" "GlanceTests/UpdateCheckerTests.swift"
git commit -m "feat(update): add pure GitHub release checker" -- "Glance/Shared/Utils/UpdateChecker.swift" "Glance.xcodeproj/project.pbxproj" "GlanceTests/UpdateCheckerTests.swift"
```

### Task 2: Update preferences in AppSettingsStore

**Files:**
- Modify: `Glance/Shared/Utils/AppSettings.swift`
- Test: `GlanceTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: isolated `UserDefaults(suiteName:)` pattern from Task 1 tests.
- Produces: `autoUpdateCheckEnabled`, `lastUpdateCheckDate`, `lastNotifiedUpdateVersion` for Tasks 3–5.

- [ ] **Step 1: Write the failing test** (append to `UpdateCheckerTests.swift`)

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise run test:xcode`
Expected: FAIL — `autoUpdateCheckEnabled` not defined.

- [ ] **Step 3: Write minimal implementation** (in `AppSettings.swift`, next to `flacWaveformEnabledKey`)

```swift
public static let autoUpdateCheckEnabledKey = "autoUpdateCheckEnabled"
private static let lastUpdateCheckDateKey = "lastUpdateCheckDate"
private static let lastNotifiedUpdateVersionKey = "lastNotifiedUpdateVersion"

public var autoUpdateCheckEnabled: Bool {
    get { defaults.object(forKey: Self.autoUpdateCheckEnabledKey) as? Bool ?? true }
    nonmutating set { defaults.set(newValue, forKey: Self.autoUpdateCheckEnabledKey) }
}

public var lastUpdateCheckDate: Date? {
    get { defaults.object(forKey: Self.lastUpdateCheckDateKey) as? Date }
    nonmutating set {
        guard let newValue else {
            defaults.removeObject(forKey: Self.lastUpdateCheckDateKey)
            return
        }
        defaults.set(newValue, forKey: Self.lastUpdateCheckDateKey)
    }
}

public var lastNotifiedUpdateVersion: String? {
    get { defaults.string(forKey: Self.lastNotifiedUpdateVersionKey) }
    nonmutating set {
        guard let newValue else {
            defaults.removeObject(forKey: Self.lastNotifiedUpdateVersionKey)
            return
        }
        defaults.set(newValue, forKey: Self.lastNotifiedUpdateVersionKey)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "Glance/Shared/Utils/AppSettings.swift" "GlanceTests/UpdateCheckerTests.swift"
git commit -m "feat(update): persist auto-check and notify-once state" -- "Glance/Shared/Utils/AppSettings.swift" "GlanceTests/UpdateCheckerTests.swift"
```

### Task 3: Check service with due-gate and single-flight fetch

**Files:**
- Create: `Glance/Shared/Utils/UpdateCheckService.swift`
- Modify: `Glance.xcodeproj/project.pbxproj` (same 4-hit pattern as Task 1, new IDs `...0110`/`...0111`)
- Test: `GlanceTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `GitHubRelease`, `UpdateChecker`, `AppSettingsStore` from Tasks 1–2.
- Produces: `UpdateCheckService.checkNow`, `checkIfDue` for Tasks 4–5.

- [ ] **Step 1: Write the failing test**

```swift
func testServiceNotifiesOncePerVersionAndGatesDaily() async throws {
    let suiteName = "GlanceTests.UpdateService.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppSettingsStore(defaults: defaults)
    let url = try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
    let release = GitHubRelease(tagName: "v9.9.9", htmlURL: url, draft: false, prerelease: false)
    var fetchCount = 0
    var notified: [String] = []
    let service = UpdateCheckService(
        settings: store,
        currentVersion: "9.9.0",
        fetch: { _ in fetchCount += 1; return release },
        now: { Date() },
        notified: { version, _ in notified.append(version) }
    )
    let first = await service.checkNow()
    let second = await service.checkNow()
    XCTAssertEqual(first, .available(version: "v9.9.9", url: url))
    XCTAssertEqual(second, .available(version: "v9.9.9", url: url))
    XCTAssertEqual(fetchCount, 2)
    XCTAssertEqual(notified, ["v9.9.9"])
    let due = await service.checkIfDue()
    XCTAssertNil(due)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise run test:xcode`
Expected: FAIL — `UpdateCheckService` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public final class UpdateCheckService: Sendable {
    private let settings: AppSettingsStore
    private let currentVersion: String
    private let fetch: @Sendable (URL) async throws -> GitHubRelease
    private let now: @Sendable () -> Date
    private let notified: @Sendable (String, URL) async -> Void

    public init(
        settings: AppSettingsStore,
        currentVersion: String,
        fetch: @Sendable @escaping (URL) async throws -> GitHubRelease,
        now: @Sendable @escaping () -> Date = Date.init,
        notified: @Sendable @escaping (String, URL) async -> Void
    ) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.now = now
        self.notified = notified
    }

    public func checkIfDue() async -> UpdateState? {
        guard settings.autoUpdateCheckEnabled else {
            return nil
        }
        if let last = settings.lastUpdateCheckDate, now().timeIntervalSince(last) < UpdateChecker.checkInterval {
            return nil
        }
        return await checkNow()
    }

    public func checkNow() async -> UpdateState {
        do {
            let release = try await fetch(UpdateChecker.latestReleaseURL)
            settings.lastUpdateCheckDate = now()
            let result = UpdateChecker.state(latest: release, currentVersion: currentVersion)
            if case let .available(version, url) = result, settings.lastNotifiedUpdateVersion != version {
                settings.lastNotifiedUpdateVersion = version
                await notified(version, url)
            }
            return result
        } catch {
            return .unknown(message: "Couldn’t check just now.")
        }
    }

    public static func liveFetcher() -> @Sendable (URL) async throws -> GitHubRelease {
        { url in
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 5: Add failure-path coverage**

```swift
func testServiceFailureIsSilentAndRetryable() async throws {
    let suiteName = "GlanceTests.UpdateServiceFail.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppSettingsStore(defaults: defaults)
    var notified = 0
    let service = UpdateCheckService(
        settings: store,
        currentVersion: "9.9.0",
        fetch: { _ in throw URLError(.notConnectedToInternet) },
        now: { Date() },
        notified: { _, _ in notified += 1 }
    )
    XCTAssertEqual(await service.checkNow(), .unknown(message: "Couldn’t check just now."))
    XCTAssertEqual(notified, 0)
    XCTAssertNil(store.lastUpdateCheckDate)
}
```

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "Glance/Shared/Utils/UpdateCheckService.swift" "Glance.xcodeproj/project.pbxproj" "GlanceTests/UpdateCheckerTests.swift"
git commit -m "feat(update): add due-gated check service with notify-once" -- "Glance/Shared/Utils/UpdateCheckService.swift" "Glance.xcodeproj/project.pbxproj" "GlanceTests/UpdateCheckerTests.swift"
```

### Task 4: Settings Software Update section

**Files:**
- Modify: `Glance/Utils/Menu.swift`
- Modify: `Glance/SettingsWC.swift`
- Test: extend `GlanceTests/WindowAppearanceTests.swift` with a settings-section test.

**Interfaces:**
- Consumes: `UpdateState`, `UpdateCheckService.liveFetcher`, `AppSettingsStore` keys from Tasks 1–3.
- Produces: visible status + buttons the manual capture in Task 5 verifies.

- [ ] **Step 1: Write the failing test**

```swift
func testSettingsShowsSoftwareUpdateSection() throws {
    let (store, suiteName) = try makeSettingsStore()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let controller = SettingsWC(settingsStore: store, fontFamilies: [])
    controller.loadWindow()
    let labels = allTextFields(in: controller.window!.contentView!)
    XCTAssertTrue(labels.contains { $0.stringValue == "Software Update" })
    XCTAssertNotNil(controller.checkForUpdatesButton)
    XCTAssertNotNil(controller.updateStatusLabel)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise run test:xcode`
Expected: FAIL — `checkForUpdatesButton` not defined.

- [ ] **Step 3: Add releases fallback link**

In `Glance/Utils/Menu.swift`, add:

```swift
static let releases = URL(string: "https://github.com/ranokay/glance/releases/latest")!
```

- [ ] **Step 4: Add minimal Settings UI** (in `SettingsWC.swift`, following existing `sectionLabel`/`descriptionLabel`/`separator` helpers)

```swift
let updateStatusLabel = NSTextField(labelWithString: "Checking…")
let checkForUpdatesButton = NSButton(title: "Check for Updates…", target: nil, action: nil)
let updateNowButton = NSButton(title: "Update Now…", target: nil, action: nil)
let autoUpdateCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
```

Wire in `setUpContent()`: append a `separator()`, `sectionLabel("Software Update")`, `updateStatusLabel`, `checkForUpdatesButton`, `updateNowButton`, `autoUpdateCheckbox` to the existing `stackView`; set targets to `checkForUpdates`, `openUpdate`, `autoUpdateChanged`; in `syncState()` set `autoUpdateCheckbox.state`, hide `updateNowButton` unless a pending URL is stored, and set `updateStatusLabel.stringValue` from a `pendingUpdateURL`/`pendingUpdateVersion` pair defaulting the label to `"You’re up to date."` when nil.

```swift
private var pendingUpdateURL: URL?
private var pendingUpdateVersion: String?

@objc
private func checkForUpdates(_: NSButton) {
    updateStatusLabel.stringValue = "Checking…"
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    Task { [weak self] in
        guard let self else {
            return
        }
        let service = UpdateCheckService(
            settings: settingsStore,
            currentVersion: current,
            fetch: UpdateCheckService.liveFetcher(),
            notified: { _, _ in }
        )
        let result = await service.checkNow()
        await MainActor.run {
            switch result {
                case .available(let version, let url):
                    pendingUpdateVersion = version
                    pendingUpdateURL = url
                    updateStatusLabel.stringValue = "Glance \(version) is available."
                case .upToDate:
                    pendingUpdateURL = nil
                    pendingUpdateVersion = nil
                    updateStatusLabel.stringValue = "You’re up to date."
                case .checking, .unknown:
                    updateStatusLabel.stringValue = "Couldn’t check just now."
            }
            syncState()
        }
    }
}

@objc
private func openUpdate(_: NSButton) {
    (pendingUpdateURL ?? AppLinks.releases).open()
}

@objc
private func autoUpdateChanged(_ sender: NSButton) {
    settingsStore.autoUpdateCheckEnabled = sender.state == .on
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 6: Run lint and format check**

Run: `mise run lint`
Expected: PASS (`swiftlint --strict` and `swiftformat --lint` clean).

- [ ] **Step 7: Commit**

```bash
git add "Glance/Utils/Menu.swift" "Glance/SettingsWC.swift" "GlanceTests/WindowAppearanceTests.swift"
git commit -m "feat(update): add Software Update section to Settings" -- "Glance/Utils/Menu.swift" "Glance/SettingsWC.swift" "GlanceTests/WindowAppearanceTests.swift"
```

### Task 5: Menu item, launch check, and notification

**Files:**
- Modify: `Glance/AppDelegate.swift`
- Test: `GlanceTests/UpdateCheckerTests.swift` (denied-notifier unit proof)

**Interfaces:**
- Consumes: `UpdateCheckService`, `AppLinks.releases` from Tasks 3–4.

- [ ] **Step 1: Write the failing test**

```swift
func testDeniedNotificationStillReturnsAvailableState() async throws {
    let suiteName = "GlanceTests.UpdateNotifyDenied.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppSettingsStore(defaults: defaults)
    let url = try XCTUnwrap(URL(string: "https://github.com/ranokay/glance/releases/tag/v9.9.9"))
    let release = GitHubRelease(tagName: "v9.9.9", htmlURL: url, draft: false, prerelease: false)
    let service = UpdateCheckService(
        settings: store,
        currentVersion: "9.9.0",
        fetch: { _ in release },
        now: { Date() },
        notified: { _, _ in }
    )
    XCTAssertEqual(await service.checkNow(), .available(version: "v9.9.9", url: url))
    XCTAssertEqual(store.lastNotifiedUpdateVersion, "v9.9.9")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise run test:xcode`
Expected: FAIL only if Task 3 regressed; otherwise PASS as a characterization of the notifier seam (permission-denied means the AppDelegate notifier no-ops while state still flows to Settings).

- [ ] **Step 3: Write minimal implementation** (in `AppDelegate.swift`)

Add `import UserNotifications`, a `Check for Updates…` item in `makeStatusMenu()` targeting `checkForUpdates`, and after `updateDockIconVisibility()` in `applicationDidFinishLaunching`:

```swift
Task { @MainActor in
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let service = UpdateCheckService(
        settings: AppSettingsStore.shared,
        currentVersion: current,
        fetch: UpdateCheckService.liveFetcher(),
        notified: { version, url in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Glance \(version) available"
            content.body = "Update now opens the release page."
            content.userInfo = ["url": url.absoluteString]
            let request = UNNotificationRequest(identifier: version, content: content, trigger: nil)
            try? await center.add(request)
        }
    )
    _ = await service.checkIfDue()
}
```

`checkForUpdates` opens Settings and triggers its check. Notification tap handling: set `UNUserNotificationCenter.current().delegate` to the app delegate once at launch and implement `userNotificationCenter(_:didReceive:)` to open `response.notification.request.content.userInfo["url"]` as a URL, falling back to `AppLinks.releases`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise run test:xcode`
Expected: PASS.

- [ ] **Step 5: Manual proof capture**

Open Settings → Software Update, screenshot the status row, attach to the ticket (one capture per repo verification rule).

- [ ] **Step 6: Commit**

```bash
git add "Glance/AppDelegate.swift" "GlanceTests/UpdateCheckerTests.swift"
git commit -m "feat(update): check on launch with notification and menu item" -- "Glance/AppDelegate.swift" "GlanceTests/UpdateCheckerTests.swift"
```

### Task 6: Full verification gate

**Files:** none (gate only).

- [ ] **Step 1: Run lint**

Run: `mise run lint`
Expected: PASS.

- [ ] **Step 2: Run all tests**

Run: `mise run test`
Expected: PASS (Rust + Xcode).

- [ ] **Step 3: Run release-metadata guard**

Run: `scripts/check-release-metadata.sh`
Expected: PASS (no version bump in this change).

- [ ] **Step 4: Run production verify**

Run: `mise run verify`
Expected: PASS.
