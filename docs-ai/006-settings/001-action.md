# 006 — Companion settings: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Wrote the plan before implementation. | Maintainer's implementation request |
| 2026-11-03 | Added native settings, shared preferences, OS-service integration, configurable interaction, global account order, and quota presentation choices. | Files below |
| 2026-11-03 | Maintainer review: added a dashboard gear button (pinned-dashboard Command-comma was tried and dropped: the nonactivating panel would have to take and hand back key focus); removed the dashboard Live Usage footer and moved refresh age to the header; switched settings to toolbar tabs, fixed duplicated slider labels and tick marks, replaced arrow reordering with drag. Maintainer checked the settings window visually. | `DashboardView`, `CompanionController`, `SettingsView`, `SettingsStore` |
| 2026-11-03 | Added focused Engine/Data regressions; ran package tests, app builds, isolated preferences/presentation checks, and source review. | Validation below |

## Outcome and current state (as of 2026-11-03)

All eleven selected settings are implemented in source. A separate focusable macOS settings window has General, Companion, Usage, and Accounts toolbar panes of system grouped forms. The companion's native dashboard and nonactivating panel remain in place. The maintainer has checked the settings window visually; the other runtime behavior is unverified.

Key files:

- `Sources/Tidemark/SettingsView.swift`: settings window, native controls, login-item status/error handling, shortcut recorder, account visibility/order controls.
- `Sources/Tidemark/SettingsStore.swift`: shared observable preferences, existing-key migration, saved account ordering and summary choice.
- `Sources/Tidemark/GlobalShortcut.swift`: optional system global hotkey; record/cancel/clear, failure feedback, registration lifecycle.
- `Sources/Tidemark/TidemarkApp.swift`: menu and Command-comma entry points, shared preferences and shortcut lifetime.
- `Sources/Tidemark/CompanionController.swift`: immediate settings application, shortcut show/hide, timer updates, unchanged history persistence.
- `Packages/TidemarkKit/Sources/TidemarkEngine/CompanionBehavior.swift` and `CompanionState.swift`: click-only activation, bounded delays, rescheduling, dismissal and reset behavior.
- `Packages/TidemarkKit/Sources/TidemarkData/QuotaDisplayPreferences.swift`: global account ordering, visibility, summary selection, and percentage conversion without UI imports.
- `Sources/Tidemark/DashboardView.swift`, `QuotaRingView.swift`, and `QuotaText.swift`: unique provider-run identities for interleaved account order; consistent percentage and reset-time presentation; unknown readings remain unknown.
- `Packages/TidemarkKit/Tests/TidemarkEngineTests/CompanionStateTests.swift` and `Packages/TidemarkKit/Tests/TidemarkDataTests/QuotaDisplayPreferencesTests.swift`: focused behavioral regressions.

The user defaults retain existing `liveUsageEnabled` and `hiddenDashboardAccountIDs` choices. History range/view and dock placement keep their existing automatic persistence. Newly discovered accounts append to the order; absent accounts' slots remain saved. Hiding a selected compact-summary account returns selection to Automatic.

## Deviations from plan

The maintainer review changed the entry points, the dashboard footer, the settings layout, and account reordering; see the plan's amendment.

## Validation

- `make test`: passed, 39 Swift Testing tests (5 Engine, 34 Data), including nine settings-related regressions.
- `make build`: passed.
- `swift format lint --strict` on the touched Swift files and `git diff --check`: passed.
- Escape in the settings window no longer unpins the background companion.
- The maintainer checked the settings window visually. Other runtime behavior is unverified.

## Open questions

- Keyboard focus, shortcut recording and delivery, shortcut conflict feedback, login-item approval and failure behavior, the timing settings, and live dashboard updates remain unverified at runtime.
