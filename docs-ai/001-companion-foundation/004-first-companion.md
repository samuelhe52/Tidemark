# 001.004 — First native companion

## Context

On 2026-11-03 the maintainer authorized implementation, autonomous validation,
review, incremental local commits, and docs-ai maintenance. Entry 001 remains the
umbrella plan. This amendment is written before feature code.

## Plan

Deliver the first usable vertical slice: a nonactivating edge panel, deterministic
hover/dwell/leave/pin engine, persisted placement, a provisional native orb, and a
shared dashboard fed by credential-free local observations. The app alone joins
the three independent package targets.

Proposed files include `CompanionState.swift` and `DockPlacement.swift` in Engine,
`QuotaObservation.swift` and `PassiveQuotaReader.swift` in Data, `OrbView.swift` in
Appearance, and app-side panel/controller/dashboard files under `Sources/Tidemark/`.
Package tests will cover distinct engine transitions, placement, parsing, bounded
rollout reads, and freshness. Add a `make test` target.

| Decision | Reason / alternative |
| --- | --- |
| Ship a first vertical slice before history/live sources | Exercises the native interaction and real quota path together; avoids treating a large collection of isolated adapters as a usable companion. |
| Native SwiftUI orb is provisional | Orb art direction is unapproved. A shader and sprite skin remain later work; this renderer proves the independent Appearance boundary without deciding final art. |
| Passive sources only | No credential reads, refreshes, or edits to agent configuration are necessary. Read Claude's existing cache and an existing Tidemark tap file; do not install the tap automatically. |
| Preserve duration and dated unknown states | Primary Codex windows can be weekly. Missing, stale, future-dated, or expired observations must never imply available quota. |
| Menu-bar recovery stays for this slice | Gives a way to reveal/reset an off-screen companion and quit while placement and nonactivation are being validated. The final menu-bar decision remains open. |

## Acceptance and validation plan

- Engine tests use explicit times, including canceled deadlines, menus, drag, pin,
  re-entry and leave grace. Geometry tests cover outer edges and display fallback.
- Data tests use synthetic redacted inputs, including weekly primary, null windows,
  malformed/partial lines, scoped Claude windows, expiry, and stale readings.
- Run `make test`, `make build`, and touched-file formatting checks.
- Launch the built app for actual screenshots and interaction validation. Inspect
  focus, click-through, dwell/leave, pin, menu recovery, and movement where the
  current desktop allows. Record untested OS/display conditions explicitly.
- Review the complete diff and fix findings before the final implementation commit.

## Deferred scope

Live requests/Keychain, CC Switch history/account enumeration, persistent last-good
snapshot storage, Metal rendering, manifest skins and the sprite pet are later
slices. Full-screen Spaces, Stage Manager and physical multi-display behavior need
runtime coverage beyond an ordinary single-display desktop check.

## Current state

Planned. Implementation and validation results will be recorded here as they occur.

## Engine and passive-data checkpoint — 2026-11-03

Implemented pure timing and placement in
`Packages/TidemarkKit/Sources/TidemarkEngine/CompanionState.swift` and
`Packages/TidemarkKit/Sources/TidemarkEngine/DockPlacement.swift`. The host schedules
a monotonic deadline; menus (including nesting), pinning and dragging cancel or
suspend retraction. Display geometry subtracts shared seams and keeps corner
clearance; disconnected displays resolve against the first supplied display.

Implemented quota normalization, parsing and read-only bounded file access in
`Packages/TidemarkKit/Sources/TidemarkData/QuotaObservation.swift`,
`Packages/TidemarkKit/Sources/TidemarkData/PassiveQuotaParser.swift`, and
`Packages/TidemarkKit/Sources/TidemarkData/PassiveQuotaReader.swift`.
The reader selects one complete Claude capture rather than merging potentially
different accounts, and scans only the newest Codex rollout's bounded tail.
Duplicate Codex durations are collapsed; boolean percentages are rejected.
Stale/expired/future-dated readings produce no remaining percentage.

Validation at checkpoint `ef851da`: the first 9 Swift Testing tests passed (4
Engine, 5 Data). Two later reader fixtures failed compilation because
`FileManager.setAttributes` was called with `atPath:` instead of `ofItemAtPath:`.
The checkpoint was inadvertently committed with that typo and a premature claim
that 11 tests had passed; this paragraph corrects that claim. The initial engine
test compilation also required an explicit CoreGraphics import with member-import
visibility enabled. `make build` passed with the initial app wiring. No network or
credential access was introduced. Synthetic temporary files are used in tests;
the bounded-tail test compares the external file before and after reading.

The follow-up corrected the fixture label to `ofItemAtPath:` and reran `make test`
successfully: 11 tests passed (4 Engine, 7 Data), including both new reader tests.
