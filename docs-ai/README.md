# Tidemark design and decision records

This directory records why Tidemark is built this way and what actually shipped.
Use the [workflow](workflow.md) for substantial new features and decision-shaping
fixes. Ordinary tasks do not need numbered documentation.

## Index

| ID | Anchor date | Topic / plan | Status | Outcome |
| --- | --- | --- | --- | --- |
| 001 | 2026-11-02 | [Companion foundation: product design and scaffold](001-companion-foundation/000-plan.md) | In progress — first native companion and passive quota slice delivered | [Scaffold](001-companion-foundation/002-scaffold.md), [single-source design and build settings](001-companion-foundation/003-single-source-design.md), [first companion](001-companion-foundation/004-first-companion.md) |
| 002 | 2026-11-03 | [Live quota and a native companion surface](002-live-quota-native-surface/000-plan.md) | Implemented | [Action record](002-live-quota-native-surface/001-action.md) |
| 003 | 2026-11-03 | [Direct multi-account quota](003-direct-multi-account-quota/000-plan.md) | Implemented — shared desktop refresh race remains | [Action record](003-direct-multi-account-quota/001-action.md), [account visibility](003-direct-multi-account-quota/002-account-visibility.md) |
| 004 | 2026-11-03 | [Usage history in the dashboard](004-usage-history/000-plan.md) | Implemented — runtime layout check pending | [Action record](004-usage-history/001-action.md), [chart and model views](004-usage-history/002-views-and-14-day.md) |

## Find a contract or source

- [Product requirements](001-companion-foundation/PRD.md).
- [Design contract](001-companion-foundation/design.md): behavior, data sources, skins.
- [Orb art-direction concepts](001-companion-foundation/orb-concepts.html) (not approved).
- [Codex design review, rounds 1–3](001-companion-foundation/historical/codex-review.md).
