# 007.002 — Review fixes: refresh reconciliation, scroll anchoring, column widths, Settings reorder

## Context

A dual review of the uncommitted feature ran on 2026-11-03: two Codex reviewers and a
Codex debate thread. Claude Code checked each finding against the code. Nothing was
rejected. The maintainer asked for the two P1 findings to go to one new Codex thread
and two P3 findings to go to a second thread. The second thread ran after the first,
because both threads change `Sources/Tidemark/RequestLogView.swift`.

| Priority | Finding |
| --- | --- |
| P1 | A newer-rows refresh moved the dashboard down by 24 pt for each added row, even when the user was looking at the quotas above the logs. |
| P1 | The list never re-read rows it already loaded. Refresh fetched only rows newer than the top cursor, and paging only rows older than the bottom cursor. So three kinds of rows stayed wrong until a relaunch: a same-second row with a smaller `request_id`, a late-imported row inside the loaded span, and a session row that the duplicate filter later hid. The debate thread reproduced the first case with in-memory SQLite. The maintainer's database had 900 timestamps shared by two or more rows. |
| P3 | Turning a column on or off rebuilt every column at its default width. |
| P3 | The Settings column list used a different drop rule from the Accounts list. |

Two P3 findings were left as they are: the opaque background of the pinned header and
the cost of the duplicate filter. Both are open questions in the
[action record](001-action.md).

## Change

**First fix thread** (`gpt-6.1-sol`, high effort):

- `RequestLogReader.loadedSpan(through:)` re-reads every row from the newest row down
  to the bottom cursor, bottom included. It does this in one read transaction with the
  same duplicate filter. At refresh, `RequestLogView` replaces the loaded rows with that
  result and keeps the bottom paging cursor. New rows inside the span now appear,
  changed rows update, and rows the filter now hides disappear. Older rows still load
  in pages of 50.
- `RowScrollPreservation.adjustment` keeps a row that is still in the list at the same
  screen position when rows are added or removed. If the top of the viewport is above
  the log rows, the dashboard does not move.
- Cost, as the thread reported it: each refresh does O(n) client work and memory for n
  loaded rows. SQLite can scan past that span because of the sort and the duplicate
  filter. Nobody has measured it.
- **Placement:** the helper is in `TidemarkEngine`. It is pure geometry: no drawing, no
  data. CLAUDE.md lists that target as placement, docking, hover and pin state, and
  interaction timing, so the maintainer has not yet confirmed that the helper fits.

**Second fix thread** (`gpt-6.1-sol`, high effort):

- `RequestLogView.updateColumns()` keeps the current width of each visible column, by
  identifier, when it rebuilds the columns. A newly shown column gets the default
  width. Widths do not persist after a relaunch.
- `RequestLogSettingsView` now reorders like `AccountsSettingsView`: it highlights the
  drop target and uses a destination index from before removal.
  `RequestLogColumns.move(_:to:)` uses the same index rule. Move Up, Move Down and
  Reset to Default stay.

## Refs

- `Packages/TidemarkKit/Sources/TidemarkData/RequestLog.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/RequestLogColumns.swift`
- `Packages/TidemarkKit/Sources/TidemarkEngine/RowScrollPreservation.swift`
- `Sources/Tidemark/RequestLogView.swift`
- `Sources/Tidemark/SettingsView.swift`
- Tests:
  - `Packages/TidemarkKit/Tests/TidemarkDataTests/RequestLogTests.swift`: the two
    existing tests now also cover timestamp ties, late imports, changed values, rows
    the filter removes, spans larger than 50 rows, and the move directions.
  - `Packages/TidemarkKit/Tests/TidemarkEngineTests/RowScrollPreservationTests.swift`:
    `refreshKeepsContentAboveRowsStill` and
    `anchorsByIdentityAcrossInsertionsRemovalsAndReplacement`.
- Validation run by Claude Code on 2026-11-03, after both fix threads finished:
  - `make build` passed.
  - `make test` passed 38 tests in the TidemarkData run and 8 in the TidemarkEngine run.
  - Neither fix has been checked in the running app.
- Codex threads:

  | Role | Thread |
  | --- | --- |
  | Reviewer A | `01a1a1bd-0621-7f51-af54-6a5d276ba443` |
  | Reviewer B | `01a1a1bd-0ed0-7443-b781-fa0a6a390c5e` |
  | Debate | `01a1a1bd-121b-7cb3-a948-47e51b935522` |
  | P1 fixes | `01a1a1c4-0463-78e2-9f00-1970ab3b3321` |
  | P3 fixes | `01a1a1c8-3173-7483-9515-595b2cac3dc5` |
