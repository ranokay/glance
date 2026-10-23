# Menu-bar app, XLSX, archive entry previews, Pele, and tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Glance menu-bar-only, add values-only `.xlsx` previews, preview files inside archives, replace Mermaid.js with Pele, and make hk + jactionlint the local/CI lint gate.

**Architecture:** AppKit changes stay in the app and Quick Look extension. New parsers live in PreviewCore behind the existing bounded FFI, returning typed JSON. Archive entry previews extract one entry to a private temp file and reuse the existing nested-preview navigation. Pele replaces the Mermaid runtime behind the existing trusted sentinel.

**Tech Stack:** Swift 6/AppKit, PreviewCore (Rust), calamine, tar-rs, Pele 1.9.0, hk 2.8.0, jactionlint 2.2.0.

**Spec:** `docs/superpowers/specs/2026-10-23-menu-bar-xlsx-archives-pele-tooling.md`

## Global Constraints

- macOS 26 deployment target, Apple silicon, macOS 26+/Xcode 26+ CI. Local machine is newer; do not change deployment target.
- No version/build bump. Add an `# Unreleased` changelog section.
- Work on `develop`-based feature branches only.
- `mise run verify` is the merge gate: hk lint, Rust tests/audit, Xcode tests, release build.
- Do not add network access to previews. Pele links/images stay disabled; CSP stays `connect-src 'none'`.
- Temporary archive files use generated names, never archive paths; delete them when the nested preview is popped or the archive preview is torn down.
- XLSX is values-only: no styles, charts, images, conditional formatting, formula evaluation, `.xls`, or `.numbers`.
- `.dockerignore` already works; leave its registry entry and pinned test alone.

## Review Focus

1. **Archive path traversal/link entries:** a malicious archive must not cause a write outside the generated temp directory, and directory/link entries must not preview. → Task 5 tests.
2. **Temp cleanup on Back and teardown:** opening many entries must not leak temp files, including when the archive preview closes. → Task 5 tests.
3. **XLSX malformed/oversized input:** corrupt zips, duplicate sheets, >5,000 rows, >256 columns, and >64 sheets must fail or truncate honestly, never hang. → Task 4 tests.
4. **Pele untrusted diagram text:** links/images disabled, unique SVG IDs, malformed diagrams keep source visible, CSP unchanged. → Task 3 tests.
5. **Menu-bar activation with no Dock icon:** Settings and Supported Files still become key and usable as an accessory app; status menu still reaches them. → Task 2 test + manual capture.

---

### Task 1: hk + jactionlint gate

