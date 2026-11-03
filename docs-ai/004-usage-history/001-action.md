# 004 — Usage history in the dashboard: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Plan written; reader, tests, and dashboard section implemented | uncommitted |

## Outcome and current state (as of 2026-11-03)

- `UsageHistoryReader` opens `~/.cc-switch/cc-switch.db` with `SQLITE_OPEN_READONLY`
  and `mode=ro` and runs a single by-app query. The query reproduces CC Switch's
  `get_usage_summary_by_app`: the range-adaptive session/proxy dedup (only the
  `rowid NOT IN` form), `fresh_input_sql`, rollup rows only for whole local days, and
  `claude-desktop` folded into `claude`. It also reads the newest detail `created_at`.
  Missing, unreadable and unrecognized databases are reported as distinct issues.
- `UsageHistoryRange` covers `today`, `7d`, `30d` and `all`, with CC Switch's
  calendar-day starts.
- The dashboard adds a **Usage** section below the quotas. It shows a range
  pop-up, total tokens with the API-equivalent cost labeled as an estimate, the age
  of the last recorded request, and one row per app with tokens, cost and a share
  bar. A tooltip and the accessibility label give the input, output, cache-write,
  cache-read and request breakdown.
- `CompanionController` reads history off the main actor on every quota refresh
  trigger and on range changes, coalescing overlapping reads. On a failed read it
  keeps the last good figures for the same range and shows the issue. The range
  persists in UserDefaults as `usageHistoryRange`; the default is `today`.

Key files:

- `Packages/TidemarkKit/Sources/TidemarkData/UsageHistory.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageHistoryTests.swift`
- `Sources/Tidemark/HistoryText.swift`
- `Sources/Tidemark/DashboardView.swift`
- `Sources/Tidemark/CompanionController.swift`

## Deviations from plan

- A per-app share bar was added beside each app's figures; the plan did not name it.
- The design contract says "clicking the estimate changes its scope". This
  implementation uses a range pop-up in the section header instead, which is easier
  to discover.

## Validation

- `make test`: 4 engine and 30 data tests pass, including the 2 new
  `UsageHistoryTests` (range and rollup-day bounds; a fixture database covering
  rollups in and out of range, session dedup, Codex fresh input, `claude-desktop`
  folding, and a missing database).
- `make build` succeeds.
- A scratch driver compiled with the reader ran against a copy of the maintainer's
  database. Its `30d` and `all` per-app requests, cost and four token kinds matched
  the hand-written sqlite3 reference query exactly. Read times were 0.01–0.13 s per
  range.
- Not done: viewing the dashboard section in the running app. The session had no
  screen-recording or accessibility access, so the layout, the pop-up inside the
  non-activating panel, and the row transitions are unverified at runtime.

## Open questions

- Whether the totals match CC Switch's own dashboard was checked only against a
  reimplemented query, not against the CC Switch UI.
- The dedup filter is skipped on the maintainer's database (it has no proxy rows),
  so only the fixture exercises it.
