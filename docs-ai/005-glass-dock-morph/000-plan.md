# 005 — Glass dock tab that morphs into the orb: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — runtime morph check pending |
| Anchor date | 2026-11-03 |
| Origin | Maintainer, 2026-11-03, with a screen recording of the hidden → revealed → expanded → hidden cycle: the resting view does not fit the glass design, the transition does not feel continuous ("a morphing effect would be very good"), and the resting view is hard to recognize. |
| Related | [001 design contract §1](../001-companion-foundation/design.md), [002 surface](../002-live-quota-native-surface/000-plan.md) |

## Background

The hidden state drew `EdgeGlowView`: a flat 4 × 44 pt accent pill at 80% opacity,
the only non-glass element of the surface. On reveal it faded out while a separate
orb faded in from half size, tucked toward the edge (`CompanionLayout.tuckOffset`).
Two different objects crossfading reads as a swap, not one object emerging, and a
4 pt flat line is easy to miss against a bright wallpaper or a window edge.

## Goals

- The resting view is Liquid Glass, like the orb, summary and dashboard.
- Reveal and retract are one continuous shape change: the same glass grows out of
  the edge into the sphere and melts back into it.
- The resting view is larger and tinted with the accent color, so it stays visible
  on light and dark backgrounds.
- Mid-flight reversals continue from the on-screen shape.

### Non-goals

- Merging the summary or dashboard glass with the orb (`NSGlassEffectContainerView`).
- Showing quota in the resting view.
- Changing hover, dwell, or click behavior.

## Design / approach

- `CompanionLayout.dock` (app target) replaces `glow`: a capsule of glass,
  16 × 48 pt, centered on the screen edge so 8 pt shows. The hover strip grows from
  8 × 64 to 10 × 64 pt to cover it. `tuckOffset` goes away.
- `OrbView` (`TidemarkAppearance`) gains `dockedFrame`, the glass's resting rect in
  its own coordinates (outside its bounds, against the edge), and
  `setDocked(_:curve:delay:completion:)`. Docking animates the body's frame with a
  spring; the glass keeps the orb's corner radius, which the system clamps into a
  capsule for the thin tab. An accent fill inside the glass fades in while docked;
  the sphere lighting fades out.
- `CompanionStageView` drops the glow. The orb is never hidden; each phase change
  docks or undocks it. Summary and dashboard keep their transform/opacity poses.
  The panel collapses to the strip only after both the morph and the other
  retracts finish.
- `EdgeGlowView` is deleted.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Animate the glass body's frame, not its layer transform | A non-uniform scale would stretch the sphere lighting and the glass rim instead of reshaping them. This is a scoped exception to the 002 "transform and opacity only" rule; it is confined to one view inside the orb and does not resize any window. |
| Spring through `NSAnimationContext.animate(_:changes:)` with a SwiftUI `Animation` | AppKit's implicit animations start from the model value, so a reversal would jump; Core Animation springs on the backing layer alone do not resize the glass's internal layers. A prototype on macOS 27.2 showed the SwiftUI-driven spring reshaping `NSGlassEffectView` continuously and retargeting mid-flight. `TidemarkAppearance` imports SwiftUI only for this timing type; the view tree stays AppKit. |
| Body frame in the orb's coordinates | The panel changes size between strip and full frame; coordinates local to the orb stay valid across that change, so an in-flight morph never jumps. |
| Tab half off-screen (8 pt visible) | Reads as a handle growing out of the edge, and the morph pulls the orb out of it. A fully on-screen floating capsule was the alternative; it reads as a detached control. |
| No glass container merge | The prototype showed that an `NSGlassEffectContainerView` ignores ancestor opacity, which would break the existing summary and dashboard fades. |
| Reduce Motion and Low Power Mode snap the shape | Matches the existing rule that those modes avoid motion; the other elements keep their short fades. |

## Validation and acceptance criteria

- `make build` succeeds.
- Runtime (maintainer): the resting tab is visible on light and dark wallpapers;
  reveal, retract and a quick in-out reversal morph without a jump on every edge;
  clicking the tab still pins; dragging the orb to another edge re-docks there.

## Amendments

- 2026-11-03, maintainer: the accent fill read as a blue chip covering the glass rather
  than tinted glass. `AccentFillView` is removed; the docked tab is untinted glass, the
  same material as the sphere, and only the sphere lighting fades out while docked. The
  goal of an accent-tinted resting view is withdrawn; visibility now rests on the glass
  adapting to the background. If it proves too subtle, the next step is a larger tab, not
  color.
