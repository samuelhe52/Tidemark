# 007 — Request logs in the dashboard: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — runtime check partly pending; see [action record](001-action.md) |
| Anchor date | 2026-11-03 |
| Origin | Maintainer request on 2026-11-03: "request logs in the dashboard on scrolling down (lazy, off-screen by default)". The design was agreed in an interactive HTML plan and the maintainer's answers to it, before implementation. This file was written after implementation from that plan and those answers, because the first version of this record was discarded. |
| Related | [004 usage history](../004-usage-history/000-plan.md), [006 settings](../006-settings/000-plan.md) |

## Background

The dashboard shows quotas and aggregated usage history ([004](../004-usage-history/000-plan.md)).
004 deferred per-request logs. The maintainer asked for a request-log table modeled on
CC Switch's Usage → Request Logs table:

> metrics: reference cc switch. we can make the shown metrics configurable too. It
> should be horizontally scrollable to show the rest of the table if there are too
> many metrics. Users need to be able to reorder columns.

CC Switch stores one row per request in `proxy_request_logs` in `~/.cc-switch/cc-switch.db`.
The row has tokens, cost, `latency_ms`, `first_token_ms`, `status_code`, `provider_id`
and `data_source`. Provider display names come from the `providers` table, keyed by
`(id, app_type)`. These facts come from the maintainer's local database, inspected on
2026-11-03.

## Goals

- A **Request Logs** section of its own below Usage. It is not a subsection of Usage.
- **Off-screen by default:** the section is left out of the dashboard's preferred
  height, so the panel never grows to show it. The user scrolls down to reach it.
- **Lazy:** no database read until the section scrolls into view. After that, rows load
  in 50-row pages. A refresh re-reads the loaded rows, so new, changed and hidden rows
  are correct (corrected 2026-11-03; the first version fetched only newer rows).
- **Rows:** every detail row, newest first. The Usage range does not filter the list,
  and the header has no request count. CC Switch's cross-source duplicate filter stays.
- **Metrics follow CC Switch's implementation:** the column set, formulas and formats
  come from its source, not from screenshots.
- **Configurable columns:** Time is fixed first. Every other column can be turned on or
  off and reordered. The default visible set is App, Model, Speed, First token and
  Total Time. "Reset to Default" restores it. The choice persists.
- **Horizontal scrolling** inside the 340 pt panel, with a **sticky** column header.

### Non-goals

- Providers and Models tabs, a Status Code filter, and a per-request detail view.
- Rows older than CC Switch's detail retention. Only daily rollups exist for them.
- CC Switch's list-time cost backfill. That backfill writes to the database, and
  Tidemark reads it read-only.

## Design / approach

**Data (`TidemarkData`)**

- `RequestLogReader.page(after:newerThan:limit:)` reads one page in a keyset order
  `(created_at DESC, request_id DESC)`. It applies `UsageHistoryReader.dedupFilter`
  over the whole time domain and joins `providers` for display names.
- `RequestLogEntry` carries raw values. Missing values stay `nil`, and the app shows
  them as "—", never as zero.
- `RequestLogColumns` holds the order and hidden set of `RequestLogColumn`. It drops
  unknown stored IDs and puts new cases at their default position. This follows the
  precedent of `QuotaDisplayPreferences`.
- The read-only SQLite opener moves out of `UsageHistoryReader.read` into
  `ReadOnlyDatabase.open`, so both readers open the database the same way
  (`SQLITE_OPEN_READONLY`, `mode=ro`).

**App**

- `RequestLogView` is a persistent dashboard row. The view survives
  `DashboardView.update`, so its rows and scroll positions survive refreshes. It
  watches the outer viewport and loads when it intersects the viewport.
- An `NSTableView` with `allowsColumnReordering` sits in a scroll view that scrolls
  horizontally only. The dashboard scroll view does all vertical scrolling.
- The column button and a right-click on the header open one checkmark menu with
  "Reset to Default". A Request Logs tab in Settings lists the columns with toggles
  and drag reorder.
- `RequestLogText` holds the CC Switch formulas and formats.
- `SettingsStore.requestLogColumns` persists the choice in UserDefaults.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Keep the panel 340 pt and scroll the table horizontally | The maintainer chose this over a 560 pt panel while the logs show, and over a separate window. A wider panel would affect placement and the content transitions, which use `DashboardView.width`. |
| List all detail rows, not the Usage range | Maintainer decision. Proposed default was the Usage range with a matching count. |
| Keep CC Switch's duplicate filter | Maintainer decision after the implementing agent first read "all detail rows" as "no duplicate filter". "All" means no range filter. Without the filter, a request imported from session logs can show twice. |
| Reorder by header drag and in Settings | Maintainer decision. Proposed default was header drag only. |
| Default columns App, Model, Speed, First token, Total Time | The maintainer's plan comment. It overrides the "compact" option the maintainer kept in the same response, because the comment is more specific. |
| Sticky header | Maintainer comment on the plan's risk that the header scrolls away. |
| Formulas from CC Switch source | Maintainer comment. The plan had inferred Speed from screenshots. The source shows two different rules: one for proxy rows and one for session rows. |
| Leave out cost backfill | CLAUDE.md allows writes to other tools' stores only for the CC Switch managed Codex OAuth flow. Costs can differ from CC Switch until CC Switch backfills them. |

## Validation and acceptance criteria

- `TidemarkDataTests`: column-preference decoding, move and reset. A fixture database
  page read that covers cursor paging, timestamp ties, newer rows, provider names, the
  session placeholder, the duplicate filter, and an unchanged fixture after reads.
- `make build` and `make test` pass.
- Runtime: the logs start below the fold, load only on scroll, page, and keep the
  header pinned. The column menu, header drag, Settings reorder, persistence after a
  relaunch, and horizontal swipes work.

## Amendments

- Updated 2026-11-03: dual-review fixes for refresh reconciliation, scroll anchoring, column widths and Settings reorder — see [002-review-fixes.md](002-review-fixes.md)
- Updated 2026-11-03: table UI, CC Switch model display names, TTFT, short Claude names, panel height and the sticky-header redesign and flashing fix — see [003-ui-and-model-names.md](003-ui-and-model-names.md)
- Updated 2026-11-04: trackpad scroll gestures in the Request Logs table are routed as a whole, with a correction to the 001 routing line and the 003 flashing account — see [004-gesture-routing.md](004-gesture-routing.md)
