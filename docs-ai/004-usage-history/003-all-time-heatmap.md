# 004.003 — All-time heat map

## Context (2026-11-04)

The maintainer requested an All Time chart style switch with a daily heat map
like the supplied CC Switch screenshot, and specified heat map as the default.

## Change

- Keep chart / harness / model breakdowns. In Settings → Usage → Display, add an
  All-time chart picker (heat map / monthly bars), persisted independently and
  defaulting to heat map. The dashboard has no chart-style control.
- Supply daily totals from the same normalized, deduplicated slices as the
  headline and monthly bars. Never reconstruct daily usage from monthly totals.
- Display Monday-first, 53-week spans, newest first, with navigation to older
  spans. Use one token intensity scale across all spans; hover names each day
  and its tokens, estimated cost and requests. Exclude future days.
- Keep the existing hourly and daily bar charts for shorter ranges.

## Implementation and decisions

- `Packages/TidemarkKit/Sources/TidemarkData/UsageHistory.swift` adds all-time
  daily buckets alongside monthly buckets. Both reuse the existing query slices.
  Removed the 2,000-bucket cap so long histories cannot silently lose recent days.
  Instead, All Time buckets reach back at most 20 years; an older (corrupt) date
  folds into the oldest bucket, so sums still match the headline.
- `Sources/Tidemark/UsageHeatmapView.swift` draws seven weekday rows across
  53 weeks, navigates older spans, and maps positive daily tokens to four levels
  using a square-root scale against the all-time daily peak. Empty days use a
  neutral color; future days have no cell.
  `DashboardView` owns the viewed page: the heat map is rebuilt whenever today's
  totals change on the minute refresh, and must not jump back to the current
  span. Hover snaps to the cell under the pointer, gaps included. Weekday labels
  come from the calendar's localized symbols.
- `Sources/Tidemark/SettingsStore.swift`, `DefaultsKey.swift`, and
  `SettingsView.swift` persist the All-time chart choice and apply it immediately.
  The missing/invalid preference defaults to heat map. After the maintainer's
  clarification, the style picker is in Settings, not in the dashboard.
- `Sources/Tidemark/DashboardView+History.swift` selects the daily heat map only
  for the All Time chart; other ranges and breakdowns retain their existing views.

## Validation

- `make test`: 8 engine and 41 data tests passed. Aggregation assertions cover
  rollups, deduplicated detail rows, empty days, sum agreement with the headline,
  histories longer than 2,000 days, and 23-/25-hour DST days.
- `make build` and final `make run` succeeded.
- Running app: inspected screenshots at the native dashboard width; checked
  month/weekday labels, daily cells, legend and navigation. Earlier navigation
  reaches May 2024 and disables at the oldest span. Monthly bars still render.
- Running app: verified Settings → Usage → Display contains the style picker,
  its choice persists across relaunch, and changing to heat map updates the
  dashboard immediately. Left the preference on heat map. No dashboard style
  picker remains.
- Post-audit fixes (page persistence, hover snapping, localized weekdays, 20-year
  floor): `make test` (42 data tests) and `make build` passed; not yet checked in
  the running app.
- Hover details are implemented but pointer-driven hover was not independently
  verified; accessibility image activation did not generate a hover event.

