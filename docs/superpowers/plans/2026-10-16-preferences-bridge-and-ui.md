# Preferences bridge + Settings overflow + TSV truncation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (` - [x]`) syntax for tracking.

**Goal:** Implement repo issues #101, #105, #102: surface main-app preview preferences inside the sandboxed Quick Look extension over the existing notification bridge, stop the Settings window from clipping when login-item status adds rows, and surface TSV row-limit truncation instead of displaying silently cut data.

**Architecture:** (1) The `PreviewSettingsBridge` wire format grows from `"id|waveform"` to `"id|waveform|family|size|wrap"` (family percent-encoded with a `-` sentinel), clients offer one `previewAppearance()` snapshot call; WebPreviewVC builders pass the appearance explicitly instead of reading the app-group suite from inside the extension sandbox. (2) `SettingsWC` window becomes resizable with a 440×490 minimum and a 560 default height. (3) Rust `TsvPayload` gains `truncated` (one record beyond `MAX_ROWS` discovered leniently), surfaced by `TablePreviewVC` as a synthesized informational final row (the DirectoryPreview loadMore-row convention).

**Tech Stack:** Swift 6 (AppKit), the CSVS-rust `glance_parse_tsv` FFI bridge, XCTest.

**Spec:** GitHub issues ranokay/glance #101, #105, #102 (findings from #99's Codex review; all pre-existing bugs).

## Global Constraints

- Wire hygiene: only non-sensitive display preferences cross the unauthenticated local notification channel; keep the comment in place.
- No version/build literals in unit tests; `mise run lint` (swiftlint strict + pinned swiftformat) must stay green.
- Rust changes: `cargo fmt --check`, `clippy --locked -D warnings`, `cargo test` must pass.
- Repos rule: UI-affecting tickets still need one manual Finder Quick Look capture (user's pass).
- Do not touch `main`; work branches off `develop`.

## Review Focus

1. **Percent-encoded family round-trip:** font names with non-alphanumerics ("San Francisco", quotes) must survive encode→decode byte-exact; sentinel `-` isn't a real family. → unit test in T1.
2. **Timeout/cancellation fallback still defaults correctly:** existing behavior is waveform=true; the snapshot fallback is wave=true + appearance `.default`. → unit test with a non-answering fake center in T1.
3. **TSV premium-row error leg:** a malformed row BEYOND the 5000-cap must mark truncation, not abort the whole preview (current behavior aborts). → Rust test in T3.
4. **No regression to app-group defaults behavior in the main app:** in-host app everything still answers from the real store. → covered by existing PreviewVCFactoryTests staying green.

---

### Task 1: Preference snapshot across the bridge (#101)

**Files:**
- Modify: `Glance/Shared/Utils/AppSettings.swift` (PreviewSettingsBridge encode/decode, `PreviewPreferenceSnapshot`, server snapshot response, client `previewAppearance()` + derived `flacWaveformEnabled()`)
- Modify: `QLPlugin/Views/PreviewVCs/WebPreviewVC.swift` (drop broken `AppSettingsStore.shared` default args → `PreviewAppearancePreferences.default`)
- Modify: `QLPlugin/Views/Previews/{MarkdownPreview,EPUBPreview,DrawIOPreview,JupyterPreview}.swift` (pass `await PreviewSettingsClient.shared.appearancePreferences()`)
- Modify: `QLPlugin/Views/NestedPreviewProvider.swift:143` (drop broken default: `false`-respecting explicit true default, the call site at :52 decides)
- Modify: `QLPlugin/Views/NestedPreviewProvider.swift:143`
- Test: `GlanceTests/PreviewSupportTests.swift` (round-trip + sentinel + malformed + timeout already localizable without network, since the client takes injected center + store defaults)

**Interfaces:**
- Produces:

```swift
public struct PreviewPreferenceSnapshot: Sendable, Equatable {
	public let waveformEnabled: Bool
	public let appearance: PreviewAppearancePreferences
	public static let `default` = ...(waveformEnabled: true, appearance: .default)
}
extension PreviewSettingsClient {
	public func previewAppearance() async -> PreviewAppearancePreferences   // one bridge round trip
}
```
- Server response wire: `"<id>|<w01>|<family-or-ahead->|<size>|<wrap01>"`; family encoded via `addingPercentEncoding(withAllowedCharacters: .alphanumerics)`, `-` sentinel = nil.

- [x] Step 1: encode/decode round-trip unit test (+ sentinel, malformed defaults)
- [x] Step 2: implement bridge (server + client) and update 4 preview call sites + WebPreviewVC defaults + NestedPreviewProvider default
- [x] Step 3: `mise run test:xcode` green
- [x] Step 4: commit `feat: carry preview appearance preferences over the QL bridge (#101)`

### Task 2: Settings window overflow (#105)

**Files:**
- Modify: `Glance/SettingsWC.swift` (styleMask `.resizable`, `window.minSize`, default height 560)
- Test: `GlanceTests/WindowAppearanceTests.swift` (style mask contains `.resizable`; min size 440×490)

- [x] Step 1: test asserting resizable + min size
- [x] Step 2: implement
- [x] Step 3: `mise run test:xcode` green
- [x] Step 4: commit `fix: keep Settings content visible across login-item states (#105)`

### Task 3: TSV truncation indicator (#102)

**Files:**
- Modify: `PreviewCore/src/model.rs` (`TsvPayload` gains `truncated: bool`)
- Modify: `PreviewCore/src/tsv.rs` (overflow detection: stop at `MAX_ROWS`, probe one more record leniently, set flag)
- Modify: `QLPlugin/Utils/PreviewCoreBridge.swift` (`TSVPreviewPayload.truncated`)
- Modify: `QLPlugin/Views/Previews/TSVPreview.swift` (pass flag through)
- Modify: `QLPlugin/Views/PreviewVCs/TablePreviewVC.swift` (`truncated` param, informational tail row via dataSource)
- Test: Rust tests in `PreviewCore/src/tsv.rs` tests module (rows == cap exactly → truncated false; cap+1 → true; malformed overflow row → truncated true, no abort)

- [x] Step 1: Rust tests first (expect failure)
- [x] Step 2: implement rust + bridge +VC indicator
- [x] Step 3: `mise run test:rust` green + full `mise run verify` green later in T4
- [x] Step 4: commit `feat: surface TSV row-limit truncation in the preview (#102)`

### Task 4: Gates + PR

- [x] Step 1: `mise run verify`
- [x] Step 2: manual capture note: Finder Spacebar on a .tsv with >5k rows (user)
- [x] Step 3: branch `fix/preferences-bridge-and-ui`, PR to `develop`, link, watch
