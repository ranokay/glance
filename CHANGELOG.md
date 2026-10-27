# Changelog

Append-only. Newest entry first.

# Unreleased

- EPUB previews render books whose package metadata omits `dc:title` and whose chapters use a
  bare HTML doctype, instead of falling back to the generic file icon.
- 7z previews bound decoded metadata, allocation-driving counts, and decoder
  memory before parsing or extraction, while retaining compressed-header and
  supported-codec compatibility. Validated metadata is reused from a snapshot.
- Settings scroll vertically at the minimum window size so approval and update
  controls remain reachable when their sections expand.
- Removed obsolete per-preview statistics writes and unused screenshot assets
  from the retired main window. Existing stored preferences remain untouched.
- Verification now checks actual Xcode test-target membership and covers real
  cross-process bookmark transfer and minimum-size Settings layout.
- Verification now proves the app actually launches: a launch gate
  (`scripts/check-app-launch.sh`, wired into `verify:app`) launches the built
  Release app as an isolated instance and requires a fresh receipt confirming
  its live delegate, menu, and registered status item after one second.
  `AppLaunchTests` also verifies the real status item inside the test host.
  Missing permissions and menu-bar overflow cannot silently skip the check.
- Verification captures can now be attached to tickets by the agent itself:
  `scripts/attach-capture.sh <issue> <image>` commits the capture to the
  `verification-captures` branch and posts it on the ticket, and the
  manual-capture convention in `docs/agents/verification.md` accepts
  agent-produced captures. Uploads accept normal screenshot sizes without
  exceeding command-line limits and link to immutable image commits.
- Dismissing Quick Look cancels an unfinished preview instead of installing it
  and restarting its file watcher after the window closes.
- Spreadsheet previews apply the expanded-byte budget to every ZIP part,
  including styles and relationships, and check ZIP metadata limits first.
- Open With keeps distinct applications separate on case-sensitive volumes
  while recognizing filesystem and symlink aliases.
- Extracting a later file from a solid 7z archive consumes preceding entries
  correctly instead of returning their bytes as the selected file.
- Test runs retain separate result bundles so later runs do not erase evidence.
- Quick Look previews for SQLite databases: `.sqlite`, `.sqlite3`, and `.db` files list their tables
  and show 50-row pages with declared column types, distinct `NULL` and empty values, and BLOB sizes
  instead of inline bytes. Tables, columns, cells, and rendered output are capped with explicit
  notices. Previews open immutable when no `-wal` sidecar exists and otherwise read a temporary
  copy, so the database file and its directory are never modified. Virtual generated columns are
  omitted, individual cells above the per-value safety limit are reported in place while the table
  list stays usable, and encrypted, truncated, or non-SQLite files show a clear message.

- Quick Look previews for structured data: `.json`, `.plist` (XML and binary), and `.xml` now
  render as collapsible trees with distinct string, number, boolean, null, date, data, key, and
  array-index presentation. Object keys keep their authored order. Malformed input falls back to
  syntax-highlighted text, and input, node, depth, and output caps show an explicit truncation
  notice instead of failing. XML entity declarations are never resolved. The tree uses the same
  Xcode-derived palette as the code previews, separates labels from values with a space, and
  keeps key-count hints out of copied text while preserving indentation.

- Quick Look web previews accept the first click and give the page keyboard focus on
  appearance, so disclosure controls, select-all, and copy respond immediately instead of
  only focusing the panel. Rapidly switching files no longer shows a spurious “Glance app is
  not running” page; previews always render with default appearance settings when the app is
  unavailable.

- Quick Look previews of Markdown, source code, and Jupyter notebooks now
  re-render when the file changes on disk, including atomic editor saves, and
  keep their scroll position. Deleting the file leaves the last good preview
  with a notice instead of an error page.

- Markdown previews now render inline and display TeX math with the bundled
  KaTeX, fully offline. Dollars inside code spans and fences stay literal, and
  invalid TeX shows its escaped source instead of failing the preview.
- Glance is now a true menu-bar-only app: no Dock icon, no main window, and no
  “Hide Dock icon” preference. Settings and Supported Files remain available
  from the status menu.
- Added values-only `.xlsx` previews with every worksheet, dates, booleans,
  cached formula values, and column letters. Styles, charts, `.xls`, and
  `.numbers` are out of scope.
- Archive previews now open files in place: double-click an entry in a ZIP,
  TAR, TAR.GZ, 7z, or RAR tree. Extracted entries are temporary, capped at
  25 MB, and deleted on Back; nested archives are allowed to depth 3.
- Markdown diagrams now render with Pele 1.9.0 instead of Mermaid.js, shrinking
  the bundled runtime by about 2.87 MB while keeping offline rendering and the
  existing Mermaid fence syntax.
- Lint and hooks now run through hk, with jactionlint checking GitHub Actions
  workflows. The release workflow drops its caches and pins every action to a
  commit SHA.
- CI no longer runs the 30-minute exploratory Quick Look corpus on every pull
  request; the gating corpus sweep remains in the unit suite. Workflow files and
  the SwiftLint configuration now use the `.yaml` extension, and actions,
  toolchains, and Rust dependencies were refreshed.
- Removed the obsolete macOS UI-test target (and its Automation permission
  prompt), main storyboard, main window controller, and unused icon/XIB code.
  The app menu is built in code.
- Cargo builds now share compiler outputs through Mr Boxington (`mbx`) locally
  and in CI. A clean release build of the Rust core dropped from 60 s to 4.6 s
  with a warm cache, and a fresh worktree reuses the same cache instead of
  recompiling every dependency.

