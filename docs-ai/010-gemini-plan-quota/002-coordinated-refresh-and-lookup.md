# 010.002 — Coordinated refresh and CLI lookup

## Context

Review on 2026-11-26 found that the plan's goal "A slow `agy` run does not delay Claude
and Codex readings" did not match the code: `UsageService` refreshes the services
concurrently, but returns one result, which `UsageModel` applies when all have finished.
It also found repeated login-shell lookups while `agy` is missing, and two copies of the
lookup code.

## Change

- **Coordinated results are kept.** Maintainer decision on 2026-11-26. Readings publish
  together, bounded by the slowest service rather than the sum. Publishing per service
  was drafted and dropped: new account IDs were saved in completion order, and the
  dashboard's checked time changed several times per cycle.
- **PATH discovery** (`56285e1`): with Live Usage on, `agy` outside the known paths is
  found through the login shell. This replaced the original rule that an unknown path
  counted only if the shell had found it before.
- **Misses are kept.** A miss is kept until Live Usage is turned on again or Tidemark
  relaunches; `56285e1` retried it on every manual refresh, which made every service wait
  for a shell. A shell that times out also counts as a miss. An `agy` installed later at
  a known path is still found at once.
- **One lookup per refresh.** `run()` uses the result of the presence check instead of
  asking the shell again after a miss.
- **Shared code.** `CLILocator` holds the lookup, its cache and the `PATH` setup for both
  CLIs, and `CLIProcess` the bounded wait. Claude Code still retries a miss on every
  run its gate allows, as before. Arguments, environment cleanup and output handling
  stay separate, because one command refreshes a cache file and the other answers on stdout.

Corrected in place: the concurrency and discovery text in [000-plan.md](000-plan.md) and
[001-action.md](001-action.md).

## Refs

- `56285e1`, `f8df0da` (shared lookup), `2a29dde` (miss retry).
- `Packages/TidemarkKit/Sources/TidemarkData/CLILocator.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`
- Tests: `agyCommandDiscoversPathOnlyInstallAndCachesMisses` (extended),
  `onlyTurningLiveOnRetriesAMissedAgyLookup` (new).
- Validation on 2026-11-26: `make test` passed (8 Engine, 75 Data tests); `make build` passed. No runtime check of the app.
