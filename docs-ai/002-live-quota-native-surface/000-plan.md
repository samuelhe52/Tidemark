# 002 — Live quota and a native companion surface: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — see [001-action.md](001-action.md); memory goal not met |
| Anchor date | 2026-11-03 |
| Origin | Maintainer feedback on the first companion (2026-11-03): poor expand/close motion (screen recording), a dashboard that "lacks taste", 95 MB reported memory, and a request for live Claude and multi-account Codex quota. Written before the code changes. |
| Related | [001 companion foundation](../001-companion-foundation/000-plan.md), [design contract](../001-companion-foundation/design.md) |

## Background

The first slice ([001.004](../001-companion-foundation/004-first-companion.md))
rendered the companion with SwiftUI. Its recording shows the orb and summary
appearing in one frame, the dashboard fading in, and every exit cut to nothing:
the controller resized the window to the 8 px strip at the moment the phase
became hidden, so the exit animation never ran. The dashboard forced a dark
scheme, custom cyan/mint/orange colors, nested cards and a tagline. Claude
showed codename windows (`iguana_necktie`) and old cache readings as "Unknown".

Memory, measured on 2026-11-03 for the running Debug build (pid 32147):
`phys_footprint` 27 MB (peak 29 MB), resident size (`ps` RSS) 88 MB. The 88–95 MB
figure comes from tools that show RSS, which counts shared system-framework pages.

Credential findings on this machine (metadata only, 2026-11-03):

- `~/.cc-switch/codex_oauth_auth.json` (version 2) holds three managed Codex
  accounts with `account_id`, `chatgpt_account_id`, `email`, `id_token`,
  `refresh_token`, timestamps — no access token.
- `~/.codex/auth.json` (`auth_mode: chatgpt`) holds the account CC Switch made
  live, with an access token valid for days. Its `last_refresh` equals one managed
  account's `token_updated_at_ms`; `codex_managed_oauth_live_auth.json` names the
  same account. The `Codex Auth` Keychain item is months older than the file.
- Keychain `Claude Code-credentials` holds `claudeAiOauth.{accessToken, expiresAt, …}`.
- A read-only `GET` with each agent's existing access token returned 200 from
  `api/oauth/usage` and `wham/usage`.

OpenAI refresh tokens are single use (openai/codex#6036, openai/codex#10332):
spending CC Switch's stored refresh token signs that account out of CC Switch
unless the rotated token is written back.

## Goals

- Motion that runs in the render server: transform and opacity animations on
  Core Animation layers, interruptible, with a real exit.
- A native, appearance-following dashboard and summary: system materials, system
  fonts and colors, standard controls.
- Lower resident memory by removing SwiftUI from the runtime path.
- Live quota for the signed-in Claude and Codex accounts, and every CC Switch
  managed Codex account listed with its newest dated reading.

### Non-goals

- Refreshing or rotating any agent's or CC Switch's tokens, or writing their files
  or Keychain items. Inactive managed Codex accounts therefore show the last
  reading Tidemark observed while that account was live, with its age.
- CC Switch history, manifest skins, the sprite pet, final orb art.

## Design / approach

**Surface (app target, Appearance).** One AppKit view tree inside the existing
nonactivating panel; no SwiftUI. Layers: the edge glow, the orb (an Appearance
`OrbView`), the summary capsule and the dashboard, each a layer-backed view whose
`transform` and `opacity` are animated with `CASpringAnimation` from the current
presentation value, so a reversal mid-flight continues smoothly. The window grows
to its visible frame before the emerge and shrinks to the strip only after the
retract completes and the phase is still hidden. Reduce Motion and Low Power Mode
use short fades and no idle motion. Materials: `NSGlassEffectView` on macOS 26+,
`NSVisualEffectView` (`.popover`) before. The app uses an `NSStatusItem` instead of
SwiftUI `MenuBarExtra`.

**Data (`TidemarkData`).** A `UsageService` actor replaces the passive reader's
public surface and returns `[ServiceUsage]` of `AccountUsage` values. Sources per
account: live request (opt-in), passive files attributed to that account, and
Tidemark's own last-good store (`~/Library/Application Support/Tidemark/usage-snapshots.json`,
no secrets). The newest observation wins; windows from different observations are
never merged. A pure `LiveRequestGate` enforces the minimum interval, `Retry-After`
and exponential backoff with jitter. Credentials are read per request and kept in
memory only; an expired token is reported, never refreshed.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Core Animation instead of SwiftUI animation | SwiftUI ticks animations on the main thread and the first slice lost its exit to a window resize. CA springs run in the render server. A Metal orb is still possible later inside the same layer. |
| AppKit dashboard instead of SwiftUI | Native controls, lower resident memory, one view system. Costs more layout code. |
| Inactive Codex accounts: last observed reading only | Live numbers need an access token; CC Switch keeps only single-use refresh tokens on disk. Refreshing would sign CC Switch out or race its write-back, which the repository rules forbid. |
| Active Codex token from `auth.json`, Keychain only when `cli_auth_credentials_store` is `keyring`/`auto` | On this machine the Keychain item is stale and the file is current; Codex's configured store decides. |
| Live stays opt-in, toggled in the dashboard and menu | Keeps 001's decision: passive mode needs no credentials or network. |
| Hide unknown Claude codename windows | Labels like `iguana_necktie` cannot be named truthfully. |

## Validation and acceptance criteria

- `make test`: gate timing/backoff, live payload parsing (Claude, Codex),
  account attribution, newest-observation selection, snapshot round trip.
- `make build`; runtime: frame-sampled recording of emerge, expand, retract and a
  reversal; dashboard screenshot in light and dark; live data for both services;
  `footprint` and RSS before/after in the same configuration.

## Amendments

None yet.
