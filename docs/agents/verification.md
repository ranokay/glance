# Verification conventions

How UI proof works in this repo. The merge gate is fully automated; human eyes
confirm only what automation cannot.

## Automated gates (all merge-blocking, all run in CI)

- Unit tests (`mise run test:xcode`, GlanceTests target): behavior asserts only.
  Version/build/platform/pin strings live in `scripts/check-release-metadata.sh`,
  never in unit tests.
- UI tests (GlanceUITests target, same scheme): app launch plus a
  keep-always screenshot attachment. Deterministic by construction: bounded
  launch wait, no wall-clock assertions, no menu-bar driving.
- Corpus sweep (`CorpusSweepTests`): every renderable fixture under
  `GlanceTests/TestFiles` must resolve through `PreviewVCFactory` and
  construct. Only the encryption-gated archives in its allowlist may throw.
- Scripted Quick Look corpus (`scripts/qlmanage-corpus.sh`): fuzzy over the
  same fixtures — fails on missing output, crashes, or hangs, never on pixel
  drift. Runs after the build in CI.
- Fulfillment waits are always bounded with generous ceilings
  (Open-With round-trips 10 s, WebView loads 15 s); XCTest returns early on
  fulfillment, so generous ceilings only slow down genuine failures.

## Manual capture (per UI ticket, alongside automated evidence)

Each UI-affecting ticket adds one manual Quick Look capture: Spacebar-preview
the affected file type in Finder, screenshot the result, attach it to the
ticket. One capture per ticket, not per commit.

## Exploratory automation (never gating)

Desktop-automation drivers (cua-driver and friends) are exploratory-only:
useful for ad-hoc walkthroughs, never a merge gate, never a CI dependency.
No new screenshot or automation dependencies without a ticket.
