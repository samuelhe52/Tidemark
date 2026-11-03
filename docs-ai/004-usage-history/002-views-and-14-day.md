# 004.002 — Chart, per-model view and the 14-day range

## Context (2026-11-03)

After the first slice, the maintainer asked for a 14-day range and for switching
the section among a bar chart of usage over the range (hover shows a bar's
figures), the existing per-harness list, and a per-model list.

## Change

- `UsageHistoryRange` gains `14d` (the picker now shows today, 7d, 14d, 30d and all)
  and a chart bucket unit: local hours for today, local days for 7d/14d/30d,
  and local months for all time.
- The reader runs a single grouped query instead of the by-app summary. It groups
  detail rows by quarter hour, folded app, and effective model
  (`COALESCE(NULLIF(pricing_model, ''), model)`, CC Switch's `get_model_stats` key),
  and rollup rows by day, app, and model, with the same dedup, fresh-input and
  whole-day rules as before. Swift folds the slices into `apps`, `models` and
  `buckets`, so all three views add up to the header total.
  - Quarter-hour slots: every current UTC offset is a multiple of 15 minutes, so
    local hour, day and month boundaries never split a slot.
  - Rejected: three queries mirroring `get_usage_summary_by_app`, `get_model_stats`
    and `get_daily_trends` separately. That would cost three dedup scans per refresh,
    and the views could disagree, because CC Switch's trend `total_tokens` excludes
    cache tokens while its summary includes them.
- Bars plot total tokens including cache, the same measure as the header, so the bars
  sum to the headline figure. This differs from CC Switch's trend chart, which plots
  fresh input plus output. Today shows all 24 hours (future hours empty); all time
  starts at the month of the first usage. CC Switch sizes `today` to elapsed hours
  and uses a heatmap for all time.
- The dashboard header has a three-segment icon control (over time, by harness, by
  model) beside the range pop-up. The choice persists as `usageHistoryView`; the
  default is the chart. Hovering a bar highlights it and fills a readout line above
  the bars; otherwise the line names the busiest bucket. List views show the five
  largest groups and fold the rest into one "N other" row once there are more than six.

## Refs

- `Packages/TidemarkKit/Sources/TidemarkData/UsageHistory.swift`,
  `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageHistoryTests.swift`
- `Sources/Tidemark/UsageChartView.swift`, `Sources/Tidemark/DashboardView.swift`,
  `Sources/Tidemark/HistoryText.swift`, `Sources/Tidemark/CompanionController.swift`

## Validation

- `make test`: 4 engine and 30 data tests pass. The history test now also checks
  model grouping under a pricing model, 30 daily buckets summing to the total, 24
  hourly buckets for today, and monthly buckets for all time.
- `make build` succeeds.
- A scratch driver against a copy of the maintainer's database showed buckets and
  model rows summing exactly to the per-app totals, in tokens and requests, for
  every range. The 30-day per-app totals still matched the sqlite3 reference.
  Reads took 0.01–0.1 s.
- Not done: viewing the chart, hover readout, or segmented control in the running
  app (no screen-recording or accessibility access in the session).
