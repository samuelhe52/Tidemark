# 002 — Live quota and a native companion surface: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Plan written before code | [000-plan.md](000-plan.md) |
| 2026-11-03 | AppKit + Core Animation surface, live quota, managed Codex accounts, last-good store | Uncommitted working tree |
| 2026-11-03 | Dashboard and summary glass tinted for legibility after maintainer feedback | Uncommitted working tree |
| 2026-11-03 | Review fixes: account attribution, gate key, future-dated readings, dashboard height | Uncommitted working tree |

## Outcome and current state (as of 2026-11-03)

- The app no longer uses SwiftUI. `AppDelegate` is the entry point and owns an
  `NSStatusItem` menu (Show Companion, Reset Position, Live Usage, Quit).
- `CompanionStageView` holds the glow, orb, summary and dashboard as layer-backed
  views. Phase changes move each layer's `transform`/`opacity` with `CASpringAnimation`
  starting from the presentation layer. The panel grows before an emerge and shrinks
  to the strip only after the retract completes and the phase is still hidden.
- Surfaces are `NSGlassEffectView` (`.regular`). Text surfaces (`.content`) are tinted
  toward `windowBackgroundColor` at `GlassSurfaceView.contentTintStrength` (0.6); the
  orb is untinted. Before macOS 26 the popover material is used.
- `UsageService` returns one `ServiceUsage` per service with `AccountUsage` rows.
  Codex lists the active account first, then every CC Switch managed account.
  Claude codename windows are dropped. Live answers and attributed passive readings
  are kept in `~/Library/Application Support/Tidemark/usage-snapshots.json` (0600,
  no credentials).

Key files:

- `Sources/Tidemark/TidemarkApp.swift`, `Sources/Tidemark/CompanionController.swift`,
  `Sources/Tidemark/CompanionStageView.swift`, `Sources/Tidemark/DashboardView.swift`,
  `Sources/Tidemark/CompanionLayout.swift`, `Sources/Tidemark/CompanionPanel.swift`,
  `Sources/Tidemark/QuotaText.swift`
- `Packages/TidemarkKit/Sources/TidemarkAppearance/CompanionMotion.swift`,
  `Packages/TidemarkKit/Sources/TidemarkAppearance/GlassSurfaceView.swift`,
  `Packages/TidemarkKit/Sources/TidemarkAppearance/OrbView.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`,
  `Packages/TidemarkKit/Sources/TidemarkData/LocalSources.swift`,
  `Packages/TidemarkKit/Sources/TidemarkData/QuotaParser.swift`,
  `Packages/TidemarkKit/Sources/TidemarkData/LiveRequestGate.swift`,
  `Packages/TidemarkKit/Sources/TidemarkData/SnapshotStore.swift`,
  `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`

## Review fixes

A two-reviewer Codex review with a debate pass found six defects, all fixed before commit:

- Access tokens were cached until expiry, so after a Claude or Keychain Codex account
  switch the old account's quota was stored under the new one. Tokens are now read on
  every gated request, as the plan states.
- Statusline tap readings carry no account. A reading taken before Tidemark saw a
  Claude account switch is no longer attributed to the new account.
- With a file sign-in, the active Codex account comes from `auth.json`
  (`tokens.account_id` only), not CC Switch's marker, which is stale after a direct
  `codex login`.
- A Keychain Codex request gated under `codex:local` recorded its gate under that key,
  so the next refresh under the real account bypassed the interval and `Retry-After`.
- A reading dated more than five minutes ahead (clock was ahead) blocked every later
  reading in the store. Such readings are now never chosen or kept.
- On the top and bottom edges a tall dashboard was clamped over the orb, which then
  took clicks meant for the dashboard. Its height is now limited to the space beside
  the orb.

## Deviations from plan

- Memory: removing SwiftUI did not lower the footprint. Measured `phys_footprint`
  was 27 MB before and 27–29 MB after (peak 30 MB); `ps` RSS was 88 MB before and
  92 MB after. In `vmmap`, most resident pages are shared system-framework `__TEXT`
  and `__OBJC_RO`, and the malloc heap is about 17 MB. The plan's "lower resident
  memory" goal was not met.
- The plan named the popover material for text surfaces; after maintainer feedback
  the dashboard keeps Liquid Glass with a tint instead.
- A sub-agent was delegated the Data layer, but it stopped after changing only the
  model enums; the Data layer was then written directly.

## Validation

| Check | Result |
| --- | --- |
| `make test` | 19 tests passed (4 Engine, 15 Data); after the review fixes, three Data tests cover the account switch, the gate key and future-dated readings. Data tests cover live parsing (microsecond dates, codename filtering, weekly primary), expired token not sent, live off reads no credentials and sends nothing, managed accounts (active, stored, not observed), no token in the store, gate Retry-After and backoff. |
| `make build` | Passed. |
| Touched-file `swift format -i` / `lint` | Formatted. Remaining lint warnings: documentation-summary style, and two `chatgpt_account_id` Decodable property names. |
| Live endpoints (before code, read-only `GET` with existing tokens) | Both returned 200; response shapes recorded in the plan. |
| Runtime live data | With Live Usage on, the store held `live` readings for the Claude account and the active Codex account; the dashboard showed both plus two managed Codex accounts as not seen in use. |
| Motion recording (`screencapture -v`, 30 fps frames) | Emerge, dwell-expand, leave-retract and a re-entry during retract all animated; the retract finished before the panel shrank. Recorded before the glass tint change. |
| Legibility over a bright wallpaper | Maintainer screenshot showed white text on clear glass; tint added. The tinted result was not re-checked by the agent (maintainer is verifying). |

## Open questions

- Whether 0.6 tint strength is the right legibility/translucency balance.
- Inactive CC Switch Codex accounts get numbers only after Tidemark observes them as
  the active account. Live numbers would need refresh-token use, which would rotate
  CC Switch's single-use tokens.
- The statusline tap is still attributed by timing only: a Claude account switch made
  while Tidemark was not running, or a tap written after the switch by an older session,
  can still be credited to the new account.
- Claude multi-account (CC Switch `claude_accounts.json`) is not implemented; the
  file is absent on this machine.
