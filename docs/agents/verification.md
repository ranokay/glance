# Verification conventions

How UI proof works in this repo. The merge gate is fully automated; human eyes
confirm only what automation cannot.

## Automated gates (all merge-blocking, all run in CI)

- Unit tests (`mise run test:xcode`, GlanceTests target): behavior asserts only.
  Version/build/platform/pin strings live in `scripts/check-release-metadata.sh`,
  never in unit tests.
- Script regressions (`mise run test:scripts`): exercise launch receipts,
  timeouts, capture uploads, and failures through isolated command stubs.
- Test registration (`mise run test:registration`): every Swift source under
  `GlanceTests`, excluding preview fixtures, must resolve to the actual macOS
  Sources phase of `GlanceTests`. The check also runs in hk; synthetic project
  regressions cover missing membership and path/target confusion.
- Launch gate (`scripts/check-app-launch.sh`, run by `verify:app`): the built
  Release app launches as a separate instance through LaunchServices with a
  unique verification token. After one second in the run loop it reports that
  its delegate, main menu, and registered status item with an image and menu
  exist, then exits. The probe instance starts no IPC server or update check
  and changes no preferences. Missing receipts, launch failures, and timeouts
  fail the gate. No Accessibility permission is needed. `AppLaunchTests` also
  assert the hosted app's actual delegate and status item in the unit suite.
  These checks establish registration, not pixel visibility or menu interaction.
- Corpus sweep (`CorpusSweepTests`): every renderable fixture under
  `GlanceTests/TestFiles` must resolve through `PreviewVCFactory` and
  construct. Only the encryption-gated archives in its allowlist may throw.
- Scripted Quick Look corpus (`scripts/qlmanage-corpus.sh`): fuzzy over the
  same fixtures — fails on missing output, crashes, or hangs, never on pixel
  drift. Exploratory only and never run in PR CI: the hosted thumbnail daemon
  serves only Apple-owned types and never dispatches to the registered appex,
  and the run takes about 30 minutes. The gating corpus check is
  `CorpusSweepTests` in the unit suite.
- Fulfillment waits are always bounded with generous ceilings
  (Open-With round-trips 10 s, WebView loads 15 s); XCTest returns early on
  fulfillment, so generous ceilings only slow down genuine failures.

## Rust build cache

Cargo runs through Mr Boxington (`mbx`) via the `mr_boxington` option in
`mise.toml`. The local store lives in `~/Library/Caches/mbx`; `mbx cache stats`
and `mbx gc --dry-run` inspect it. CI restores the store with
`jdx/mr-boxington-action`; pull requests restore only. Pushes to `develop` that
change dependencies or tooling refresh the shared cache, and
`gh workflow run verify.yaml --ref develop` seeds it manually. Release builds
use the local store only, never a remote cache.

The action caches the Cargo target tree, so `mbx` object-cache counters can
report zero hits while Cargo still reuses the restored artifacts. Judge the
cache by the step time, not by those counters.

`test:rust` builds for `aarch64-apple-darwin` with
`MACOSX_DEPLOYMENT_TARGET=26.0`, matching `PreviewCore/build-xcode.sh`, so the
Xcode Debug build reuses its dependency artifacts.

## Local Quick Look registrations

Every local build registers its `QLPlugin.appex` with `pluginkit`, so System
Settings → Login Items gains one "Glance — Quick Look" row per build directory.
`mise run registrations:prune` unregisters everything except the installed
`/Applications/Glance.app` copy.

## Manual capture (per UI ticket, alongside automated evidence)

Each UI-affecting ticket adds one Quick Look capture: Spacebar-preview the
affected file type in Finder, screenshot the result, attach it to the ticket.
One capture per ticket, not per commit.

The agent fulfills this end to end: a capture produced through desktop
automation (cua-driver screenshot saved under `build/verification/`) counts as
the capture, and the agent attaches it to the ticket itself with
`scripts/attach-capture.sh <issue> <image>` — a ticket that names a capture is
not done until the image is on the ticket. Only where a ticket explicitly says
the capture is human-gated (e.g. asset changes) does the step wait for a human.
The script validates the issue before uploading and links the image at its
immutable commit. Capture files must contain only the intended preview.
Record an explicit user waiver on the ticket instead of requesting the same
capture again. If desktop capture is unavailable, record the missing evidence
and continue independent work; local file existence alone is not an attachment.

## Exploratory automation (never gating)

Desktop-automation drivers (cua-driver and friends) are exploratory-only:
useful for ad-hoc walkthroughs, never a merge gate, never a CI dependency.
No new screenshot or automation dependencies without a ticket.

## Human gates

Canonical list lives in `STATE.md` and is enforced by blocking checklist, not
by convention alone: destructive (reset/uninstall/shared-DerivedData clean),
publishing (releases, App Store), credentials (Apple ID, notarization,
keychain, VM secrets), and signing/entitlement/deployment-target changes.
Agents act alone on code, verify, and issue edits; anything on the gate list
goes through the `wizard` skill's blocking checklist with a human first.
