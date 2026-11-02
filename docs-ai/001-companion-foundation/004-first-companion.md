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
