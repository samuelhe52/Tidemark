# 003.002 — Account visibility

## Context (2026-11-03)

The maintainer wants accounts such as a free account kept out of the usual
dashboard list. Folding an account's quota details would still leave it listed.

## Decisions

- Each account, including the only account of a service, can be hidden. A
  service-level “Show hidden accounts” menu restores one or all of them and stays
  available even when every account in the service is hidden.
- Hidden choices are stored in Tidemark's UserDefaults by `AccountUsage.id`, never
  by email, list position, plan, or upstream workspace alone. New accounts start
  visible; a temporary discovery failure does not erase hidden choices.
- Hiding filters only the dashboard. Discovery, refresh, credentials, snapshots and
  the active-account companion summary are unaffected, so the preference lives in
  the app target, not in Engine, Appearance or Data.
- Free plans are not hidden automatically: visibility is the user's explicit choice
  and must survive a plan change.
- Visibility changes animate per row (see the motion rules in
  [design.md](../001-companion-foundation/design.md)). A snapshot crossfade of the
  whole glass surface was tried and rejected because the dashboard visibly flashed.

## Outcome

Implemented in `Sources/Tidemark/DashboardView.swift`, with resize and transition
handling in `Sources/Tidemark/CompanionController.swift` and
`Sources/Tidemark/CompanionStageView.swift`. Hide, restore, all-hidden recovery and
persistence were exercised with synthetic accounts and isolated preferences, and a
hide/restore round trip ran in the real app.
