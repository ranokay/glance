# Glance software-update check — design

Date: 2026-09-27. Path: architectural, approach A (minimal GitHub Releases poller).
Status: awaiting human review before implementation planning.

## Intent

Notify the user when a newer stable `ranokay/glance` GitHub Release exists.
Settings shows update status; `Update now` opens the release page in the
browser. Background work is check-only: no DMG fetch, verify, or install.
Manual SHA/`xattr` install story in `README.md` stays as-is.

Agreed behavior:

- `Update now` opens the release page (`html_url`, fallback
  `https://github.com/ranokay/glance/releases/latest`).
- Automatic work is check-only: periodic poll + notify, never download.
- Checks on launch + ~daily, plus Notification Center alert on first sighting.
- Checks on by default; only stable (non-draft, non-prerelease) releases count.

## Architecture + components

- New `UpdateChecker` + `UpdateState` (`upToDate | available(version, url) |
  unknown`) next to `Glance/Shared/Utils/AppSettings.swift`. Reuses the
  existing app-group `UserDefaults`; no new framework or target.
- Pure `isNewer(latestTag, currentVersion)`: strips leading `v`, numeric
  per-component compare (`1.6.10` > `1.6.2`). Unit-testable, no plist access.
- `AppVersion.current` reads `CFBundleShortVersionString` at runtime. No
  version/build literals in code or tests (per `scripts/check-release-metadata.sh`).
- UI touchpoints only: one "Software Update" section in `SettingsWC.swift`
  (status label, `Check for Updates…`, `Update Now…` hidden unless available,
  `Automatically check` checkbox) and one `Check for Updates…` item in the
  `AppDelegate.swift` status menu.
- Persistence: two keys in `AppSettingsStore`: `lastUpdateCheckDate`,
  `lastNotifiedVersion`. No migration.

## Data flow + scheduling

- Triggers: after `migrateStandardDefaultsIfNeeded` in
  `applicationDidFinishLaunching` when auto-check is on and last check is
  older than ~24h; plus manual check anytime. Single-flight request.
- Request: `GET https://api.github.com/repos/ranokay/glance/releases/latest`,
  `Accept: application/vnd.github+json`, via `URLSession`.
- Response: read `tag_name`, `html_url`, `draft`, `prerelease`. Skip drafts and
  prereleases. Compare tag to `AppVersion.current`.
- If newer: refresh Settings status immediately; if tag differs from
  `lastNotifiedVersion`, post one `UNUserNotificationCenter` notification
  ("Glance <version> available — Update now opens the release page") and store
  the tag.
- `Update now` opens `html_url`. No download or installer code.

## Error handling + edge cases

- Failures (offline, timeout, 403/429 rate limit, bad JSON, missing tag) are
  silent in background: status shows "Couldn't check just now", retry via
  button, no notification, `lastCheckDate` left stale so the next launch retries.
- Unparseable latest tag or current version yields `unknown`: never notify.
- Only `api.github.com` is contacted, after launch, with no identifiers.
  Denied notification permission degrades to Settings/menu status only.
- Turning off "Automatically check" stops background requests; manual check
  keeps working.

## Testing + verification

- New `GlanceTests/UpdateCheckerTests.swift`: injected-version compare tests,
  draft/prerelease filtering, malformed tag handling, notify-once-per-tag
  dedup with an isolated `UserDefaults` suite. No `1.6.2`/`22` literals.
- No new UITest driving; existing launch + keep-always screenshot stands.
  Manual proof: one Settings → Software Update capture attached to the ticket.
- Gates: `mise run test:xcode` and `mise run verify` green;
  `scripts/check-release-metadata.sh` untouched (no version bump here).

## Defaults + non-goals

- Defaults: auto-check on; fresh installs start at "never checked / never
  notified" and notify once on first sighting of a newer stable release.
- Non-goals: no DMG download, no in-app SHA verify, no auto-install or
  relaunch, no Sparkle dependency, no appcast or `release.yml` change, no
  prerelease channel, no configurable interval (fixed ~24h), no in-app
  release-notes rendering.
- No signing, entitlement, deployment-target, destructive, publishing, or
  credential changes, so no wizard human-gate beyond normal review.
- Upgrade path: if API rate limits ever bite, swap the poll URL for a
  release-owned `update.json` feed. Revisit Sparkle only with signed and
  notarized distribution.
