# 001.003 — Single-source design and build settings

## Context

On 2026-11-02 the maintainer confirmed the decisions that the HTML plan lacked and
asked to make the docs-ai entry the single source of truth, removing the HTML plan.
The same request asked to align the package's concurrency settings with the app,
use the newest Swift, and match AniShelf's signing configuration.

## Change

### Design

`plan.html` and `plan.packed.html` were removed. Their content now lives in
[design.md](design.md), with these changes from the HTML:

| HTML plan | Now in design.md |
| --- | --- |
| "Edge Companion", `Sources/Data/...`, `EdgeCompanion/` support folder | Tidemark; the three `TidemarkKit` targets; `~/Library/Application Support/Tidemark/` |
| Default: show the glow over full-screen apps | Hides over full-screen apps; no `.fullScreenAuxiliary` (1.1) |
| Statusline tap, Codex rollouts, OAuth, Codex app-server | Adds `~/.claude.json` `cachedUsageUtilization`; Codex live uses `wham/usage` with the Keychain token instead of the app-server; other CC Switch accounts show last dated numbers (3.1) |
| One account per service | Several accounts; every window optional; Codex `primary` may be weekly (3.4) |
| History from `usage_daily_rollups` only | Adds both tables, as CC Switch does, with its duplicate filter and fresh-input rule (3.6) |
| Fixed 14-day history | Clickable scope with CC Switch's presets and filters (3.7) |
| Mood (claim 4), pace warning, mood-driven clips and cues | Removed (6) |
| "Esc and the menu-bar item open and close the panel" | Menu-bar item left out pending its open question |

Checking CC Switch's source while folding in 3.6 showed that summing
`proxy_request_logs` directly double-counts: session-log rows can duplicate proxy
rows, and CC Switch removes them with `effective_usage_log_filter`. The HTML plan
did not mention this.

`orb-concepts.html` stays: it is art-direction material, not a plan.

### Build settings

- `Packages/TidemarkKit/Package.swift`: swift-tools-version 6.4 (the installed
  toolchain is Swift 6.4.2) and Swift 6 language mode, the newest available. All
  targets enable `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, and
  `MemberImportVisibility`, matching the app's approachable-concurrency and
  member-import settings. `TidemarkEngine` and `TidemarkAppearance` default to the
  main actor like the app; `TidemarkData` stays nonisolated because it does file
  and network I/O.
- `Tidemark.xcodeproj`: removed the explicit `CODE_SIGN_IDENTITY = "Apple
  Development"` settings. Like AniShelf, the app target now sets only
  `CODE_SIGN_STYLE = Automatic` and `DEVELOPMENT_TEAM = 768QBKMWKW`, so Xcode picks
  the identity, and export can choose Developer ID. Hardened runtime stays on:
  notarization requires it. AniShelf's project-level `DEVELOPMENT_TEAM =
  LB52UWA223` was not copied; its target-level setting overrides it.

## Refs

- [design.md](design.md); removed files are retrievable at `8e2b536:docs/plan.html`.
- Validation on 2026-11-02: `make build-kit` and `make build` succeeded. A verbose
  package build showed the three upcoming features on all targets and
  `-default-isolation MainActor` only on Engine and Appearance. `codesign` showed
  the Debug app signed "Apple Development" with team `768QBKMWKW` and the hardened
  runtime flag.
