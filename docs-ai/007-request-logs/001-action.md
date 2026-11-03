# 007 — Request logs in the dashboard: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | The maintainer answered the interactive HTML plan: all detail rows, reorder in headers and Settings, 340 pt panel, sticky header, CC Switch source as reference, default columns App, Model, Speed, First token, Total Time. | — |
| 2026-11-03 | An OpenAI Codex agent (`gpt-6.1-sol`, high effort) implemented the feature from that brief. During the turn, the maintainer told it to keep CC Switch's duplicate filter. | Feature commit |
| 2026-11-03 | Claude Code discarded the agent's `docs-ai/007` records and wrote this record and the plan. | Feature commit |
| 2026-11-03 | Dual review; two Codex fix threads fixed two P1 and two P3 findings. See [002](002-review-fixes.md). | Feature commit |
| 2026-11-03 | Table UI, model display names, TTFT, short Claude names, height fix, sticky-header redesign and flashing fix. See [003](003-ui-and-model-names.md). | Feature commit |

## Outcome and current state (as of 2026-11-03)


- **Section and height:** `DashboardView` appends a separator and a persistent
  `RequestLogView` row after Usage. `preferredSize(maxHeight:)` subtracts the logs row
  and its separator from the content height, so the panel stops at the end of Usage.
- **Lazy loading:** `RequestLogView` owns a `RequestLogReader` and reads off the main
  actor. The controller does not do this read, which differs from Usage history. A read
  starts when the outer viewport reaches the section. After that, rows load in 50-row
  pages, and the next page starts near the end of the loaded rows. A dashboard update
  with a new `refreshedAt` re-reads the whole loaded span with
  `RequestLogReader.loadedSpan(through:)` and replaces the rows.
  `RowScrollPreservation` keeps the visible rows in place (corrected 2026-11-03; see
  [002](002-review-fixes.md)). If a read fails, the loaded rows stay and a Retry button
  shows.
- **Query:** `RequestLogReader.page(after:newerThan:limit:)` and `loadedSpan(through:)` order by
  `(created_at DESC, request_id DESC)`. It applies `UsageHistoryReader.dedupFilter`
  over the whole time domain and left-joins `providers` on `(provider_id, app_type)`.
  An unjoined provider ID that starts with `_` and ends with `session` shows as
  "Session logs". Other unjoined IDs show the raw ID.
- **Columns:** `RequestLogColumns` normalizes stored IDs, removes duplicates, adds new
  cases at their default position, and supports `setVisible`, `move` and `reset`. Time
  is not a case and stays first. `SettingsStore.requestLogColumns` persists the order
  and the hidden set under `DefaultsKey.requestLogColumnOrder` and
  `DefaultsKey.requestLogHiddenColumns`.
- **Column UI:** the section button and a right-click on the header use one menu
  builder. Header drag reorders columns, but a drag cannot move Time or put a column
  before it. Columns fit their content, and the user cannot resize them (corrected
  2026-11-03; see [003](003-ui-and-model-names.md)). The Settings tab
  "Request Logs" (`RequestLogSettingsView`) has a toggle per column, drag reorder that
  works like the Accounts list, and "Reset to Default".
- **Sticky header** (redesigned 2026-11-03; see [003](003-ui-and-model-names.md)):
  - The native header sits in the inner scroll view's own header slot, and the rows
    start below it.
  - While the user scrolls, the inner scroll view's frame top follows the pinned
    position. A locked vertical clip offset of the same distance keeps the rows in place.
  - The dashboard repositions it synchronously in its bounds-change handler, with
    responsive scrolling turned off.
  - Mostly vertical wheel events go to the dashboard scroll view. (Corrected 2026-11-04:
    a trackpad gesture is routed as a whole, from its first event with movement through
    its momentum; only plain mouse-wheel events are routed one by one. See
    [004](004-gesture-routing.md).)
- **Shared opener:** `ReadOnlyDatabase.open` replaces the inline opener in
  `UsageHistoryReader.read`.

### CC Switch semantics

These rules come from CC Switch commit `c0189078aacdd80fd2462f59b345f55f62b41cf2`,
inspected on 2026-11-03. The implementing agent read the sources. Claude Code checked
the Speed rules and the Hit Rate truncation against `format.ts` and
`RequestLogTable.tsx` at that commit. The other rules are as the agent reported them.

