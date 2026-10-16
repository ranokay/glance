# Changelog

Append-only. Newest entry first.

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
