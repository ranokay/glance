# Release checklists

Step-by-step bump procedures. `scripts/check-release-metadata.sh` is the
machine-readable mirror of the version checklist — update its literals in the
same commit as any intentional bump, then run it.

## Version bump (1.6.1 build 21 → next)

1. `Glance.xcodeproj/project.pbxproj`: `MARKETING_VERSION` (×4: app + plugin ×
   Debug/Release) and `CURRENT_PROJECT_VERSION` (×4, same scopes). The app
   `Info.plist` follows via `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`.
2. `README.md`: hero line and requirements line (`Version X.Y.Z (build N)`).
3. `AppStore/Listing/Description.txt`: version line.
4. `CHANGELOG.md`: new entry on top, append-only, never rewrite history.
5. `scripts/check-release-metadata.sh`: version/build literals and occurrence
   counts; run the script.
6. Tag `vX.Y.Z` and push the tag — `release.yml` builds the DMG and creates
   the GitHub release with `--notes-file CHANGELOG.md`.

## Type add (new extension or new preview kind)

1. `QLPlugin/Info.plist` `QLSupportedContentTypes`: the file's UTI.
2. `Glance/Shared/Utils/SupportedPreviewRegistry.swift`: `extensionEntry`
   (plus a new `PreviewFileType` case when it is a new kind, not just a new
   extension of an existing one).
3. `Glance/Shared/Utils/PreviewVCFactory.swift`: switch arm mapping the new
   `PreviewFileType` to its `Preview` class (new kinds only).
4. Tests: extend the `PreviewFactoryTests` case table, add a smoke test, and
   drop a fixture in `GlanceTests/TestFiles` — the corpus sweep then covers
   the new type automatically.
5. Docs: extend the supported-types list in `AppStore/Listing/Description.txt`
   when the type is user-facing.

## Web-runtime bump (drawio, mermaid, or similar bundled viewer)

1. `docs/<name>-runtime.md`: new version, source URL, SHA-256 digest of the
   runtime and of its license file, measured Release size impact
   (`Glance.app` and `QLPlugin.appex` before/after), and any CSP changes.
2. `PreviewCore/THIRD_PARTY_LICENSES.md`: refresh the license table from
   `PreviewCore/Cargo.lock` (authoritative) when Rust dependencies move with
   the bump.
3. Run the full `mise run verify` — runtime swaps must survive the DOM,
   color-scheme, and corpus gates.
