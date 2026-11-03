# 005 — Glass dock tab that morphs into the orb: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Plan written | `docs-ai/005-glass-dock-morph/000-plan.md` |
| 2026-11-03 | `EdgeGlowView` deleted, `OrbView` gains `setDocked`, `CompanionLayout.dock` added, `CompanionStageView` rewired | see key files below |

## Outcome and current state (as of 2026-11-03)

The resting state is now a 16 × 48 pt Liquid Glass capsule centered on the screen
edge (8 pt visible), in untinted glass (the accent fill was removed; see the plan's amendments). Reveal
morphs it into the 44 pt sphere; retract melts it back. `EdgeGlowView` is gone.

Key files:

- `Packages/TidemarkKit/Sources/TidemarkAppearance/OrbView.swift` — `OrbView`
  gains `docked`, `dockedFrame`, and `setDocked(_:curve:delay:completion:)`
  (the initial `AccentFillView` was removed; see the plan's amendments); idle
  breathing uses `bounds` center instead of body center.
- `Packages/TidemarkKit/Sources/TidemarkAppearance/GlassSurfaceView.swift` —
  fallback (`NSVisualEffectView`) mask now clamps to min half-dimension, matching
  the glass capsule clamp; mask only rebuilds when the radius changes.
- `Sources/Tidemark/CompanionLayout.swift` — `glow: CGRect` replaced by
  `dock: CGRect`; `tuckOffset` removed; strip widens to `dockDepth + 2`.
- `Sources/Tidemark/CompanionStageView.swift` — glow element and `Element.glow`
  case removed; orb stays in the view tree at all times; `show()` docks/undocks
  the orb and uses a two-counter settle gate so `completion` fires only after both
  the morph and the CA retract finish.
- `docs-ai/005-glass-dock-morph/000-plan.md` — this plan.

## Deviations from plan

- The `show()` settle gate counts to 2 only when docking state changes; unchanged
  docking calls `settle()` immediately, so there is no stray extra-call risk. This
  was not spelled out in the plan but follows directly from the design.
- `idleMotion = false` while docked was already implied by the plan ("breathing
  never runs while docked") but is explicit in the implementation by checking
  `!docked` before starting the breathing animation.

- Audit fix (2026-11-03): the first version never animated. Every spring step resizes the
  body, which marks `OrbView` for layout, and `layout()` re-applied the shape and fill
  unconditionally, so each step snapped to the end state. `layout()` now re-applies only
  when the target rect changes. The dock delay moved from `Animation.delay` into `OrbView`
  (`DispatchQueue` plus a generation): a delayed SwiftUI animation that replaces one in
  flight first jumps to the old target, which broke mid-flight reversals. Breathing is
  rebuilt only when the body changes size, not on every layout pass.

## Validation

- `make build` succeeded (6.9 s, no warnings).
- Runtime screenshot confirmed the dock tab renders at the left edge on launch.
- A standalone harness that drives the real `OrbView` sampled the body frame at 30 Hz:
  the reveal springs from the tab to the sphere with overshoot; a dock call with a 0.1 s
  delay made 0.14 s into the reveal turns it around without a jump; a snap in mid-flight
  holds; and the completion of a replaced call still fires.
- In-app reveal/retract on every edge and drag-to-another-edge are left for maintainer
  verification.

## Open questions

- Hover strip width of `dockDepth + 2 = 10 pt` may be tight; maintainer may want
  to widen it to 16 pt if activation feels hard to hit in practice.
