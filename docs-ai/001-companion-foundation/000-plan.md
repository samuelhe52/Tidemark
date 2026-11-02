# 001 — Companion foundation: product design and scaffold: Plan

| Field | Value |
| --- | --- |
| Status | In progress — implementation authorized; first companion slice underway |
| Anchor date | 2026-11-02 |
| Origin | Maintainer's PRD, a design discussion with a Codex agent, and an HTML plan the maintainer answered (since folded into [design.md](design.md)). This record was written on 2026-11-02, after the design phase and the scaffold (`6988d2d`) but before any feature code. It consolidates those inputs; it did not precede the scaffold. |
| Related | [Design contract](design.md), [PRD](PRD.md), [orb concepts](orb-concepts.html), [Codex review](historical/codex-review.md) |

## Background

The maintainer wants a macOS desktop companion that rests at a screen edge, comes
alive on hover, and shows Claude Code and Codex quota and usage in an elegant,
skinnable form ([PRD](PRD.md)). Codenotch is the functional reference; its visual
design is the thing to beat.

A Codex review (three rounds, [historical/codex-review.md](historical/codex-review.md))
found that CC Switch persists no quota results — its usage cache is process-local —
so quota must come from the agents' own files or vendor endpoints. CC Switch remains
the source of token and cost history.

## Goals

- Three presentation states: a hidden edge glow, a revealed orb with a one-line
  summary, and an expanded dashboard (which a click can pin).
- Quota left and reset time for every window each account reports, with the age of
  the source. Token and cost history from CC Switch, labeled as an estimate.
- An appearance system in which skins change shape, motion, and behavior while
  sharing one engine and one data snapshot. First version: the orb and one sprite pet.
- Never write or refresh another tool's credentials.

### Non-goals

- A CC Switch export or IPC channel (maintainer: not needed for now).
- The orb "mood", which showed quota pressure through motion and color (maintainer: skip for now).
- Downloadable or code-running skins. A skin is a manifest folder.
- The Mac App Store.

## Design / approach

[design.md](design.md) is the single source of truth for the behavior, data
sources, and skin contract. It is a living file; this plan records the goals and
the decisions behind it.

Module layout, as scaffolded: `Packages/TidemarkKit` with three targets that do not
depend on each other, and the app target as the only code that imports more than one.

| Concern | Target | Owns |
| --- | --- | --- |
| Companion engine | `TidemarkEngine` | Placement, docking, hover and pin state, timing. No I/O, no drawing. |
| Appearance | `TidemarkAppearance` | Skins and rendering. Never moves windows, reads credentials, or changes data. |
| Data | `TidemarkData` | Sources, normalization, freshness. No AppKit or SwiftUI. |

The dashboard is shared and not skinnable.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Native Swift: nonactivating `NSPanel`, SwiftUI dashboard, Metal orb | Maintainer kept the plan's default over Tauri and Electron, which need native code for the window rules anyway and cost more idle memory. |
| Hide over full-screen apps | Maintainer changed the default from "glow only": full screen means focus. |
| 600 ms dwell or click opens; click pins; 400 ms leave grace | Maintainer kept the plan default over "first hover opens" (more accidental opens) and "click only". Codex round 2 accepted the timings as initial tuning values, not validated numbers. |
| Passive quota sources by default, live opt-in | Passive sources need no credentials. Codex round 2 showed the Codex app-server can rewrite auth, and Claude's tap carries only what Claude Code last learned. |
| Codex live source: `wham/usage` with the Keychain token, not the Codex app-server | The app-server can refresh tokens in `~/.codex/auth.json`. |
| Keychain for live credentials, not CC Switch's files | Maintainer proposed using CC Switch's auth files only; round 3 showed CC Switch reads the Keychain first and its Codex file holds only refresh tokens. The maintainer accepted. |
| No CC Switch export or IPC | Maintainer: not needed for now. |
| Orb plus one sprite pet in the first version | Maintainer kept the plan default: a second skin proves the contract. Codex preferred the orb only. |
| History adds `proxy_request_logs` and `usage_daily_rollups` | CC Switch deletes detail rows once it rolls them up; the HTML plan's "rollups only" was wrong. |
| No orb mood for now | Maintainer deferred it. Codex round 2 warned that pace-based urgency is noisy. |
| Separate SwiftPM targets for the three concerns | PRD section 4; the compiler then stops one concern from importing another. |
| Developer ID direct distribution, macOS 15+, no sandbox | Codex round 1 proposal, kept in the scaffold. Reading other tools' files and Keychain items is the inferred reason for no sandbox. |

## Validation and acceptance criteria

- Engine: state-transition tests for reveal, dwell, pin, unpin, and leave grace,
  run as `TidemarkKit` package tests.
- Data: parsing tests against redacted fixtures of each source format, including
  a Codex payload whose `primary` window is weekly and a missing window.
- Freshness: stale or missing data renders as unknown with its age; after a reset
  passes, the window shows "refresh needed", never 100 % left.
- History: totals for a scope match CC Switch's own usage view for the same scope,
  which catches both missing rollups and double-counted session rows.
- Runtime: the panel never takes focus, passes clicks outside its shape, hides over
  full-screen apps, and renders nothing while hidden.

## Unresolved decisions

- Orb art direction: [orb-concepts.html](orb-concepts.html) has three concepts
  (Tide, Ember, Iris), not yet shown to or approved by the maintainer.
- Whether the menu-bar item in the scaffold stays. Codex round 1 proposed
  "menu-bar recovery, no Dock icon"; the maintainer has not confirmed it.

## Evidence and recovered rationale

- **Source documents:** [PRD.md](PRD.md), the HTML plan (removed; retrievable at
  `8e2b536:docs/plan.html`), and [historical/codex-review.md](historical/codex-review.md). CC Switch facts refer to
  version 4.0.24 as inspected on 2026-11-02.
- **Recovered discussion:** the maintainer's answers to the plan and the later
  decisions listed in [003](003-single-source-design.md) come from the scaffolding
  agent's handoff notes of 2026-11-02. The maintainer confirmed them on 2026-11-02.
  The Codex review corroborates the data-source findings.
- **Inference:** the reason for disabling the sandbox is inferred, as marked above.

## Amendments

- Updated 2026-11-02: project scaffold — see [002-scaffold.md](002-scaffold.md)
- Updated 2026-11-02: fold the HTML plan into design.md, aligned package concurrency settings and signing — see [003-single-source-design.md](003-single-source-design.md)

- Updated 2026-11-03: implementation authorized; first native companion slice planned — see [004-first-companion.md](004-first-companion.md)
