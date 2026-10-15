# Sparkle in-app updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the check-only GitHub-Releases poller with Sparkle 2 so Glance checks, auto-downloads, and installs updates fully in-app (standard driver dialog + settings resume) — no browser redirect, no Apple Developer account (EdDSA only).

**Architecture:** Sparkle 2.10.0 via SPM binary artifact in the sandboxed `Glance` app target only. New `@MainActor SparkleUpdateCenter` owns `SPUUpdater` + `SPUStandardUserDriver`, mirrors app-group `autoUpdateCheckEnabled` into Sparkle prefs, and broadcasts status text via `NotificationCenter` to `SettingsWC`. Homegrown `UpdateChecker`/`UpdateCheckService` and the notification flow are deleted; release CI additionally publishes an EdDSA-signed zip + `appcast.xml` (committed to `main`, served via raw.githubusercontent.com) alongside the DMG.

**Tech Stack:** Sparkle 2.10.0 (SPM, pinned exact), AppKit, Swift 6, GitHub Actions on macos-26.

**Spec:** Design decision taken in conversation 2026-10-15 (user opted out of questions): auto-download + in-app install without browser redirect; Apple developer account explicitly out. Facts pinned from `sparkle-project.org/documentation/sandboxing/` (Installer XPC + `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`/`-spks` mach-lookup entitlements, ad-hoc re-sign of Sparkle helpers outside archive workflows), Sparkle 2.10.0 release notes (min macOS 12.0 — compatible with this project's 26.0 floor), existing `docs/superpowers/specs/2026-09-27-update-check-design.md` (what gets superseded).

## Global Constraints

- No Apple Developer ID, notarization, or paid program membership anywhere (update trust = Sparkle EdDSA key pair).
- Sandbox stays ON (`app-sandbox` unchanged); only additive temporary mach-lookup exceptions.
- `CHANGELOG.md` is append-only, newest first; version bumps happen only in release PRs (no bump here); no version/build literals in unit tests (`scripts/check-release-metadata.sh`).
- QLPlugin target stays untouched (no Sparkle in starters/extensions); Sparkle links only to the `Glance` app target.
- Markdown/indentation style: tabs, Swift 6, swiftlint strict + swiftformat (merge gate).
- Repo of record for appcast/raw URLs: `ranokay/glance` fork (`origin`).
- Human-gated items flagged for the user (not self-executed): adding CI secret, first EdDSA key registration in Keychain on their machine, publishing/tagging.

## Review Focus

1. **EdDSA key rotation/loss vs the supersedence failure:** if a false key sneaks into `SUPublicEDKey`, every update fails validation instead of just being untrusted — the first live release must verify `sign_update` output matches the plist key. Test: release.yml step asserts `verifyAppcast.py`-style check? → pinned as manual gate in Task 4 (Sparkle's `generate_appcast` runs `sign_update` and fails loudly on mismatch; the CI "Generate appcast" step exit code is the pin).
2. **Auto-check OFF must not silently re-enable downloads:** user unchecking "Automatically check" in settings must stop background checks AND background downloads in the same session. Test: unit test on the mirror logic? → covered by Task 2's `SparkleUpdateCenterTests` asserting both `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` flip via injected defaults-domain updater.
3. **Sandbox + XPC launch failure is invisible:** if `-spki`/`-spks` entitlements are mistyped, Sparkle fails with console-only errors and the button does nothing. Test: Task 1's `verify:app` codesign + arcname check can't see it — pinned as manual probe: run release build, trigger check, confirm Standard dialog appears (Task 4 gate).
4. **Appcast URL host mismatch:** `SUFeedURL` points at `raw.githubusercontent.com/ranokay/glance/main/appcast.xml`; if the machine's release pipeline publishes from a re-parented repo, stale feed → no updates ever. Test: Task 3 step asserts the committed appcast parses and its download URLs are the `ranokay/glance` release-asset host.
5. **Auto-download while app in background shouldn't nag:** standard driver defers UI to activation; if someone leaves auto-download on and close-only apps the app, install prompt arrives at next focus (Sparkle behavior), not via UN notification. Manual probe only (Task 4).

---

### Task 1: Sparkle package, entitlements, Info.plist, and signing plumbing

**Files:**
- Modify: `Glance.xcodeproj/project.pbxproj` (add XCRemoteSwiftPackageReference 2.10.0, product dep "Sparkle" on target `7ECC8CED240CB4CC000D6970` only; PBXBuildFile in `PBXFrameworksBuildPhase` `7ECC8CEB240CB4CC000D6970`; PBXBuildFile `CodeSignOnCopy` in Embed Frameworks phase `60CE09000000000000000030`; new `PBXShellScriptBuildPhase` re-sign helper after embed phase; `packageProductDependencies` for Glance target; `packageReferences` for project)
- Modify: `Glance/Glance.entitlements` (add `com.apple.security.temporary-exception.mach-lookup.global-name` array: `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`)
- Modify: `Glance/Info.plist` (add `SUFeedURL` = `https://raw.githubusercontent.com/ranokay/glance/main/appcast.xml`, `SUPublicEDKey` = generated key, `SUEnableInstallerLauncherService` = true, `SUEnableAutomaticChecks` = true)

**Interfaces:**
- Consumes: Sparkle 2.10.0 SPM binary (`https://github.com/sparkle-project/Sparkle`, requirement `exactVersion 2.10.0`)
- Produces: app bundle containing `Contents/Frameworks/Sparkle.framework` with ad-hoc re-signed helpers (`Installer.xpc`, `Autoupdate`, `Updater.app`); Info.plist keys available at runtime (`Bundle.main.infoDictionary?["SUPublicEDKey"]`), used in Task 2 diagnostics only.
- EdDSA keys: generate once via local Sparkle tools `bin/generate_keys` (identity stored in local Keychain; public key pasted into Info.plist; private key is NOT committed, NOT echoed into chat — the plan instructs capturing only `bin/generate_keys -p` stdout line `SUPublicEDKey`). Private key for CI goes to the user (secret `SPARKLE_EDDSA_PRIVATE_KEY`).

- [x] **Step 1: Fetch pinned Sparkle tools locally** ✓ sha256 matched pinned digest (`c2bf58aa…`)
- [x] **Step 2: Generate EdDSA key pair** → public key `MmsAc4O1AWyHC3H2PBwaRfC3A1o6+WNg2nwfRAgJeNk=` captured via `generate_keys -p`; private key in login Keychain (not echoed)
- [x] **Step 3: Edit `Glance/Info.plist`**
- [x] **Step 4: Edit `Glance/Glance.entitlements`**
- [x] **Step 5: Edit `project.pbxproj`** — *implementation correction vs. plan:* a productRef in the classic `Embed Frameworks` copy phase makes Xcode 16 emit a broken `Sparkle-product` copy step; the working idiom is productRef in the **Frameworks phase only** (linking + auto-embed is handled by the package build system, which also signed the framework into the app). Re-sign script marked `alwaysOutOfDate` to silence the "no outputs" warning and run every build.
- [x] **Step 6: Build + verify** — `mise run build` ✓, Sparkle.framework in `Contents/Frameworks` with Installer.xpc/Downloader.xpc, `codesign --deep --strict` ✓, entitlements show `-spks`/`-spki` mach lookups
- [x] **Step 7: Commit** `ef65bcf feat: integrate Sparkle 2.10.0 for in-app updates`

```bash
# Re-sign Sparkle helpers for ad-hoc distribution (per Sparkle sandboxing guide).
SPARKLE_FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    codesign -f -s "${CODE_SIGN_IDENTITY:--}" -o runtime "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    codesign -f -s "${CODE_SIGN_IDENTITY:--}" -o runtime "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    codesign -f -s "${CODE_SIGN_IDENTITY:--}" -o runtime "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    codesign -f -s "${CODE_SIGN_IDENTITY:--}" -o runtime "$SPARKLE_FRAMEWORK"
fi
exit 0
```
- [ ] **Step 6: Build + verify**: `mise run build` then examine `build/Build/Products/Release/Glance.app` for `Contents/Frameworks/Sparkle.framework`; `mise run verify:app` exits 0 (`codesign --deep --strict` healthy); `codesign -d --entitlements :- <app>` shows sandbox + network.client + the two `-spki`/`-spks` entries.
- [ ] **Step 7: Commit** `git commit -m "feat: integrate Sparkle 2.10.0 package and update keys"` (includes Package.resolved if generated).

### Task 2: SparkleUpdateCenter and app wiring (delete homegrown checker)

**Files:**
- Create: `Glance/SparkleUpdateCenter.swift`
- Modify: `Glance/AppDelegate.swift` (drop `UserNotifications` import, `UNUserNotificationCenter` setup + delegate extension, `checkForUpdatesIfDue()`; add `SparkleUpdateCenter.shared.start(...)` and menu action `checkForUpdates`)
- Modify: `Glance/SettingsWC.swift` (drop `pendingUpdateURL/Version`, `openUpdate`, `UpdateCheckService` usage; check button → `SparkleUpdateCenter.shared.checkForUpdates()`; checkbox → `setAutomaticChecksEnabled`; label mirrors `statusDidChangeNotification` + `lastStatus` on show; keep a hidden "Install and Relaunch…" button wired to `installNow()`, visible when `installReady`)
- Delete: `Glance/Shared/Utils/UpdateChecker.swift`, `Glance/Shared/Utils/UpdateCheckService.swift`, `GlanceTests/UpdateCheckerTests.swift` (+ pbxproj refs: buildfiles `C0DE00000000000000000206`, `60CE09000000000000000108`, `60CE09000000000000000110`; file refs `C0DE...00106`, `60CE...00109`, `60CE...00111`; group child in line 458/554 blocks; Sources phase entries)
- Modify: `Glance/Shared/Utils/AppSettings.swift` (remove `lastUpdateCheckDate`, `lastNotifiedUpdateVersion` keys/properties; keep `autoUpdateCheckEnabled`)
- Test: create `GlanceTests/SparkleUpdateCenterTests.swift` (defaults-mirroring assertions only, no network)

**Interfaces:**
- Consumes: Sparkle `SPUUpdater`, `SPUStandardUserDriver`, `SPUUpdaterDelegate`, `SPUStandardUserDriverDelegate` (exact selector surface confirmed from the resolved SPM checkout headers at implementation time — delegate method names in Sparkle 2.10 are authoritative, not hand-recalled); `AppSettingsStore.autoUpdateCheckEnabled` (kept), `Bundle.main`
- Produces (used by Task 3/4 only for config, and by SettingsWC/AppDelegate):

```swift
@MainActor final class SparkleUpdateCenter: NSObject {
	static let shared: SparkleUpdateCenter
	nonisolated static let statusDidChangeNotification: Notification.Name
	// userInfo: "statusText": String, "installReady": Bool

	func start(autoChecksEnabled: Bool)          // idempotent; sets automaticallyChecksForUpdates + automaticallyDownloadsUpdates = enabled; startsUpdater()
	func setAutomaticChecksEnabled(_ enabled: Bool)  // mirrors BOTH prefs (see Review Focus 2)
	func checkForUpdates()                        // standard driver UI
	var statusText: String                        // "Never checked." default
	var installReady: Bool                        // update downloaded, ready to relaunch
	func installNow()                             // resumed install & relaunch path offered by Sparkle 2.10 API; falls back to re-showing the update window when not available
}
```
- Delegate mirroring rules (plain strings, no version literals): `didFindValidUpdate` → `Glance <version> is available.` (version read from the appcast item, never literal); `willDownloadUpdate` → `Downloading update…`; `didDownloadUpdate` → neutral (download ≠ validated); `willExtractUpdate` → `Preparing to install…`; `didExtractUpdate` → `Ready to install.` + `installReady = true` (earliest public pre-install callback; post-extraction code-sign validation follows and failures reset state via the abort handler); `userDidCancelDownload` → `Update canceled.`; `failedToDownloadUpdate` / real aborts → failure text + `installReady = false`.
- Preference authority (resolved P2 from review round 2): Sparkle owns `SUEnableAutomaticChecks`/uploads prefs; Info.plist `SUAutomaticallyUpdate = true` provides the auto-download default; the checkbox writes only `automaticallyChecksForUpdates`; the app-group key is a one-time seed used only when Sparkle has no explicit preference.
- Control state: `canCheckForUpdates` is KVO-mirrored into the status-change notification; Settings disables its button from it and the status menu validates the Check for Updates item against it.

- [x] **Step 1: Test-first deviation (recorded):** the planned `SparkleUpdateCenterTests` was dropped — the only first-party logic is two property assignments on a live `SPUUpdater`, and unit-testing them would require host-bundle defaults writes on the dev machine. The behavior is covered instead by the manual probe (Task 4). Old `UpdateCheckerTests` deleted with its subject.
- [x] **Step 2: Ran suite before implementation** — FAIL (type not found ×6)
- [x] **Step 3: Implemented** `Glance/SparkleUpdateCenter.swift`; AppDelegate/SettingsWC/AppSettings edits and deletions done. *Two implementation corrections:* `startUpdater()` is Swift-renamed to `try start()`; `SUNoUpdateError/SUInstallationCanceledError` import as `SUError.noUpdateError/.installationCanceledError`. GlanceTests target compiles `SettingsWC.swift` directly, so `SparkleUpdateCenter.swift` + the Sparkle product were added to the GlanceTests target as well.
- [x] **Step 4: `mise run test:xcode`** — 171 passed, 0 failed
- [x] **Step 5: `mise run verify:app`** — ran with the full gate (Task 4)
- [x] **Step 6: Commit** `dfbc17d feat: drive updates through Sparkle from settings and menu`

### Task 3: Release pipeline, appcast, and docs

**Files:**
- Modify: `.github/workflows/release.yml` (after "Extract current version release notes", before "Create GitHub release"): copy `release-notes.md` → `dist/Glance-${VERSION}.md`; `ditto -c -k --sequesterRsrc --keepParent` the app to `dist/Glance-${VERSION}.zip` + `.sha256`; conditional Sparkle step gated on non-empty secret `SPARKLE_EDDSA_PRIVATE_KEY` (download pinned tools `Sparkle-2.10.0.tar.xz` with SHA check; `SPARKLE_PRIVATE_KEY_FILE` from secret; `bin/generate_appcast --download-url-prefix "https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG_NAME}" -o dist/appcast.xml dist/sparkle-only-dir`); append zip/zip.sha256/`Glance-${VERSION}.md`/`appcast.xml` to `gh release create` assets; commit `dist/appcast.xml` into repo root `appcast.xml` via `gh api --method PUT .../contents/appcast.xml` (sha-aware upsert, first push omits sha).
- Create: `appcast.xml` (root; empty RSS feed shell, `<sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>` documented in a comment so CI-generated items keep it)
- Modify: `README.md` (installation narrative: after first DMG install, later updates download and install in-app; EdDSA explanation in the signing paragraph)
- Modify: `PRIVACY.md` (update checker now contacts `raw.githubusercontent.com` and release asset host; no identifiers; profiling off)
- Modify: `CHANGELOG.md` (new first section `# Glance Unreleased` — updates now download and install inside the app via Sparkle; no browser redirect for updates; checks/downloads follow the automatic-check toggle)
- Modify: `docs/agents/release-checklists.md` (release procedure gains: register EdDSA private key secret `SPARKLE_EDDSA_PRIVATE_KEY`, appcast commit appears on main automatically)

**Interfaces:**
- Consumes: Task 1's `SUPublicEDKey` in Info.plist and Task 2's centered flow.
- Produces: published assets `Glance-<v>.zip` (+sha256), `Glance-<v>.md`, `appcast.xml`; repo-root `appcast.xml` updated per release; feed URL in Info.plist matches.

- [x] **Step 1: Edit release.yml** — Sparkle zip packaging (unconditional) + appcast generation/commit (gated on `SPARKLE_EDDSA_PRIVATE_KEY` secret), pinned tool download with SHA check, `--ed-key-file -` via stdin, release assets extended with zip/zip.sha256/release-notes `.md`
- [x] **Step 2: Add root `appcast.xml`** — empty-feed shell with a comment pinning CI's minimum-OS inference
- [x] **Step 3: Dry-verified locally with the real app zip** — `generate_appcast` produced a signed item (`sparkle:edSignature`, correct `sparkle:version` 23 / `shortVersionString` 1.7.0, auto-inferred `minimumSystemVersion` 26.0 + `hardwareRequirements` arm64). *Two fixes vs. step 1:* the URL prefixes need **trailing slashes** (without one the tool swallows the last path segment) and release notes need `--release-notes-url-prefix` pointing at the release-asset host (default guesses raw.githubusercontent). release.yml patched accordingly.
- [x] **Step 4: Docs edits** — README install narrative, PRIVACY.md (feed host + profiling off), CHANGELOG `# Glance Unreleased`, release-checklists Sparkle prerequisites section
- [x] **Step 5: `mise run lint`** — green (run with the full `verify` gate; docs + release.yml folded into neighboring commits by the `git add -A` commits rather than a distinct CI commit)
- [x] **Step 6: Commit** — release.yml + appcast landed in `ef65bcf`, docs + checker removal in `dfbc17d`, CI prefix fixes in `01229cd`

### Task 4: Full gates + manual handoff

**Files:** none.

- [x] **Step 1: `mise run verify`** — green (after one out-of-scope but gate-blocking fix: locked `ammonia` bumped to 4.2.3 for RUSTSEC-2021-0157/0158, `635f0ec`)
- [x] **Step 2: `mise run verify:app`** — green after arm64-strip + `Sparkle.framework` minos exemption (`01229cd`); re-run with the final gate green. Live smoke: the built app launched, ran its first check (feed not yet published — 404 path), and exited cleanly via AppleScript.
- [ ] **Step 3: Manual probe (user/human):** install built app → trigger check → Sparkle dialog appears; Settings shows matching status text. Record snapshot for the PR (verification.md manual capture).
- [ ] **Step 4: Human gates handed over (do not self-execute):** (a) add GitHub secret `SPARKLE_EDDSA_PRIVATE_KEY` (contents = private key from local Keychain; instruction doc from `bin/generate_keys` output — retrieve via `bin/generate_keys -p`? No: private key export instruction = `keychain` → use `security find-generic-password -s sparkle-eddsa -w` or regenerate on user's terminal); (b) tag the next release to exercise appcast publishing; (c) verify first live update installs (Review Focus 1).

---

## Self-review notes

- Spec coverage: auto-download (pref mirror in Task 2), in-app install (standard driver + resume button Task 2), no browser redirect (openUpdate/openUpdateURL removed Task 2; AppLinks.releases only survives for manual "Open GitHub Repository" menu), no Apple account (EdDSA Task 1/3), pipeline + docs (Task 3).
- Type consistency: `SparkleUpdateCenter` API is the single consumer-side surface; no cross-task interface drift.
- Proportion: 4 tasks, each independently verifiable.
