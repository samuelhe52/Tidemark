# 007.004 — Scroll gesture routing in the Request Logs table

## Context

[003](003-ui-and-model-names.md) fixed the header flashing by repositioning the sticky
header synchronously in `DashboardView`. 003 lists that fix under "Not verified yet":
no real-trackpad confirmation was recorded.

On 2026-11-03 the same Codex thread (`gpt-6.1-sol`, thread
`01a1a1f5-30a3-7651-a601-0424fe6f14ae`) audited the scroll path again and found a second,
independent defect. The facts below come from that thread's final report and the diff it
left in the working tree. The audit harness lived outside the repository and is not cited.

## Change

### Defect

`RequestLogHorizontalScrollView.scrollWheel(with:)` chose a recipient for each event
separately: vertical if `abs(scrollingDeltaY) > abs(scrollingDeltaX)`, otherwise the
inner (horizontal) scroll view.

A trackpad gesture is not only movement events. It also carries events whose deltas are
zero: the `mayBegin`/`began` start, and the end and momentum-end events. Those compared
as "not vertical" and went to the inner scroll view, while the movement between them
went to the dashboard scroll view. Neither view saw a complete gesture.

- **Observed (Codex harness, synthetic events):** the old handler delivered 2 of 6
  packets of a vertical gesture to the dashboard.
- **Inference, not observed on hardware:** a split gesture can leave the dashboard scroll
  view without its begin/end and momentum bookkeeping, and the inner scroll view with a
  stray start. This is a plausible contributor to the flashing and the missed momentum,
  but no one has confirmed it on a trackpad.

### Fix

The handler now decides once per gesture and routes every event of that gesture to the
same recipient:

- A plain mouse wheel (no `phase`, no `momentumPhase`) is routed per event, as before.
- `mayBegin` or `began` resets the decision.
- While no axis is decided, zero-delta events are held, not routed. A held `began` is
  stored as `pendingScrollStart`.
- The first event with movement fixes the axis for the gesture, then delivers the stored
  start to that recipient, then the event itself.
- The decision is kept through finger lift, because momentum arrives as separate events.
  It is cleared when the gesture is cancelled or the momentum ends.
- A held start is dropped if the gesture ends, is cancelled, or the momentum ends
  before any movement.

Instance state: `gestureIsVertical` and `pendingScrollStart` on
`RequestLogHorizontalScrollView`. Routing itself moved into `routeScrollWheel(_:vertically:)`.

### Rejected

None discussed. Routing by gesture was the only approach the thread tried.

## Validation

Reported by the Codex thread on 2026-11-03; I did not re-run these:

- Complete vertical gesture: old handler 2 of 6 packets to the dashboard, new handler 6 of 6.
- Horizontal gestures, cancelled gestures and plain mouse-wheel routing passed in the harness.
- The earlier sticky-header harness still reported zero misplaced headers (0 of 240
  programmatic positions, 0 of 160 synthetic wheel-plus-momentum samples, 0 of 9
  fractional and boundary positions).
- `make build` passed and the package tests passed (40 tests in the run it reported).

The thread noted why its earlier harness missed this: it measured header position during
supplied momentum packets, not delivery of the complete gesture lifecycle.

Runtime evidence:

- **Maintainer, 2026-11-04:** tested on a physical trackpad and reported that scrolling
  works now. The report did not break the result down further.

Not verified:

- Whether this change, the 003 synchronous repositioning, or both stop the flashing the
  maintainer saw. The trackpad test covered the combined state.
- No test covers this handler. It is AppKit event routing inside a view, and no
  existing package target can reach it.

## Current state

As of 2026-11-04 the change is implemented and confirmed working on a trackpad by the
maintainer.

## Refs

- `Sources/Tidemark/RequestLogView.swift`: `RequestLogHorizontalScrollView.scrollWheel(with:)`
  and `routeScrollWheel(_:vertically:)`.
