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

Implemented as the first vertical slice. Entry 001 remains In progress for the
remaining contract; this amendment is the slice record, and its aggregate
`001-action.md` will be written when the final foundation slice lands.

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


## Native UI outcome — 2026-11-03

The app owns a borderless, nonactivating `NSPanel`, global/local pointer monitoring,
native strip tracking, deadline scheduling, a 250 ms revealed-pointer reconciliation
timer, and coalesced local reads at launch, reveal, wake and every 60 seconds.
Placement is stored only in Tidemark's own UserDefaults. Sleep and screen-lock
notifications remove the visible presentation. Orb drawing stays in Appearance;
the shared dashboard stays in the app target.

Key files:

- `Sources/Tidemark/CompanionController.swift`: host effects and source refresh.
- `Sources/Tidemark/CompanionPanel.swift`: nonactivation and native input handling.
- `Sources/Tidemark/CompanionLayout.swift`: panel, circle, strip and travel corridor.
- `Sources/Tidemark/CompanionRootView.swift`: presentation and accessible pin action.
- `Sources/Tidemark/QuotaDashboard.swift`: dated quota rows and local reset countdowns.
- `Packages/TidemarkKit/Sources/TidemarkAppearance/OrbView.swift`: provisional
  native orb, 30 Hz idle animation, paused for Reduce Motion or Low Power Mode.

### Review and validation

| Check | Observed result |
| --- | --- |
| `make test` | Final run passed 11 Swift Testing tests: 4 Engine and 7 Data. Newest-capture isolation, bounded tails, malformed values, nested menus and seam fallback are included. |
| `make build`, `make run` | Passed on macOS 27.2, Apple Silicon, including the final UI revision. Launch printed Xcode's multiple-matching-destination warning (arm64/x86_64); the build succeeded. |
| Touched-file `swift format lint`, `git diff --check` | Passed after fixing three documentation-comment lint warnings. No repository-wide formatting was run. |
| Source inspection | Module imports preserve the three package boundaries. File handles are read-only; no network client, credential refresh, configuration writes or statusline installation was introduced. |
| Real passive sources | Claude Code 2.1.316 and codex-cli 0.166.0, inspected 2026-11-03. Claude cache field types matched the parser; no account identifiers or credential values were printed. The dashboard showed expired/stale Claude observations as unknown and a current weekly Codex window with a dated remaining percentage. |
| Native window and screenshots | Observed an 8 × 64 point hidden window with a 4 × 44 point glow, then the orb and dashboard. Enlarged the dashboard to 440 points high (clamped to the visible display), retained scrolling for additional windows, and made scroll indicators visible. |
| Input and recovery | Direct edge click opened and pinned. Refresh kept the pin. Orb click and the accessible Unpin action removed it; leave grace then returned to the strip. Show Companion and Reset Position worked through the app menu. |
| Nonactivation | Restored Prowl as the foreground app, then separately opened via edge click and pressed Refresh. Frontmost-app probes after each still returned Prowl. The screenshot helper's `--app` mode explicitly activates Tidemark, so that helper's foreground state was excluded from this check. |
| Visual regression | Whole-root sizing animation produced a screenshot with clipped text. Hidden strip and visible content now have separate view branches; animation is scoped to the visible content's stable frame. Repeated final reveal/reset screenshots showed readable text. This is an observed repair, not a claim about SwiftUI internals. |

The manual code review also fixed duplicate-duration Codex row identity, rejected
boolean percentages and overflowing duration/reset numbers, suspended leave timing
for nested menus, and stopped trusting future capture times. Native click/drag
handling uses event coordinates, rather than a later sample of the global pointer.
The hidden window occupies only the strip and receives its own tracking events.

### Validation limits and deviations

- Desktop automation did not establish a sustained native hover or complete a drag:
  coordinate drag attempts returned `windowNotFoundAtPosition` with click-through
  enabled. Hover/dwell cancellation, drag/pin restoration, seams and display
  fallback are unit-tested; drag persistence is implemented but not runtime-proven.
- Fast cross-and-click through transparent regions, full-screen Spaces, Stage
  Manager, physical multi-display/replug, notch/Dock variants, sleep/lock, Reduce
  Motion and Low Power Mode need additional runtime coverage. Native panel flags
  and source wiring do not substitute for those checks.
- Global Escape relies on existing macOS event-monitoring permission; Tidemark
  does not request permission. Orb click and its accessibility action always
  provide the unpin path. Global Escape was not separately validated.
- The renderer is SwiftUI, not the planned Metal orb. Hidden/revealed window
  resizing is immediate; the visible dashboard uses scoped transitions. Final
  emergence/retraction motion and the full render-budget contract remain later
  appearance work.
- Live quota requests, CC Switch history, managed accounts, durable last-good
  snapshot storage, behavior presets and manifest/sprite skins remain deferred.
  The menu-bar item is retained for recovery; its final product status and final
  orb art direction remain open.

### Commit references

- `9ea2b29`: implementation plan before code.
- `ef851da`: engine, passive sources and test checkpoint.
- `5786042`: fixture correction and truthful validation record.
- Native UI, final parser hardening, public README updates and this completed slice
  record are committed together in the implementation commit containing this file.