| Metric | Rule | Source |
| --- | --- | --- |
| Fresh Input | For `codex`, `gemini` and `grokbuild`, input − cache reads when input ≥ cache reads; else input. | `src/types/usage.ts` `getFreshInputTokens` |
| Cache Hit | Positive cache reads, else "—". | `RequestLogTable.tsx` |
| Cache Write | Positive cache writes. "—" for cache-inclusive apps, whose writes are unknown. | `RequestLogTable.tsx` |
| Hit Rate | read ÷ (fresh + read + write), truncated to one decimal. "—" when the total is 0. Verified. | `RequestLogTable.tsx` `getRequestCacheHitRate` |
| Speed, proxy rows | output ÷ ((latency − first token) / 1000). Needs ≥ 100 output tokens and ≥ 100 ms of generation. Verified. | `src/components/usage/format.ts` |
| Speed, session rows | output ÷ (latency / 1000), shown with "≈". Needs ≥ 200 output tokens and ≥ 1000 ms. Verified. | `format.ts` |
| First token, Total Time | Seconds to one decimal. Session rows use "≈". | `RequestLogTable.tsx` |
| Tokens | Grouped integers below 10,000; K/M/B with three significant figures above. | `format.ts` |
| Cost | USD, four decimals. A successful row with tokens, zero cost and a nonzero multiplier shows "Unpriced". | `RequestLogTable.tsx`, `usage.ts` |
| Time | `HH:mm:ss` today, `MM-dd HH:mm` on earlier days, with the full date as a tooltip. | `RequestLogTable.tsx` |
| Provider | `providers` join first. "Session logs" for unjoined `_…session` IDs, by maintainer request. | `providerLabel.ts` |

CC Switch's list also runs `maybe_backfill_log_costs`, which writes to the database.
Tidemark leaves it out (see the plan). Tidemark also ignores CC Switch's currency
setting.

Key files:

- `Packages/TidemarkKit/Sources/TidemarkData/RequestLog.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/RequestLogColumns.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageHistory.swift`
- `Packages/TidemarkKit/Sources/TidemarkEngine/RowScrollPreservation.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/RequestLogTests.swift`
- `Sources/Tidemark/RequestLogView.swift`
- `Sources/Tidemark/RequestLogText.swift`
- `Sources/Tidemark/DashboardView.swift`
- `Sources/Tidemark/SettingsStore.swift`
- `Sources/Tidemark/SettingsView.swift`
- `Sources/Tidemark/DefaultsKey.swift`

## Deviations from plan

- The HTML plan put the page loads in `CompanionController`. The reader lives in
  `RequestLogView` instead, and the dashboard triggers refreshes from `refreshedAt`.
- The HTML plan inferred one Speed rule from screenshots. The implementation uses CC
  Switch's two rules (see the table).
- `RequestLogEntry` keeps raw optional values (`latencyMS`, `firstTokenMS`, `status`
  and others) and a `RequestLogCursor`. The sketched schema was different.
- The list projects the raw `model`, as CC Switch's list does. Usage groups by the
  pricing model when one is set.

## Validation

Run by Claude Code on 2026-11-03:

- `make build`: passed.
- `make test`: 38 tests in 6 suites passed. These include
  `preferencesMigrateMoveAndReset` and
  `fixturePagesNewerRowsProvidersAndDedupAreReadOnly` in `RequestLogTests`.
- After the review fixes: `make build` passed. `make test` passed 38 tests in the
  TidemarkData run and 8 in the TidemarkEngine run. See [002](002-review-fixes.md).

Reported by the implementing agent and not repeated by Claude Code:

- `git diff --check` passed. Only the touched Swift files were formatted.
- A `make run` check showed these results:
  - The logs start below the viewport.
  - Scrolling loads rows, and further scrolling loaded a second page (100 rows).
  - The header stays at the top of the viewport.
- The same check found two defects, and the agent fixed them:
  - a size calculation that used the bottom-up stack coordinates;
  - column compression and cell alignment.

## Open questions

- **Not runtime-verified:**
  - the header right-click menu
  - header drag reorder
  - Settings drag reorder and persistence after a relaunch
  - horizontal trackpad swipes and the header's horizontal sync
  - the failed, Retry and end-of-list states
  - a burst of newer rows larger than one page
- **Performance:** every page and every refresh runs `dedupFilter` over the whole table
  (about 44,500 rows on the maintainer's database on 2026-11-03). Each refresh also
  re-reads the whole loaded span. The filter falls back to `1 = 1` unless the table has
  both successful proxy rows and session rows. The maintainer's database has no proxy
  rows, and one page took about 11 ms there. Nobody has measured a database with both
  kinds of row.
- **Code placement:** `RowScrollPreservation` is in `TidemarkEngine`, and the maintainer
  has not confirmed that it fits there.
- **Runtime:** the review fixes (refresh reconciliation, scroll anchoring and Settings
  reorder) have not been checked in the running app. The open runtime checks from
  [003](003-ui-and-model-names.md) also still apply.
- **Cost:** stored costs can differ from CC Switch's display until CC Switch backfills
  the missing prices.
- **Fresh Input:** the list uses the frontend `getFreshInputTokens` rule. The Usage
  aggregate uses `fresh_input_sql`, which also reads `input_token_semantics`, so a
  row's Fresh Input can differ from its share of the Usage total. The implementing
  agent reported this. Claude Code did not check it.
- The redesigned sticky header has not been code-reviewed.
