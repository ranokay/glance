# Menu-bar app, XLSX, archive entry previews, Pele, and tooling

**Status:** agreed 2026-10-23, tracked in
[#114](https://github.com/ranokay/glance/issues/114). This is the binding spec
for the implementation plan in
`docs/superpowers/plans/2026-10-23-menu-bar-xlsx-archives-pele-tooling.md`.

## Goal

Turn the existing Glance app into a true menu-bar-only container, add
values-only `.xlsx` previews, add previews for files inside archives, replace
the bundled Mermaid.js runtime with Pele, and adopt hk + jactionlint as the
lint/hook gate.

## Decisions

1. **Menu-bar-only app.** Glance runs as an accessory/`LSUIElement` app at all
   times. The main “Glance” window and its “Open Glance” menu item are removed.
   Settings, Supported Files, Start at Login, and Sparkle remain reachable from
   the status-item menu. The “Hide Dock icon” preference and its migration are
   removed because the Dock icon is never shown. Bundle ID, app name, and
   existing preferences stay unchanged.
2. **`.dockerignore` stays as-is.** It is already supported by the registry and
   pinned by `PreviewSupportTests`.
3. **XLSX is values-only.** Parse `.xlsx` with calamine in PreviewCore. Show
   every worksheet through a sheet picker, with column letters as headers,
   formatted dates/times, booleans, cached formula values, and auto-sized
   columns. Limits: 25 MB source file, 5,000 rows, 256 columns, 64 sheets.
   No cell styles, colors, fills, borders, merged-cell layout, charts, images,
   conditional formatting, formula evaluation, `.xls`, or `.numbers`. Add the
   Spreadsheet group to the registry, Quick Look UTIs, Supported Files, README,
   fixtures, and factory tests.
4. **GIF.** Do not claim `public.gif`; macOS already previews GIFs natively.
   GIFs work in folder thumbnails and through archive-entry previews once the
   extracted temp file is routed to the native preview.
5. **Archive entry previews.** Double-clicking a file entry in a ZIP, TAR,
   TAR.GZ/TGZ, 7z, or RAR outline opens a nested preview, with Back returning to
   the archive tree. Extract one entry at a time into a private temporary
   directory under a generated filename, never the archive path. Reject
   directories, links, and path traversal. Per-entry cap 25 MB; at most one
   extracted file is retained per nested preview and it is deleted when that
   preview is popped or the archive preview is torn down. Nested archives are
   allowed to depth 3. Open With remains hidden for temporary entries.
6. **Pele replaces Mermaid.js.** Bundle Pele 1.9.0’s `pele.global.js` and MIT
   license. Keep the existing `mermaid` fence syntax and
   `<!--glance-renderer-mermaid-v1-->` sentinel. Render synchronously with
   `links: false`, `images: false`, a unique `idPrefix`, and `maxWidth`;
   theme with Pele CSS variables in light and dark mode. Delete the Mermaid
   runtime and license. Accept Pele’s own layout/appearance; no Mermaid
   fallback. Arbitrary HTML labels stay unsupported; math labels show TeX.
7. **hk + jactionlint.** Pin `hk = "2.8.0"`, `jactionlint = "2.2.0"`, and
   `shellcheck = "0.11.0"` in `mise.toml`. Add `hk.pkl` steps for SwiftFormat,
   SwiftLint, Rust formatting, jactionlint, shellcheck, and release-metadata
   checks. `mise run lint` runs `hk check --all`; `hk install` wires the local
   pre-commit hook; tests and release builds stay in `mise run verify`.
   jactionlint uses the default profile with no baseline. Fix its eight current
   findings: pin `actions/cache` and `actions/upload-artifact`, move release
   permissions to the job with top-level `permissions: {}`, add a release job
   timeout, and remove both release-workflow cache steps to eliminate
   cache-poisoning risk.
8. **Delivery.** One branch off `develop`, one PR, independently revertible
   commits, no version bump. Add an `# Unreleased` changelog section. One manual
   Finder Quick Look capture per UI-affecting area remains a human step.

## Security and limits

- All archive extraction stays inside PreviewCore; Swift writes bytes to a
  private temporary directory using a generated name plus the entry’s
  extension only.
- No extracted file is opened with `Open With`.
- Pele runs under the existing CSP (`connect-src 'none'`) with links and images
  disabled; no network access.
- XLSX parsing is bounded by source size, row, column, and sheet caps.

## Out of scope

- Formatted XLSX fidelity, charts, images, conditional formatting, pivot
  tables, `.xls`, `.numbers`.
- Direct ownership of `public.gif`.
- Replacing mise as the build/test/task runner.
- Version bump, release, App Store submission, or notarization.
