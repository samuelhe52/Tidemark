# 010 — Gemini plan quota through the Antigravity CLI: Action record

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-26 | Inspected `agy` 1.5.16, drafted HTML plan, received maintainer decisions and horizontal-row comment, wrote `000-plan.md`, implemented data layer, dashboard horizontal row, and tests. | `ec71d1d` |

## Outcome and current state (as of 2026-11-26)

Live Gemini plan quota is implemented in `TidemarkData` and the app target, mirroring
entry 008's CLI-delegated credential boundary:

- `QuotaService.gemini` (raw value `gemini`, account key `gemini:local`) is included in
  `UsageService.refresh` only when `agy` exists at a known install path (or was cached by
  a previous shell lookup) or `usage-snapshots.json` already holds `gemini:local`.
- With Live Usage on, `AgyCLIUsageCommand` runs
  `agy -p /usage --output-format json --log-file /dev/null --print-timeout 40s` with cwd
  `~`, routing proxy variables (HTTP, HTTPS, and SOCKS) through `UsageProxy.agyEnvironment`
  targeted at `daily-cloudcode-pa.googleapis.com`, writing stdout to a `0600` temporary
  file capped at 256 KB. Raw output is parsed and discarded.
- `QuotaParser.agyUsage` parses `command.data.groups[].buckets[]` into four canonical
  windows (`five_hour_gemini`, `seven_day_gemini`, `five_hour_3p`, `seven_day_3p`) with
  `usedPercent = (1 - remaining_fraction) * 100`, dropping unknown groups/windows and
  marking missing or out-of-range fractions unknown. `QuotaWindow.isWeekly` covers the
  group-scoped weekly windows so weekly pace warnings apply.
- `UsageService.performRefresh` runs Claude, Codex, and Gemini refreshes concurrently via
  `async let` so `agy`'s ~7 s run does not stall Claude or Codex.
- `DashboardView` renders Gemini's windows in a single sideways-scrolling row using a
  shared `HorizontalScrollView` (extracted from `RequestLogHorizontalScrollView`) with
  hidden scrollbars, horizontal scroll-offset preservation across dashboard refreshes,
  and per-gesture vertical scroll routing to the dashboard's outer scroll view.
- `QuotaText` names the service "Gemini", names the windows "5-hour · Gemini",
  "Weekly · Gemini", "5-hour · 3P", and "Weekly · 3P", and tailors
  `cliUnavailable`, `cliFailed`, `credentialExpired`, and `requestFailed` copy per service.
  `SettingsView`'s Live usage footer notes both Claude Code and `agy`.

Key source files:
- `Packages/TidemarkKit/Sources/TidemarkData/AgyUsageCommand.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/QuotaObservation.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/AccountKey.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/QuotaParser.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageProxy.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`
- `Sources/Tidemark/DashboardView.swift`
- `Sources/Tidemark/DashboardView+BuildingBlocks.swift`
- `Sources/Tidemark/RequestLogView.swift`
- `Sources/Tidemark/QuotaText.swift`
- `Sources/Tidemark/SettingsView.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/PassiveQuotaTests.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageProxyTests.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/QuotaDisplayPreferencesTests.swift`
- `docs-ai/001-companion-foundation/design.md`

## Deviations from plan

- Shared `HorizontalScrollView` was extracted into `DashboardView+BuildingBlocks.swift`
  and inherited by `RequestLogHorizontalScrollView` in `RequestLogView.swift` so both
  horizontally scrolling regions use one gesture-routing implementation instead of
  duplicating it.
- Tiles in the horizontal Gemini row use a `150…184 pt` width range so the first two
  tiles align with Claude and Codex's 2-column grid while longer window labels fit
  without ellipsis when scrolled into view.

## Validation

Run on 2026-11-26:
- `swift format -i` on all 18 touched Swift files.
- `make test`: passed — 8 Engine tests (2 suites) and 72 Data tests (9 suites), including
  7 new tests covering `QuotaParser.agyUsage`, `UsageService` Gemini presence/live/off/gate/error
  paths, `UsageProxy.agyEnvironment`, and `AgyCLIUsageCommand` stdout/exit handling.
- `make build`: passed (`Tidemark` Debug scheme).
- `make launch` runtime check: the launched Debug app ran `agy` 1.5.16 and persisted
  `gemini:local` to `~/Library/Application Support/Tidemark/usage-snapshots.json` with all
  four live windows (`five_hour_gemini` 21.4% used, `seven_day_gemini` 6.1% used,
  `five_hour_3p` 100% used, `seven_day_3p` 51.8% used), confirming that an exhausted
  bucket (`remaining_fraction: 0`) is serialized and parsed as 100% used rather than
  omitted.

Not yet verified:
- Visual layout, horizontal trackpad scrolling, and vertical gesture hand-off over the
  Gemini row inside the live dashboard panel (needs maintainer check on trackpad).
- Live SOCKS5 proxy handshake through `agy` (only connection refusal against a closed
  `socks5://127.0.0.1:1` port was observed).
- Signed-out `agy` exit behavior (untested so the maintainer's sign-in stayed untouched).

## Open questions

- If `agy` is installed only outside known paths (`~/.local/bin/agy`,
  `~/.gemini/antigravity-cli/bin/agy`, Homebrew) and has never run before, `isInstalled`
  stays false so no shell lookup runs on startup. Revisit if users install `agy` in custom
  directories.
