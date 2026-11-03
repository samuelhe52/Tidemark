# 006.002 — Per-service compact summary and working drag reordering

## Context

Maintainer review of the Accounts pane on 2026-11-03 found two problems:

- Dragging accounts to reorder did nothing. The rows used `ForEach.onMove` inside the pane's grouped `Form`, and each row was a checkbox `Toggle` whose label (email and service) covered most of the row, so mouse-down on the text went to the checkbox. The drag-handle image had no behavior. That `onMove` does not start drags inside a macOS grouped `Form` is an inference from the observed symptom; it was not isolated.
- The compact-summary picker was confusing. Automatic showed one account per service (two by default), but choosing any account showed only that account, silently removing the other service. One control decided both which services appear and which account represents each.

## Change

- The compact summary is chosen per service. `QuotaDisplayPreferences.summaryChoices` maps a `QuotaService` to `QuotaSummaryChoice` (`automatic`, `account(id)`, `off`); a missing entry is Automatic. Choosing an account replaces only that service's entry. Off removes the service from the summary.
- `summaryAccounts(in:)` now returns one `QuotaSummaryEntry` per shown service, in the order services first appear among visible accounts. An explicit selection that is absent keeps its entry with no account, so the summary shows that service as unknown (`Codex —`) instead of substituting another account; a service with no visible account is appended after the others.
- Hiding the selected account resets only that service to Automatic.
- Settings shows one picker per service that has accounts. The old `summaryAccountID` default is removed on launch rather than migrated: it was same-day, unreleased state, and its service is unknown until usage loads.
- Account rows are drag sources (`draggable` with the account ID) and drop targets (`dropDestination`); dropping onto a row moves the dragged account to that row's position. The checkbox is a bare box with an accessibility label, so the email and service text can start a drag. Context-menu and accessibility move actions are unchanged.

Rejected: keeping a single picker with clearer labels (still couples service count to account choice); moving the account rows into a `List` (would leave the grouped-form styling of the pane, and nesting a `List` in a `Form` sizes poorly).

## Refs

- `Packages/TidemarkKit/Sources/TidemarkData/QuotaDisplayPreferences.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/QuotaDisplayPreferencesTests.swift`
- `Sources/Tidemark/SettingsStore.swift`, `Sources/Tidemark/SettingsView.swift`, `Sources/Tidemark/QuotaText.swift`
- [Design contract](../001-companion-foundation/design.md)
