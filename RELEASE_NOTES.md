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
