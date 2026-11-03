# 006 — Companion settings: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — runtime verification pending |
| Anchor date | 2026-11-03 |
| Origin | Maintainer selected eleven settings. |
| Related | [Foundation](../001-companion-foundation/000-plan.md), [live quota](../002-live-quota-native-surface/000-plan.md), [account visibility](../003-direct-multi-account-quota/002-account-visibility.md) |

## Background

The menu and dashboard expose a few independent preferences. Users need one native settings window for login, a global shortcut, hover behavior and timing, position recovery, Live Usage, account visibility/order, compact-summary account, percentage style, and reset-time style.

## Goals

- Implement exactly the agreed settings with persistent changes applied immediately.
- Preserve the native dashboard's system typography, controls, materials, and account identity.
- Carry existing Live Usage and hidden-account preferences forward; continue remembering history choices and dock placement automatically.
- Support account ordering across providers, retaining absent accounts' saved positions. Newly discovered accounts follow known accounts.
- Keep stale, expired, future-dated, and absent quota readings unknown in both percentage styles.

### Non-goals

Additional appearance controls, notifications, refresh frequency, skins, and other previously omitted settings.

## Design / approach

- App files: `SettingsStore.swift`, `SettingsView.swift`, and `GlobalShortcut.swift`. One shared observable preferences store connects native settings, menu actions, dashboard controls, and companion rendering.
- A regular, focusable settings window hosts toolbar panes of system grouped forms. The companion remains nonactivating. Settings opens from the menu, from the dashboard's gear button, and with Command-comma while Tidemark is active.
- Use ServiceManagement's main-app login registration and reflect its actual status, including failures and approval requirements. Do not register during initialization.
- Use the system global-hotkey API with a shortcut recorder, clear/cancel support, and registration-error feedback. Registration happens only in the running app, not during validation.
- `CompanionBehavior` in Engine controls hover expansion and bounded timing. Click-only keeps the docked glass tab until clicked. Pin, drag, menu, and leave protections remain intact.
- `QuotaDisplayPreferences` in Data normalizes account visibility/order/summary selection and percentage conversion without UI dependencies. Dashboard section identifiers remain unique even when users interleave providers.
- Keep account hiding available inline, synchronized with settings. Summary selection offers Automatic (current behavior over visible accounts) or one visible account. Hiding the selected account returns to Automatic; a temporarily absent selected account shows unknown.
- Quota gauges, labels, tooltips, accessibility descriptions, and compact summary consistently use remaining/used. Clock time includes the date for resets on later days.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Native grouped settings form | Matches the existing native UI language without introducing custom skin controls. |
| Separate Engine behavior and Data display preferences | Preserves module boundaries; the app owns persistence and OS services. |
| Global order with repeated service headings when interleaved | Honors exact account order instead of silently constraining order to provider groups. |
| Automatic defaults and explicit shortcut recording | Preserves current hover/timing/display behavior and avoids reserving an unsolicited shortcut. |

## Validation and acceptance criteria

- Focused Engine tests cover click-only, custom timing, settings changes during deadlines, and pin/menu/drag safeguards.
- Data tests cover visibility, interleaved ordering, discovery/removal, summary selection, unknown readings, and an isolated app-store preference round trip in both styles.
- Run `make test`, `make build`, touched-file formatting/lint, and `git diff --check`.
- Review integration source for preference synchronization and OS-service failure handling.
- Runtime: the settings window renders correctly; login registration, global shortcut delivery, and the timing settings behave as specified in the running app.

## Amendments

- 2026-11-03, maintainer review: the dashboard gains a gear button that opens settings. Command-comma from the pinned dashboard was tried and dropped, because the nonactivating panel would have to take key focus and hand it back. The dashboard's Live Usage footer is removed, and its refresh age moves to the header. Settings uses toolbar panes, and accounts are reordered by dragging instead of with arrow buttons. The design approach above is corrected to match.
