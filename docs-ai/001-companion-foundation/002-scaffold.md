# 001.002 — Project scaffold

## Context

The maintainer asked to settle the name, the working directory, and the project
scaffold before any implementation. The name Tidemark was chosen over Selkie and
Kodama (recovered from the scaffolding agent's handoff notes).

## Change

Commit `6988d2d` (2026-11-02) added an empty, buildable app:

- `Tidemark.xcodeproj`: hand-written, with synchronized root groups for `Sources/`
  and `Resources/`, the shared `Tidemark` scheme, and the local package
  `Packages/TidemarkKit`. Bundle ID `com.samuelhe.Tidemark`, macOS 15.0, Swift 6,
  `LSUIElement`, no App Sandbox, hardened runtime, `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- `Packages/TidemarkKit/Package.swift`: the three targets from the plan, with no
  dependencies on each other and one placeholder type each.
- `Sources/Tidemark/TidemarkApp.swift`: a `MenuBarExtra` with a Quit command. This is
  a placeholder until the engine's panel exists; see the menu-bar question in the plan.
- `Makefile`, `AGENTS.md` (with `CLAUDE.md` linking to it), READMEs, `LICENSE`, and
  `.swift-format`.

No test targets were added: the first tests arrive with the first engine and data code.

On 2026-11-02 the design inputs moved from `docs/` into this entry, and the
docs-ai workflow was adopted ([workflow](../workflow.md)).

## Refs

- `6988d2d chore: Scaffold Tidemark app and TidemarkKit package`
- `8e2b536 docs: Add product requirements and design plan`
- Validation run on 2026-11-02 at `6988d2d`: `make build`, `make build-kit`, and
  `make lint` succeeded with no warnings or lint findings. The scaffolding agent
  reported that `make run` launched the app but could not confirm the menu-bar icon.