# Glance 1.8.2

Glance 1.8.2 makes Quick Look previews follow the app's appearance settings and
keeps overflow information honest.

- Code, Markdown, EPUB, Draw.io, and Jupyter previews now use the font family,
  size, and line-wrapping chosen in Settings — the preferences previously
  never reached preview windows (the Quick Look extension reads a preferences
  store its sandbox cannot see; they now cross the local bridge).
- TSV previews display an informational row when files exceed the 5,000-row
  cap instead of stopping silently, and one malformed row past the cap no
  longer fails the whole preview.
- The Settings window resizes (and opens taller) so Start at Login error
  states never clip the update controls.
- Standalone and scripted builds get an explicit GlanceKit ordering: three
  GlanceKit target dependencies pointed at their own consumers in the project
  file, relying on implicit dependencies to mask it.
- The release pipeline publishes GitHub releases draft-first and attaches a
  signed Sparkle appcast per release, resolved only when fully assembled; the
  Rust dependency graph is clean again on strict audit (zip bumped to 9.0.3
  after crates.io yanked the pinned 8.6.0); CI restores the pinned-mise tool
  cache before installing tools.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.8.1

Glance 1.8.1 fixes the in-app updater's feed URL so those installs can discover
future releases automatically.

- The 1.8.0 build carried an update-feed URL pointing at a mirror branch that
  must stay untouched; 1.8.1 points the updater at the release-asset host that
  always serves the current release's signed feed.
- The update pipeline itself is unchanged from 1.8.0: Sparkle checks, verifies
  EdDSA signatures, downloads, and installs inside the app.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.8.0

Glance 1.8.0 installs its own updates from inside the app, without opening the
browser.

- Sparkle (`https://github.com/sparkle-project/Sparkle`, 2.10.0) drives
  software updates: scheduled checks, background downloads, EdDSA signature
  validation, sandboxed installation, and relaunching. No Apple Developer ID
  or notarization is involved.
- Settings shows live update status and an Install and Relaunch button once an
  update is downloaded; the menu bar's Check for Updates item opens Sparkle's
  update window. Update checks and background downloads both follow the
  existing Automatically check toggle.
- The 1.7.0 check-only path is removed along with its Notification Center
  alerts, release-page redirect button, and GitHub Releases API polling.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.7.0

Glance 1.7.0 adds software-update checks based on GitHub Releases.

- Settings gains a Software Update section showing whether Glance is up to date, with
  Check for Updates, Update Now (opens the release page), and an automatic-check option.
- Glance checks the latest stable release on launch and about daily, and posts one
  notification per new version. Checks are on by default and never download anything.
- Unparseable version data and failed checks stay silent and retry later instead of
  notifying.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.6.2

Glance 1.6.2 adds new preview kinds, appearance preferences, and reliability fixes.

- New previews: Mermaid diagrams in Markdown, Draw.io diagrams, 3MF models, RAR archives, EPUB books, FLAC waveform playback, Jupyter LaTeX outputs, and TypeScript and template source files, with broader source and data format recognition.
- Preview appearance preferences for font family, font size, and line wrapping, plus a Start at Login option.
- Fixes: FLAC audio stops when Quick Look closes, the app no longer quits silently in the background while previews need it running, archives reject oversized entries in every format, and folder navigation keeps cursor continuity.
- Shared Swift code now lives in the GlanceKit framework, and rendering, parsing, and directory enumeration run off the main thread with cancelled work discarded.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.6.1

Glance 1.6.1 improves folder browsing, preview transitions, media playback, and Quick Look chrome.

- Folder previews now load direct children lazily in independent 500-item pages, so a large nested
  folder cannot hide its siblings. Folders can be expanded on demand or opened with multi-level
  Back navigation while preserving selection, sorting, scroll position, and expansion state.
- Sorting and outline reloads keep Finder-style icons at a stable size, and enumeration failures
  provide an inline retry action.
- Audio and video previews use native AVKit controls with lifecycle-safe cleanup.
- Web previews wait for their first rendered frame, reducing white flashes while switching files in
  light or dark appearance.
- Preview chrome now has one contextual utility bar, compact single-line archive statistics, and
  appearance-aware surfaces that respect Finder's rounded clipping.

This release remains Apple-silicon-only for macOS 26 or later. The app is ad hoc signed; its DMG
is not Developer ID-signed or notarized, so verify the published SHA-256 checksum before installation.

# Glance 1.6.0

Glance 1.6.0 replaces its HTML renderer and untrusted file-format parsers with a bounded Rust
preview core while preserving the native Swift/AppKit Quick Look experience.

- Source, Markdown, and Jupyter rendering now use the Rust preview core with the existing visual
  styles and stricter handling of unsafe HTML and URLs.
- TSV, ZIP/JAR/EAR/WAR, TAR/tgz, and 7z metadata parsing now runs in Rust with explicit input,
  entry-count, metadata, and scan limits; Swift retains the bounded archive-tree construction.
- Preview rendering, parser work, JSON decoding, and directory enumeration run outside the main
  thread and discard cancelled results.
- The Go runtime and the SwiftCSV, ZIPFoundation, SWCompression, and BitByteData packages have been
  removed from the shipping app.

This release remains Apple-silicon-only for macOS 26 or later. Its DMG is unsigned and
unnotarized; verify the published SHA-256 checksum before installation.
