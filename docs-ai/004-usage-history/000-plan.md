# 004 — Usage history in the dashboard: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — runtime layout check pending; see [action record](001-action.md) |
| Anchor date | 2026-11-03 |
| Origin | Maintainer request on 2026-11-03: "implement the usage metrics section" |
| Related | [001 design contract §3.6–3.7](../001-companion-foundation/design.md), [003](../003-direct-multi-account-quota/000-plan.md) |

## Background

The PRD asks for "other relevant usage metrics" beside quota, and the design
contract (§3.6–3.7) specifies token and estimated-cost history from CC Switch's
`~/.cc-switch/cc-switch.db`. The dashboard shows quotas only; nothing reads the
database yet.

The database facts below come from CC Switch source at commit `c018907`
(`src-tauri/src/services/usage_stats.rs`, `services/sql_helpers.rs`,
`src/lib/usageRange.ts`) and the maintainer's local database, both inspected on
2026-11-03:

- `proxy_request_logs` holds detail rows (`data_source` is `proxy` or a session
  importer such as `session_log`, `codex_session`, `omp_session`, `pi_session`).
  Rows older than 30 days move into `usage_daily_rollups` (one row per local
  `date`, app, provider and model) and are deleted.
- `get_usage_summary_by_app` adds detail totals to rollup totals, takes rollup rows
  only for whole local days inside the range, removes session rows that duplicate
  a successful proxy row (`effective_usage_log_filter_for_range`), normalizes input
  with `fresh_input_sql`, and folds `claude-desktop` into `claude`.
- Range presets: `today` starts at local midnight; `7d`/`30d` start at local
  midnight N−1 calendar days ago; `all` starts at 0. Every range ends now.
- On the maintainer's database, an all-time by-app query took about 0.2 s and a
  30-day one about 0.03 s (sqlite3 CLI, on a copy).

## Goals

- A **Usage** section below the quotas: total tokens and API-equivalent cost for
  the chosen range, then one row per app (Claude, Codex, and any other CC Switch
  app with usage), labeled as an estimate rather than a bill.
- A compact range picker with `today`, `7d`, `30d` and `all`; the choice persists.
- Numbers match CC Switch's own dashboard for the same range.
- Missing or unreadable history is shown as such, never as zero.

### Non-goals (this slice)

- Provider and model filters, the `1d`/`custom` presets, and per-request logs. The
  by-app rows stand in for the app filter. The contract keeps them; they are
  deferred, not rejected. (Corrected 2026-11-03: `14d` and a chart were added in
  [002](002-views-and-14-day.md).)
- Feeding history into the orb, the summary line, or the last-good snapshot.

## Design / approach

**Data (`TidemarkData`)** — proposed `UsageHistory.swift`:

- `UsageHistoryRange` (`today`, `7d`, `30d`, `all`) resolves to a start and end
  `Date` with the CC Switch rules, using a caller-supplied `Calendar`.
- `UsageHistoryReader` opens the database with `SQLITE_OPEN_READONLY` and
  `mode=ro` (never `immutable`, which would ignore the WAL), with a short busy
  timeout, and runs one by-app query that reproduces `get_usage_summary_by_app`:
  the dedup filter, `fresh_input_sql`, rollup day bounds, and `claude-desktop` folding.
  It returns `UsageHistory` (range, per-app `UsageTotals`, the newest detail
  `created_at`) or a `UsageHistoryIssue` (`missing`, `unreadable`, `unrecognized`).
- It uses the system `SQLite3` module, with no new dependency. It reads no
  credentials and makes no network calls.

**App** — `CompanionController` reads history off the main actor whenever it
refreshes quotas (60 s timer, reveal, wake, the refresh button) and when the range
changes. It keeps the last good result for the current range, so a transient lock
shows the previous figures with an issue line. The range is stored in
UserDefaults. `DashboardView` adds the section as ordinary content rows, so it
reuses the per-row transitions and scrolling.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Reproduce CC Switch's SQL instead of a simpler sum | Summing detail rows alone loses everything older than 30 days; summing both sources without the dedup filter double-counts sessions seen by the proxy. Matching CC Switch also lets users compare the two dashboards. |
| Only the range-adaptive `rowid NOT IN` dedup form | CC Switch chooses between `EXISTS` and `rowid NOT IN` for speed; they are semantically identical. One form keeps less copied SQL. Like CC Switch, the filter is skipped when the window has no successful proxy rows or no session rows. |
| Separate reader, not part of `UsageService` | History has its own scope and no credentials or gates; a range change must not trigger live quota requests. |
| Re-query on each refresh rather than cache in Tidemark's store | The query is cheap and CC Switch owns the data; a second copy could drift. |
| By-app rows instead of an app filter | Uses the same number of rows as a filter, without making the user switch filters to compare apps. |

## Validation and acceptance criteria

- `TidemarkDataTests`: range resolution (including a midnight boundary) and a
  fixture database that exercises rollup day bounds, dedup of a session row,
  Codex fresh-input normalization, `claude-desktop` folding, and a missing file.
- `make build` succeeds.
- Runtime: the dashboard shows the section; per-app totals for `30d` match the
  sqlite3 reference query on the maintainer's database.

## Amendments

- Updated 2026-11-03: 14-day range and chart / by-harness / by-model views — see [002-views-and-14-day.md](002-views-and-14-day.md)

- Updated 2026-11-04: default All Time heat map and chart style preference in Settings — see [003-all-time-heatmap.md](003-all-time-heatmap.md)