**Files:**
- Modify: `mise.toml`
- Create: `hk.pkl`
- Modify: `.github/workflows/verify.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `scripts/check-release-metadata.sh`
- Test: command gates only (configuration exception)

**Interfaces:**
- Produces: `mise run lint` → `hk check --all`; `hk install` local hook; jactionlint default profile clean.

- [ ] **Step 1: Pin tools in `mise.toml`**

Add exact pins: `hk = "2.8.0"`, `jactionlint = "2.2.0"`, `shellcheck = "0.11.0"`. Extend `scripts/check-release-metadata.sh` with the three pinned-tool checks.

- [ ] **Step 2: Add `hk.pkl`**

Use the 2.8.0 package URL, `Builtins.swiftlint`, `Builtins.cargo_fmt`, `Builtins.cargo_clippy`, `Builtins.jactionlint`, `Builtins.shellcheck`, plus a custom `swiftformat` step (`swiftformat --lint {{files}}` / `swiftformat {{files}}`) and a `release-metadata` step. Keep tests and release builds out of the hook.

- [ ] **Step 3: Make `mise run lint` use hk**

Change the task to `hk check --all`. Add a `hooks` task that runs `hk install`.

- [ ] **Step 4: Fix jactionlint's eight default findings**

Pin `actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830` (v4.3.0) and `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02` (v4.6.2). In `release.yml`, set top-level `permissions: {}`, job-level `permissions: contents: write`, add `timeout-minutes: 60`, and remove both cache steps. Keep `verify.yml` caches.

- [ ] **Step 5: Verify**

Run: `mise install && hk validate && jactionlint --profile default`
Expected: jactionlint exits 0 with no findings.
Run: `mise run lint`
Expected: hk exits 0.

- [ ] **Step 6: Commit**

`chore: adopt hk and jactionlint lint gates`

---

### Task 2: Menu-bar-only app

**Files:**
- Modify: `Glance/Info.plist`
- Modify: `Glance/AppDelegate.swift`
- Modify: `Glance/SettingsWC.swift`
- Modify: `Glance/Shared/Utils/AppSettings.swift`
- Test: `GlanceTests/PlistCoverageTests.swift`, `GlanceTests/WindowAppearanceTests.swift`

**Interfaces:**
- Produces: `LSUIElement` true; status menu without “Open Glance”; no `hideDockIcon` preference or Settings checkbox.

- [ ] **Step 1: Write failing tests**

Add `testAppInfoPlistMarksTheAppAsMenuBarOnly` asserting `LSUIElement == true`, and `testSettingsDoesNotOfferDockIconToggle` asserting no visible button/label contains “Hide Dock icon”. Run both and watch them fail.

- [ ] **Step 2: Make the app accessory-only**

Add `LSUIElement` to `Glance/Info.plist`. Remove `mainWindowController`, `openMainWindow`, window caching, window notifications, `DockIconVisibilityUpdating`, and `updateDockIconVisibility` from `AppDelegate`. Remove the “Open Glance” item; add an “About Glance” item.

- [ ] **Step 3: Remove the Dock preference**

Delete `hideDockIcon` and its standard-defaults migration from `AppSettingsStore`; remove the checkbox, description, action, and sync line from `SettingsWC`.

- [ ] **Step 4: Verify**

Run: `mise run test:xcode`
Expected: 177+ tests pass; the two new tests pass.
Run: `plutil -extract LSUIElement raw Glance/Info.plist`
Expected: `true`.

- [ ] **Step 5: Commit**

`feat: make Glance a menu-bar-only app`

---

### Task 3: Replace Mermaid.js with Pele

**Files:**
- Create: `QLPlugin/Resources/markdown/markdown-pele-1.9.0.global.js`
- Create: `QLPlugin/Resources/markdown/PELE_LICENSE.txt`
- Delete: `QLPlugin/Resources/markdown/markdown-mermaid-11.17.2.min.js`
- Delete: `QLPlugin/Resources/markdown/MERMAID_LICENSE.txt`
- Modify: `QLPlugin/Views/Previews/MarkdownPreview.swift`
- Modify: `QLPlugin/Resources/markdown/markdown-main.css`
- Modify: `GlanceTests/PreviewSmokeTests.swift`
- Modify: `docs/mermaid-runtime.md` → rename to `docs/pele-runtime.md`
- Modify: `Glance/Credits.rtf`

**Interfaces:**
- Produces: `window.pele` global; `.mermaid-diagram svg`; `data-glance-mermaid-state` preserved; light/dark via `--pele-*` CSS variables.

- [ ] **Step 1: Update tests first**

Change Mermaid smoke tests to expect `typeof window.pele === "object"`, a rendered `.mermaid-diagram svg`, failed malformed source state, and light/dark `--pele-bg` computed values. Update the runtime/license test to `markdown-pele-1.9.0.global` and `PELE_LICENSE.txt`. Run and watch the Mermaid tests fail.

- [ ] **Step 2: Vendor Pele 1.9.0**

Extract `pele.global.js` and `LICENSE` from the `pele@1.9.0` npm package into the Markdown resources under the names above. Delete the Mermaid files. Record the SHA-256 in the runtime doc.

- [ ] **Step 3: Wire the renderer**

In `MarkdownPreview`, load the Pele global and replace the render script with `pele.render(source, { idPrefix, maxWidth, links: false, images: false, fontFamily, fontSize })`. On error, mark the source failed and keep it visible. Keep the trusted sentinel.

- [ ] **Step 4: Theme Pele**

Add `--pele-bg`, `--pele-fg`, `--pele-muted`, `--pele-line`, `--pele-surface`, `--pele-surface-alt`, and `--pele-border` to the light and dark rules in `markdown-main.css`, mapped to the existing colors.

- [ ] **Step 5: Update docs and credits**

Replace `docs/mermaid-runtime.md` with `docs/pele-runtime.md` (version, npm source, SHA-256, license, size impact, Mermaid 12.1.0 compatibility, security settings). Replace the Mermaid credit with Pele 1.9.0 / kepano / MIT. Update the release checklist heading from Mermaid to Pele/Mermaid.

- [ ] **Step 6: Verify**

Run: `mise run test:xcode`
Expected: all tests pass, including the Pele smoke tests.

- [ ] **Step 7: Commit**

`feat: render Markdown diagrams with Pele`

---

### Task 4: Values-only XLSX preview

**Files:**
- Modify: `PreviewCore/Cargo.toml` (add `calamine = "=0.37.0"`)
- Create: `PreviewCore/src/xlsx.rs`
- Modify: `PreviewCore/src/lib.rs`, `PreviewCore/src/ffi.rs`, `PreviewCore/include/glance_preview_core.h`
- Create: `QLPlugin/Views/Previews/SpreadsheetPreview.swift`
- Create: `QLPlugin/Views/PreviewVCs/SpreadsheetPreviewVC.swift`
- Modify: `QLPlugin/Utils/PreviewCoreBridge.swift`
- Modify: `Glance/Shared/Utils/PreviewSupport.swift`, `SupportedPreviewRegistry.swift`, `PreviewVCFactory.swift`
- Modify: `QLPlugin/Info.plist`, `Glance/SupportedFilesWC.swift`
- Create: `GlanceTests/TestFiles/spreadsheet/example.xlsx`
- Test: `PreviewCore/src/xlsx.rs`, `GlanceTests/PreviewFactoryTests.swift`, `GlanceTests/PreviewSmokeTests.swift`, `GlanceTests/PlistCoverageTests.swift`

**Interfaces:**
- Produces: `glance_parse_xlsx(path, path_len)` → JSON `{"sheets":[{"name","rows","truncated"}]}`; Swift `PreviewCoreBridge.parseXLSX(at:) -> SpreadsheetPreviewPayload`; `PreviewFileType.spreadsheet`.

- [ ] **Step 1: Write failing Rust tests**

Add tests for two sheets, shared/inline strings, numbers, booleans, a date cell (`2026-10-23`), a cached formula value, malformed input, and row/column truncation. Run `cargo test --manifest-path PreviewCore/Cargo.toml xlsx` and watch them fail.

- [ ] **Step 2: Implement `xlsx.rs`**

Use `calamine::open_workbook_auto`, `sheet_names()`, and `worksheet_range()`. Convert `Data` to display strings; format `ExcelDateTime` with `to_ymd_hms_milli()` as `YYYY-MM-DD`, `HH:MM:SS`, or `YYYY-MM-DD HH:MM:SS`; format floats with `ryu`-style shortest output via `to_string`, trim trailing `.0`. Enforce 25 MB file, 5,000 rows, 256 columns, 64 sheets. Return a resource-limit error for oversized files and truncation flags for clipped sheets.

- [ ] **Step 3: Add the FFI and header**

Wire `glance_parse_xlsx`, add it to `lib.rs` exports and `glance_preview_core.h`.

- [ ] **Step 4: Write failing Swift tests**

Add `.xlsx` to `PreviewFactoryTests` (expected `SpreadsheetPreview.self`), the registry/UTI test, and a smoke test that loads the fixture and asserts sheet names and selected rows. Run and watch them fail.

- [ ] **Step 5: Implement the Swift bridge and UI**

Add `SpreadsheetPayload`/`SpreadsheetSheet` Decodable types and `parseXLSX`. Add `SpreadsheetPreviewVC` with an `NSPopUpButton` sheet picker, dynamic column letters, a value table, and a truncation tail row. `SpreadsheetPreview` creates it. Add the registry group/entry, `.spreadsheet` preview type, factory arm, UTI `org.openxmlformats.spreadsheetml.sheet`, Supported Files section, README/listing docs.

- [ ] **Step 6: Add the fixture**

Commit an `example.xlsx` with two sheets, shared strings, a date cell, and a cached formula value. The corpus sweep must construct it without throwing.

- [ ] **Step 7: Verify**

Run: `mise run test:rust`
Expected: all Rust tests pass.
Run: `mise run test:xcode`
Expected: all Xcode tests pass and the corpus sweep includes the XLSX fixture.

- [ ] **Step 8: Commit**

`feat: add values-only XLSX previews`

---

### Task 5: Preview files inside archives

**Files:**
- Modify: `PreviewCore/Cargo.toml` (add `tar = "=0.4.46"`)
- Modify: `PreviewCore/src/{zip,tar,sevenzip,rar}.rs`, `lib.rs`, `ffi.rs`, `include/glance_preview_core.h`
- Modify: `QLPlugin/Utils/FileTree.swift`, `QLPlugin/Utils/LegacyFileTree.swift`
- Modify: `QLPlugin/Views/Previews/ArchivePreview.swift`, `ZIPPreview.swift`, `TARPreview.swift`, `RARPreview.swift`, `SevenZipPreview.swift`
- Modify: `QLPlugin/Views/PreviewVCs/OutlinePreviewVC.swift`
- Modify: `QLPlugin/Views/NestedPreviewProvider.swift`
- Modify: `QLPlugin/MainVC.swift`, `MainVCNavigation.swift`, `MainVCBackgroundWork.swift`
- Modify: `QLPlugin/Utils/PreviewCoreBridge.swift`
- Test: `PreviewCore/src/*` archive tests, `GlanceTests/NestedPreviewTests.swift`, `GlanceTests/FileTreeTests.swift`, `GlanceTests/PreviewSmokeTests.swift`

**Interfaces:**
- Produces: Rust `extract_entry(path, entry, format, max_bytes)` and FFI `glance_extract_archive_entry`; Swift `ArchiveEntryFormat` (0 zip, 1 tar, 2 tarGz, 3 sevenZip, 4 rar), `ArchivePreviewContext`, `FileTreeNode.archiveEntryPath`, `NestedPreviewResult`.

- [ ] **Step 1: Write failing Rust extraction tests**

For each fixture, extract `example/hello-world.txt` (ZIP/TAR) or `hello.txt` (7z/RAR) and assert the bytes. Add tests for missing entries, directory entries, encrypted archives, oversized entries, and path traversal names. Run and watch them fail.

- [ ] **Step 2: Implement bounded extraction**

ZIP: `by_name`, size pre-check, `take(max+1)`. TAR: `tar::Archive` over a file or `MultiGzDecoder`, find the entry, size pre-check. 7z: `for_each_entries`, match name, read at most `max+1`. RAR: reuse the validated archive read, find the member metadata, reject encrypted/directory, then `read_member` with the size pre-check. All return resource-limit errors above the cap.

- [ ] **Step 3: Add the FFI**

Add `glance_extract_archive_entry(path, entry, format, max_bytes)`; validate UTF-8, format byte, and max > 0. Add it to the header and `lib.rs`.

- [ ] **Step 4: Write failing Swift tests**

Test that `FileTree` records `archiveEntryPath`; that an archive outline exposes it; that the provider extracts a file and returns a temp URL; that Back deletes the temp directory; that a second-level archive is rejected at depth 3; and that directories/links do not preview. Run and watch them fail.

- [ ] **Step 5: Implement archive context and navigation**

Add `archiveEntryPath` to `FileTreeNode`/`FileTree.addNode`. Add `ArchivePreviewContext` and attach it in `ArchivePreview.makePreview`. Generalize `OutlinePreviewVC`’s nested-browser condition. Add `NestedPreviewResult` and `makeArchiveEntryPreview`. In `MainVC`, push archive entry previews with a temp URL, delete it on pop/clear/teardown, and hide Open With for temp entries. Add the depth-3 guard. Route nested archive entries through the existing archive adapters with `depth + 1`.

- [ ] **Step 6: Verify**

Run: `mise run test:rust`
Expected: all Rust tests pass.
Run: `mise run test:xcode`
Expected: all Xcode tests pass; archive intent tests pass.

- [ ] **Step 7: Commit**

`feat: preview files inside archives`

---

### Task 6: Docs, changelog, and final gate

**Files:**
- Modify: `README.md`, `AppStore/Listing/Description.txt`, `CHANGELOG.md`
- Modify: `Glance/Credits.rtf`, `PreviewCore/THIRD_PARTY_LICENSES.md`
- Modify: `docs/agents/release-checklists.md`
- Create: `docs/adr/0001-pele-for-mermaid.md`, `docs/adr/0002-archive-entry-extraction.md` (only these two; no ADR for reversible copy/UI changes)

- [ ] **Step 1: Update user-facing docs**

README: menu-bar-only behavior, `.xlsx`, archive entry previews, Pele. Listing: same. Changelog: `# Unreleased` with the four feature bullets and the tooling bullet. Remove all “Hide Dock icon” wording.

- [ ] **Step 2: Update credits/licenses**

Replace Mermaid with Pele; add calamine, tar, and direct dependency rows to `THIRD_PARTY_LICENSES.md`. Update the release checklist runtime section to Pele.

- [ ] **Step 3: Write the two ADRs**

ADR-0001 records Pele vs Mermaid (size/security/layout trade-off). ADR-0002 records on-demand extraction, temp-file policy, and depth cap. Use `docs/adr/000N-*.md` with context/decision/consequences.

- [ ] **Step 4: Full gate**

Run: `mise run verify`
Expected: lint/hk, Rust tests/audit, Xcode tests, release build all pass.
Run: `mise run verify:app`
Expected: arm64-only, macOS 26 minos, codesign verify pass.

- [ ] **Step 5: Commit**

`docs: document menu-bar app, XLSX, archive previews, and Pele`

---

### Task 7: PR and evidence

- [ ] **Step 1: Push the branch**

`git push -u origin feature/menu-bar-xlsx-archives-pele-tooling`

- [ ] **Step 2: Create the PR**

Use `gh pr create --repo ranokay/glance --base develop --head feature/menu-bar-xlsx-archives-pele-tooling` with a body summarising the spec, verification, and manual capture needs.

- [ ] **Step 3: Link the PR**

Call the T3 `link_pull_request` tool with the full PR URL.

- [ ] **Step 4: Watch**

Call `watch_pull_request` if available and end the turn; otherwise report the PR URL and current check state.
