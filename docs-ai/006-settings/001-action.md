# 006 — Companion settings: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Created the authorized `.worktrees/settings` checkout on `feat/settings`, based on `b1b9835`; wrote the plan before implementation. | Maintainer's implementation request |
| 2026-11-03 | Added native settings, shared preferences, OS-service integration, configurable interaction, global account order, and quota presentation choices. | Files below; uncommitted |
| 2026-11-03 | Maintainer review: added a dashboard gear button (pinned-dashboard Command-comma was tried and dropped: the nonactivating panel would have to take and hand back key focus); removed the dashboard Live Usage footer and moved refresh age to the header; switched settings to toolbar tabs, fixed duplicated slider labels and tick marks, replaced arrow reordering with drag. Maintainer checked the settings window visually. | `DashboardView`, `CompanionPanel`, `CompanionController`, `SettingsView`, `SettingsStore` |
| 2026-11-03 | Added focused Engine/Data regressions; ran package tests, app builds, isolated preferences/presentation checks, and source review. | Validation below |

## Outcome and current state (as of 2026-11-03)

All eleven selected settings are implemented in source. A separate focusable macOS settings window uses system grouped forms and General, Companion, Usage, and Accounts tabs. The companion's native dashboard and nonactivating panel remain in place. The app has not been launched for this work.

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

None in product scope. Runtime and visual verification are intentionally deferred by the maintainer's explicit no-launch instruction. No commit or remote mutation was authorized or performed.

## Validation

- `make test`: passed, 43 Swift Testing tests (9 Engine, 34 Data), including nine new settings-related regressions.
- `make build`: passed after resolving an initial compiler failure caused by reading observable properties before all stored properties were initialized. Initialization now uses local normalized values.
- Isolated command-line checks compiled the actual app `SettingsStore.swift` and `QuotaText.swift` against the package libraries. Passed legacy-key loading, duplicate-order normalization, account discovery/reorder with absent slots, preferences reload, selected-account hiding, percentage/reset formatting, and synchronous preference-change callbacks. Used a unique UserDefaults suite and removed that suite afterward. This executable did not create an NSApplication or call login-item, hotkey, credential, or networking APIs.
- Source review caught and fixed a hotkey event-identity issue after a rejected replacement, and prevented Escape in the settings window from unpinning the background companion. These integration paths still require runtime validation.
- `swift format lint --strict` on all touched Swift files: passed after correcting documentation-comment spacing (including one pre-existing warning in the touched dashboard file). `git diff --check`: passed. The original main checkout remains clean.

## Open questions

- Native settings layout, keyboard focus/recording and delivery, shortcut conflict feedback, login-item approval/failure behavior, and live dashboard updates remain unverified at runtime.
- No app launch, visual check, login-item change, or actual global-hotkey registration was performed. Launch only after explicit maintainer authorization.
