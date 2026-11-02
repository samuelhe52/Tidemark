My recommendation: build a native macOS companion whose quota providers work independently of CC Switch. Use CC Switch for optional provider context and historical tokens/cost. The PRD’s biggest mistake is treating that local history store as the source of subscription limits. Its biggest interaction gap is failing to say what distinguishes revealing the companion from opening its dashboard.

This is a design review, not an implementation. Inspected 2026-11-02. Local findings below are measured; endpoint behavior is source-verified, not authenticated end-to-end tested. I did not retrieve Keychain secret values, invoke quota APIs, refresh credentials, or launch helper servers.

**A. Data sources: verdicts and consequences**

**1 — Confirmed, with an important qualification.** Installed `/Applications/CC Switch.app/Contents/Info.plist` identifies `com.ccswitch.desktop`, version **4.0.24**. Read-only SQLite inspection of `~/.cc-switch/cc-switch.db` returned:

```text
PRAGMA journal_mode -> wal
proxy_request_logs -> 41,799 rows at first inspection
  app_type counts: claude 19,060; codex 21,943; omp 648; pi 148
usage_daily_rollups -> 521 rows
```

Relevant schema shapes:

```text
proxy_request_logs:
  request_id, provider_id, app_type, model, request_model,
  input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
  *_cost_usd, total_cost_usd, latency_ms, first_token_ms, duration_ms,
  status_code, created_at, data_source, pricing_model, input_token_semantics, ...
usage_daily_rollups:
  date, app_type, provider_id, model, request_model, pricing_model,
  request_count, success_count, *_tokens, total_cost_usd, avg_latency_ms, ...
providers:
  settings_config TEXT, meta TEXT, is_current BOOLEAN,
  limit_daily_usd TEXT, limit_monthly_usd TEXT, ...
```

`Claude Official` has the reported enabled `usage_script`: `templateType=official_subscription`, `autoQueryInterval=5`, empty `code`. Both USD limit columns are unset for this provider. Source confirms the interval is **minutes**. These configuration fields do not contain a quota response.

Crucially, the table name does not establish that requests traversed a proxy. A subsequent grouped query found `data_source` values `session_log`, `codex_session`, `omp_session`, and `pi_session`. The current history is imported from session logs. It can lag tool activity and contain calculated token-price equivalents; do not label all costs “subscription spend” or infer subscription depletion from them. Do not add raw logs and daily rollups together without establishing their coverage relationship.

**2 — Correct about persistence; incomplete about caching.** The installed-version source explicitly implements a process-local `UsageCache` containing subscription, managed-account, and script results. Its module comment says it is not persisted and is emptied on restart. Rust commands write it and emit `usage-cache-updated` to the Tauri frontend; React Query keeps another UI cache. This is stronger evidence than merely failing to find a table. See [UsageCache, lines 1–20](https://github.com/farion1231/cc-switch/blob/v4.0.24/src-tauri/src/services/usage_cache.rs#L1), [subscription command](https://github.com/farion1231/cc-switch/blob/v4.0.24/src-tauri/src/commands/subscription.rs#L8), and [query interval/cache handling](https://github.com/farion1231/cc-switch/blob/v4.0.24/src/lib/query/subscription.ts#L89).

Other local surfaces checked:

- `proxy_config`: every existing app row has proxy disabled; configured address is `127.0.0.1:15721`. `lsof -nP -a -p <cc-switch-pid> -iTCP -sTCP:LISTEN` returned no listener. A configured inference proxy is not a quota API.
- `live-state.json` has `{version, apps}`, with app entries exposing `mode`; `settings.json` contains provider/display/preferences keys. Neither inspected shape supplies quota results.
- `session-scan-cache.db` contains `session_scan_cache` and `session_sync_resume`, for session scanning/resumption, not a subscription snapshot table.
- `codex_oauth_auth.json` has `{version, accounts, default_account_id}`: an account/credential store, not a metrics feed.

I found no externally readable quota-result interface in these inspected surfaces. Tauri commands/events are internal app IPC, not an external subscription service. This is not a claim that every backup, log, or WebKit cache was exhaustively searched. Do not scrape logs or app memory as the product integration. If CC Switch dependency is mandatory, propose an upstream sanitized snapshot export or authenticated read-only IPC; that is a separate dependency to secure before promising the product.

**3 — Both candidates are real, but Codex has a better primary interface.**

| Provider/source | Evidence and freshness | Auth implications / recommendation |
|---|---|---|
| Codex rollout events | Confirmed locally under `~/.codex/sessions/**/rollout-*.jsonl`; `event_msg → token_count → rate_limits`. Captured observations, updated when the CLI writes them; idle files do not refresh remote usage. | No credential read needed. Useful offline fallback; not an authoritative live polling source. |
| Codex app-server | Officially exposes `account/rateLimits/read` and `account/rateLimits/updated`, including limit buckets and window durations. | Prefer a compatible installed CLI’s supported interface. Uses its authentication machinery; a separately launched server is not a subscription to every other running CLI process. Refresh explicitly. Version compatibility and auth side effects need validation. |
| Claude OAuth usage | CC Switch 4.0.24 calls `GET https://api.anthropic.com/api/oauth/usage` with bearer OAuth and `anthropic-beta: oauth-2025-04-20`. Parses `utilization`/`resets_at`, plus newer scoped `limits[]`. | A real vendor endpoint used by clients, not a promised public integration contract. Isolate it behind an adapter. Keychain access may prompt; expired credentials and 429s need visible states. |
| Codex direct HTTP | CC Switch and Codenotch call `https://chatgpt.com/backend-api/wham/usage`, using bearer auth and account context. | Viable fallback, but prefer app-server to owning private endpoint and token handling. |
| Claude Desktop cache / Claude CLI | Codenotch implements account-matched Desktop HTTP-cache reads and a CLI `/usage` fallback. | Potential token-free cache source, but private Chromium format and Desktop refresh behavior make it optional. CLI parsing varies by version and can require a terminal interaction. Neither was exercised locally here. |

The supported Codex interface is documented in [OpenAI’s app-server documentation](https://learn.chatgpt.com/docs/app-server). The HTTP adapters and credential lookup are visible in [CC Switch’s subscription service](https://github.com/farion1231/cc-switch/blob/v4.0.24/src-tauri/src/services/subscription.rs#L133).

Concrete local Codex evidence: `~/.codex/sessions/2026/11/02/rollout-2026-11-02T20-44-52-01a19c4a-8732-7481-957d-640703b969d1.jsonl` contained this allowlisted metric subset:

```text
timestamp: 2026-11-02T12:45:21.876Z
type: event_msg; payload.type: token_count
rate_limits:
  limit_id: codex
  primary: {used_percent: 64, window_minutes: 10080, resets_at: 1793774147}
  secondary: null
```

**Primary is weekly on this account. Never hard-code primary=5-hour or secondary=weekly.** Preserve bucket identity, duration, model scope, and missing values. “Remaining 36%” is a complement of vendor-reported utilization, not a prediction of remaining tokens or requests.

Keychain **metadata-only** lookups found services `Claude Code-credentials` and `Codex Auth`; this proves item existence, not validity or permission to read secrets. `~/.codex/auth.json` exists with top-level keys `OPENAI_API_KEY`, `auth_mode`, `last_refresh`, `tokens`; token-object keys are `access_token`, `account_id`, `id_token`, `refresh_token`. No values were printed. `~/.claude/stats-cache.json` contains historical activity/model-token fields, not subscription windows.

For v1, bind each quota snapshot to an explicit account/profile and provenance. CC Switch’s selected provider does not prove which account an already-running agent uses. Never combine the newest rollout from one account with another account’s live response. Honor configurable tool homes. Keep last-good snapshots with their actual observation time; when reset passes, show “refresh needed” until confirmed rather than manufacturing 100% remaining. Suggested polling policy: five minutes hidden, an age-gated refresh on reveal, request coalescing, Retry-After/backoff, and refresh after wake. Do not rotate or overwrite another tool’s OAuth credentials yourself.

**B. Codenotch: keep the engineering lessons, narrow the product**

[Codenotch](https://github.com/vinzdg/codenotch) is an existing native macOS edge quota/activity monitor, not merely a notch animation. Its README describes four-edge placement, a small resting pill, hover unfolding, click-to-pin, per-account/provider readings, and usage reset information. Its model distinguishes official, derived, and manual data and preserves dated last-good readings.

Inspected source at commit `6522e9f3ee0fe35d46e428b441e6e80b586eacbb` shows:

- [NotchPanel.swift](https://github.com/vinzdg/codenotch/blob/6522e9f3ee0fe35d46e428b441e6e80b586eacbb/Sources/Notch/NotchPanel.swift#L73): borderless nonactivating `NSPanel`, `.statusBar` level, all-Spaces/full-screen auxiliary behavior, no key/main focus.
- [NotchWindowController.swift](https://github.com/vinzdg/codenotch/blob/6522e9f3ee0fe35d46e428b441e6e80b586eacbb/Sources/Notch/NotchWindowController.swift#L1230): shape-aware event transparency, local/global mouse monitoring, and a 0.3-second cursor fallback poll.
- [NotchPlacement.swift](https://github.com/vinzdg/codenotch/blob/6522e9f3ee0fe35d46e428b441e6e80b586eacbb/Sources/Notch/NotchPlacement.swift): common along-edge/inward coordinates rather than four duplicated layouts.
- [ClaudeDesktopUsageCache.swift](https://github.com/vinzdg/codenotch/blob/6522e9f3ee0fe35d46e428b441e6e80b586eacbb/Sources/Providers/ClaudeDesktopUsageCache.swift#L3): narrowly scoped cached-response reading with organization matching and capture timestamps.

Keep nonactivation, pinning, provenance, geometry separation, and error handling. Drop provider proliferation, phone sync, and activity detection from the first release. Those are separate products’ worth of maintenance. Do not copy its private `_hasActiveAppearance` selector workaround. This source review establishes implementation techniques, not successful runtime behavior on our display setup.

**C. Stack: native Swift, with one rendering path per appearance**

Choose **AppKit window/input shell + SwiftUI dashboard/settings + a small Metal orb renderer**. Use Core Animation/SwiftUI for panel transitions. Keep a simpler layer-based orb available if it meets the visual target; custom Metal is justified by art direction, not by the word “orb.”

| Option | My verdict |
|---|---|
| Native Swift | Best fit. The difficult requirements are macOS windowing, pointer routing, Spaces, power management, and focus—not dashboard markup. |
| Tauri | Reasonable if cross-platform delivery is imminent. These macOS behaviors still require native integration; Rust/web/native boundaries add work here. |
| Electron | Can produce the UI, but brings Chromium overhead and still needs platform-specific window/input handling. Poor default for a tiny always-running companion. |
| SpriteKit | Good future sprite-pet renderer if scene animation warrants it. Not needed for dashboard or docking. |
| Rive | Strong candidate for authored interactive vector pets: inputs/state machines suit personality. Official Apple runtime supports AppKit/SwiftUI and macOS. Validate a representative asset and power cost before adopting. |
| Lottie | Useful for authored timeline clips; I would not make it the general behavior engine. Its package does support macOS, so rejecting it as “iOS-only” would be wrong. |

See [Rive Apple runtime](https://rive.app/docs/runtimes/apple/apple) and [Lottie package platforms](https://github.com/airbnb/lottie-ios/blob/master/Package.swift#L10). Begin skin extensibility with bounded local assets and manifests: dimensions, anchors, hit regions, named clips, transition/fallback rules. Sprite sheets are the simplest portable pet format; do not ship arbitrary executable skin plugins or require every skin to implement shaders.

The input/window design needs explicit proof:

- Use a nonactivating panel; open settings in a normal focusable window. Start with floating level and raise only if tested full-screen behavior requires it. Evaluate all-Spaces/full-screen auxiliary behavior and Apple’s newer [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications) for Stage Manager; do not blindly combine mutually exclusive flags. “Above ordinary apps” does not mean above system security surfaces.
- Keep a small on-screen activation region when retracted. An off-screen object cannot receive ordinary hover. Track the union of companion, dashboard, and the travel corridor between them; apply enter/leave hysteresis so the panel does not flee from the pointer.
- SwiftUI `contentShape` or a view returning `nil` from hit testing does not itself guarantee clicks reach another app. Window-level [ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) governs transparency. Use bounded panels and pointer-based gating; independently observe entry while a render panel ignores events. Local/global mouse monitors plus infrequent stationary-pointer reconciliation are a plausible approach, demonstrated by Codenotch. Apple documents that global monitors are asynchronous, so fast crossing-and-click behavior needs testing. Do not promise no lost clicks from architecture alone. [Apple event-monitor documentation](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)).
- Save display identity, edge, and normalized along-edge position. Distinguish physical frame from usable dashboard bounds, convert points/backing pixels correctly, handle negative display origins, unplug/replug, notch/Dock/menu-bar exclusions, and adjacent-display seams. An internal seam should not silently behave like an outside screen edge.

**Continuous 120-fps idle animation is a bad default for this product.** Offer 60–120-fps transitions/interaction where supported, modest visible idle cadence, and zero continuous rendering while retracted/asleep. Pause or reduce work for Low Power Mode and Reduce Motion. Keep metrics polling independent of animation. Measure CPU, GPU, wakeups, frame pacing, and energy with representative assets; “uses Metal” proves none of those outcomes.

**D. Architecture and three contracts**

Keep five small modules, not a plugin framework:

1. **WindowHost:** AppKit panels, display/Space lifecycle, event routing, accessibility, settings/menu-bar recovery.
2. **CompanionEngine:** deterministic interaction state, placement intent, dwell/hide timers, pinning, drag, transition progress. Owns interaction timing, not skin-specific animation internals.
3. **AppearanceHost:** loads a descriptor and renderer; validates bounds/hit regions, maps semantic inputs to orb motion or pet clips, applies render budget.
4. **UsageService:** provider adapters, account binding, scheduling, normalization, freshness/error state, sanitized last-good persistence. CC Switch history and quota acquisition remain separate adapters.
5. **Dashboard:** stable readable SwiftUI presentation of normalized metrics; a skin cannot replace or obscure quota semantics.

The three core interfaces can be specified without choosing concrete Swift types yet:

| Contract | Inputs → outputs | Ownership rule |
|---|---|---|
| Engine | `send(event, time)` → `presentation state` | Events include pointer, click, drag, pin, display/wake changes and deadlines. Output includes phase, progress, anchor, dashboard visibility and input regions. No networking. |
| Appearance | `descriptor` + `render(context)` → hosted content/geometry | Descriptor defines supported states, visual bounds, activation/hit regions and dashboard attachment point. Renderer never moves windows, reads credentials, or changes quota data. |
| Data provider | `fetch(scope, reason)` → `snapshot` | Scope identifies service/account/profile; snapshot contains arbitrary quota windows, history, provenance, observation time and typed availability/error. UsageService handles coalescing and cancellation. |

Every appearance receives the same **semantic context**: hidden/revealing/revealed/expanded/pinned/dragging phase; transition progress and elapsed time; dock edge and inward direction; local normalized pointer position, proximity, velocity and button/drag state; selected metric summaries; mood/urgency; freshness/auth/connectivity; motion preferences, scale, theme and frame budget. Explicit semantic events such as `greet`, `open`, `close`, and `quotaWarning` let an orb pulse while a pet waves.

Keep mood computation outside skins. A weekly 64% utilization reading alone does not prove danger; elapsed window time, other windows, and unavailable data matter. Missing/stale means unknown, not “happy/full.” If v1 does not monitor agent activity, do not animate “working” as a factual claim. A pet can express the same state with different art, but it must not invent different interaction rules.

**E. Six decisions before building, with my defaults**

1. **Relationship to CC Switch:** independent quota acquisition, optional CC Switch history/context. If zero credential/API access is a hard requirement, accept a dated Codex fallback and potentially unavailable Claude quota, or secure an upstream export first. The existing PRD cannot promise all three: live quotas, local-store-only reads, and no CC Switch changes.
2. **Reveal versus expand:** hover reveals companion plus a compact summary; click opens/pins the full dashboard; Escape/unpin dismisses. If the full dashboard must open on hover, specify dwell and a safe pointer corridor. “Retracts when pointer leaves” needs exceptions for reading, controls, drag and pinning.
3. **Display/full-screen policy:** one companion on a chosen display, remembers placement, falls back safely after disconnect; user-selectable full-screen visibility. Default to a side outer edge and avoid Dock/menu/notch conflicts. Do not spawn one pet per display or chase the pointer by default.
4. **Appearance scope:** one polished orb in v1; asset/geometry contract designed for a second sprite appearance. Defer Rive integration and downloadable skins until a real pet asset demonstrates the need. “Shape-shifting” does not require arbitrary morphing between unrelated meshes in v1.
5. **Account/metric scope:** one explicitly selected local profile per service initially; show every returned relevant quota window, source age and auth state. Historical tokens/cost are secondary, clearly labeled. Defer cross-machine and managed multi-account aggregation.
6. **Distribution/performance target:** Developer ID signed/notarized direct distribution, macOS 15+ as a proposed baseline, menu-bar recovery, no Dock icon by default. Sandboxing/shared tool files and Keychain access need a separate feasibility check if App Store distribution is desired. Require no app focus theft, real click-through outside shape, explicit stale states, smooth interaction and stopped hidden rendering before adding skins.

Bluntly: the PRD is an appealing vision, not yet a buildable specification. Replace “aesthetic excellence” with an approved visual/motion reference, define the three interaction states and their triggers, define freshness/account truth, and define measurable power/windowing acceptance criteria. The first engineering validation should prove data access and the native window/input behavior across full-screen Spaces, Stage Manager, mixed-DPI displays and sleep/wake. A beautiful orb cannot compensate for stealing clicks or confidently showing someone else’s quota.

## Round 2

**1. Claude statusline — agree; I missed this source and revise my default.** Locally, `~/.claude/statusline-command.sh:44–45` reads `.rate_limits.five_hour.used_percentage` and `.rate_limits.seven_day.used_percentage`; `settings.json` references that script. Installed package metadata reports Claude Code **2.1.316**. Official docs confirm each window has `used_percentage` (0–100) and `resets_at` (**Unix seconds**). Windows are independently optional, subscription data arrives after the first API response, and expired windows are dropped. [Claude Code statusline documentation](https://code.claude.com/docs/en/statusline#available-data).

Make the tap the default; OAuth is opt-in for live refresh while idle. One qualification: the tap does not intrinsically exclude Desktop/web usage; it exposes whatever account quota Claude Code last learned, without independently tracking those clients. A statusline rerun can follow UI changes or a refresh timer, so receipt time is not proof of a fresh server observation. The documented window shape has no observation timestamp. [Update triggers](https://code.claude.com/docs/en/statusline#when-the-status-line-updates).

I disagree with shipping a literal raw-JSON `tee` as the integration: project/transcript metadata is unnecessary, concurrent sessions can race, and overwrites expose partial reads. Prefer a tiny allowlisted, atomic snapshot per bound profile/session, preserving existing statusline output and tolerating write failure. Keep receipt time separate from known source-observation time; repeated payloads do not prove freshness. Countdown can advance locally to the recorded reset; afterward mark the window expired/unknown, never assume a refreshed allowance. No statusline edits were made here.

**2. Codex passive-first — agree; app-server is not side-effect-free.** Use the account-bound rollout observation by default, with optional live refresh. Locally installed npm package is **0.166.0**. Official OpenAI documentation says managed ChatGPT auth persists tokens and refreshes automatically; `account/read` also has an explicit forced-refresh option. Thus an app-server helper must be treated as capable of credential writes, including `CODEX_HOME/auth.json` with file storage, or Keychain with that storage backend. [App-server auth](https://learn.chatgpt.com/docs/app-server), [credential storage](https://learn.chatgpt.com/docs/auth#credential-storage).

I would allow an age-gated refresh on reveal **after live refresh is enabled**, through one coalesced, lazily started stdio helper with an idle timeout—not a process spawn for every hover. Do not force refresh or perform login/logout. `refreshToken:false` on `account/read` is not a documented process-wide read-only guarantee. I did not launch a server or trace this installed build’s exact quota-read refresh path, so “this particular read will rewrite auth.json” remains unverified; “guaranteed zero writes” is unsupported. Keep the passive path usable without the helper.

**3. Three concerns — agree, no objection.** My five were ownership boundaries, not a requirement for five packages. Engine may contain WindowHost and interaction-state files; Appearance and Data remain separate concerns; Dashboard is shared and non-skinnable. Preserve the internal seam between deterministic interaction decisions and AppKit effects. Skins own expressive animation, while Engine owns reveal/hide timing and placement.

**4. Interaction timings — agree as initial tuning values, not validated numbers.** Use 600 ms of uninterrupted hover within the revealed companion to open the dashboard, and 400 ms exit grace. Cancel pending dwell on departure or drag. Start exit grace only outside the union of companion, dashboard and travel corridor; freeze retraction while pinned, dragging, or a menu is open. Define click unambiguously: a companion click opens and pins immediately; a later companion click unpins. Dwell opens without pinning. Dashboard control clicks do not toggle pinning. Add Escape dismissal and a keyboard/menu-bar access route. These rules matter more than whether dwell ends up 500 or 600 ms.

**5. Pace mood — disagree as a reliable urgency rule; agree as an optional heuristic.** For a confirmed fixed-duration window, use utilization as a fraction: `pace = (usedPercent / 100) / elapsedFraction`, with inferred start `reset − duration`. Claude’s two named windows provide nominal durations; Codex requires its actual `window_minutes`—the observed primary was 10,080 minutes, not five hours. A truly sliding/replenishing window cannot generally be modeled this way from one reset timestamp.

The traps are near-zero elapsed time, bursty sessions, weekly sleep/weekend time, stale observations, clock jumps, quota adjustments and differing model scopes. Even 1% used just after reset can produce “urgent”; 95% used seconds before reset need not justify alarm. The ratio measures cumulative consumption against a uniform schedule, not current burn rate or a vendor prediction.

For v1, make low headroom plus time-to-reset the main mood inputs; pace may add a mild alert only after a meaningful elapsed interval, with hysteresis. Evaluate windows separately, take the strongest applicable signal, and let unknown freshness dominate. Never advance the denominator against an aging utilization sample to make the companion look calmer. Sleepy-grey for stale/unknown is fine, with an explicit “last seen”/unknown label in the dashboard.

## Round 3

Inspected the shallow checkout `./cc-switch-src`, tag **v4.0.24**, commit **c0189078aacdd80fd2462f59b345f55f62b41cf2**. Below, Rust paths are relative to `cc-switch-src/src-tauri/src/`; `src/...` paths are relative to `cc-switch-src/`. No quota requests, credential refreshes, or secret-value output were performed.

**1. Credential sources — reusing the logic is reasonable; “CC Switch files only, no Keychain” is wrong as a general claim.**

| Query path | Actual credential source | Evidence |
|---|---|---|
| Claude official, unbound | Keychain service `Claude Code-credentials`, then `<Claude config dir>/.credentials.json` (normally `~/.claude/.credentials.json`). Parses `claudeAiOauth` or `claude.ai_oauth`, then `accessToken`, `expiresAt`, `refreshToken`, `refreshTokenExpiresAt`. Not provider `settings_config`. | `services/subscription.rs:120–151,172–180,230–248,266–269,1744` |
| Claude official, managed account | Resolve the account’s current credential slot: default slot if currently live; otherwise `~/.cc-switch/claude-accounts/<localId>/config`. On macOS read the corresponding Keychain item; use that slot’s `.credentials.json` only when the item is missing. Account service is `Claude Code-credentials-<first 8 hex of SHA256(config-dir string)>`. CC Switch explicitly does not save a separate credential copy. | `services/claude_account/snapshot/mod.rs:114–131`; `snapshot/store.rs:1–7,63–72,123–147`; `snapshot/store/keychain.rs:33–50`; `layout.rs:122–129` (all under `services/claude_account/`) |
| Codex official, unbound | Keychain service `Codex Auth`, account `cli\|<first 16 hex SHA256(canonical Codex home)>`, then `<Codex home>/auth.json`. Requires ChatGPT OAuth mode; parses `tokens.access_token`, `tokens.account_id`, `last_refresh`. | `services/subscription.rs:626–635,647–725,781–845` |
| Codex managed | `~/.cc-switch/codex_oauth_auth.json` stores accounts and refresh credentials. `get_codex_oauth_quota` calls `manager.get_valid_token_for_account`, which uses an **in-memory access-token cache** or refreshes. It does not simply read a persisted access token. | `commands/codex_oauth.rs:28–87`; `proxy/providers/codex_oauth_auth.rs:266–288,350–403,790–797,866–888` |

On this machine: `Claude Official` has no `authBinding`; `~/.cc-switch/claude_accounts.json` and `~/.claude/.credentials.json` are absent. The managed Codex store has **three accounts; none has an `access_token` field**. `codex_managed_oauth_live_auth.json` is an identity marker (`account_id`, `chatgpt_account_id`, `user_identity`, `version`), not an auth bundle. So there is no demonstrated CC Switch-file-only route to fresh quotas for all these accounts.

**Important correction to my earlier review:** Claude Code’s `~/.claude.json` has `cachedUsageUtilization: {fetchedAtMs, accountUuid, utilization}`. CC Switch reads this after its CLI refresh fallback; the cache exists here and its account matches the current profile. This is a useful credential-free passive source with a real capture timestamp, stronger than statusline receipt time. Managed profiles use their slot’s `.claude.json`; honor legacy `.config.json` and default-slot movement. It is Claude Code’s cache, not a CC Switch credential export. Evidence: `services/claude_account/usage.rs:38–54`; `snapshot/store.rs:50–60`; `services/subscription.rs:1667–1689,1719–1733`.

Other Auth Center types do not share one storage model:

- **GitHub Copilot:** `copilot_auth.json`, `accounts[*].github_token`; quota query uses that GitHub token directly, not the short-lived inference token. `proxy/providers/copilot_auth.rs:519–548,582,1107–1128`.
- **xAI:** `xai_oauth_auth.json`, persisted `refresh_token`; access tokens are in memory, refreshed and rotated credentials persisted. `proxy/providers/xai_oauth_auth.rs:134–143,193–211,606–648`.
- **Antigravity:** `agy_accounts.json`, `accounts[*].credential` preserves the native credential JSON, including `/token/access_token` and `/token/refresh_token`. The manager also absorbs the active native Keychain login and refreshes its file copy. `services/agy_account/mod.rs:33–65,434–480,534`; `oauth.rs:329–347`.
- **Kimi:** `kimi_accounts.json` is identity metadata; auth lives in the native Kimi home (normally `~/.kimi-code`), `credentials/<oauth.key minus oauth/>.json`. Non-file/keyring references are rejected by this reader. `services/kimi_oauth/account.rs:25–55,246–295`; `services/kimi_oauth/mod.rs:170–191`; `kimi_config.rs:93`.
- **DeepSeek Harness:** native `$DSH_HOME/.credentials.yaml`, record `records["deepseek-account-platform/default"].payload.{token,issuer}`, for profile/balance queries. Not a CC Switch auth export. `services/dsh_account.rs:1–13`.

The exact managed-provider union is `github_copilot | codex_oauth | xai_oauth | agy_oauth | claude_official`; Kimi and DSH are additional Auth Center targets (`src/lib/api/auth.ts:3–19`). The separate unbound Gemini subscription path also uses native Keychain/file credentials (`services/subscription.rs:1145–1274`).

**2. Refresh — keep one refresh owner; do not turn the companion into a second CC Switch token manager.**

- **Managed Codex:** yes, CC Switch refreshes and writes back rotated `refresh_token`, `id_token`, and `token_updated_at_ms`; keeps access tokens in memory; can synchronize the corresponding managed live Codex auth. It has per-account locks, generation checks, and explicit recovery for CLI-rotated credentials. Evidence: `proxy/providers/codex_oauth_auth.rs:748–785,894–912,975–1055,1286–1370`. Permanent rejection includes `invalid_grant`, `refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated` (`:2136–2152`). An independent refresher can advance the token chain behind CC Switch’s in-memory copy; atomic file replacement alone does not coordinate that chain.
- **Claude:** CC Switch does **not** implement the OAuth refresh exchange itself. For managed accounts with expired/rejected access credentials, it invokes `claude -p /usage` in the appropriate slot; Claude Code owns refresh and writes its credentials/cache. Switching accounts also moves credential slots. Evidence: `services/subscription.rs:1618–1689`; `services/claude_account/usage.rs:1–5,91–143`. The unbound direct query has no equivalent CLI fallback (`services/subscription.rs:1744`).
- xAI persists rotated refresh tokens; Antigravity refreshes/persists its copy; Kimi uses its native refresh lock and writes the credential file (`xai_oauth_auth.rs:606–648`; `agy_account/mod.rs:460–480`; `kimi_oauth/account.rs:246–319`, under their paths above).

**Recommendation:** consume passive snapshots/caches or an available valid access token, never refresh or write someone else’s credential store. On expiration, reread once to detect owner rotation, then show “waiting for credential renewal” and retain only explicitly dated last-known metrics. Offer refresh through the owning tool/CC Switch. For fresh quotas across *all* managed Codex accounts, a read-access-token-only policy cannot work with the existing store: obtain a sanitized quota-export/IPC from CC Switch, or deliberately build a separately authenticated integration. Do not silently switch active accounts to expose their tokens.

**3. Multi-account model and parsed quota fields**

**Claude:** `claude_accounts.json` is `{version, accounts}` keyed by `accountUuid:organizationUuid` (identity helper permits absent organization). Each record has camelCase `localId`, optional `email`, `orgName`, `plan`, `rateLimitTier`, and `addedAt`. Labels prefer email, then organization, then a shortened key. There is no Codex-style `default_account_id`: current/default identity comes from the default slot’s profile; inactive accounts have their own slots. Evidence: `services/claude_account/mod.rs:1–12,33–93`; `identity.rs:45–60`; `snapshot/mod.rs:114–131`.

**Codex:** `{version, accounts, default_account_id}`; local account IDs are stable UUIDs, distinct from upstream `chatgpt_account_id` (workspace ID). Account records: `account_id`, `chatgpt_account_id?`, `email?`, `refresh_token`, `authenticated_at`, `id_token?`, `token_updated_at_ms`. Labels use email or `ChatGPT (<workspace/id>)`. Explicit account wins; otherwise manager default. Provider bindings use `meta.authBinding.{source:"managed_account",authProvider,accountId}`. Evidence: `proxy/providers/codex_oauth_auth.rs:266–358,1707`; `commands/codex_oauth.rs:36–45`; `src/lib/authBinding.ts:3–20`.

**Vendor response fields actually parsed:**

- **Claude legacy windows:** `five_hour`, `seven_day`, `seven_day_fable`, `seven_day_opus`, `seven_day_sonnet`, each `{utilization?, resets_at?}`; unknown top-level objects with the same shape are retained. Scoped rows are `limits[]` with `kind="weekly_scoped"`, `group="weekly"`, absent/null `scope.surface`, `scope.model.display_name` matching Fable/Opus/Sonnet, and `{percent, resets_at?}`. Scoped values override legacy counterparts; duplicates/invalid rows are skipped. It deliberately does **not** filter by `is_active`; 0% and null reset can be valid. `extra_usage` parses `{is_enabled?, monthly_limit?, used_credits?, utilization?, currency?}`. `services/subscription.rs:374–395,432–438,502–605`.
- **Codex:** `rate_limit.{primary_window?,secondary_window?}`, each `{used_percent?,limit_window_seconds?,reset_at?}`. Duration maps to `five_hour`, `seven_day`, `30_day`, or another duration-derived name; missing windows remain absent. A raw 0% causes reset suppression because the vendor may return a placeholder reset. `credits` parses `{has_credits,unlimited,balance}` (balance string or number). A separate reset-credit request parses `credits[].{status,expires_at}`, keeping available/nonexpired entries. **This version does not parse additional/model-specific Codex quota buckets.** Evidence: `services/subscription.rs:865–918,938–995,1077–1116`.

Normalized response is camelCase `{tool, credentialStatus, credentialMessage, success, tiers:[{name,utilization,resetsAt,...}], extraUsage, resetCredits?, creditsBalance?, error, queriedAt}`; Claude managed results may add `plan`. Account identity must remain attached externally—the normalized quota body itself has no account ID. `services/subscription.rs:27–82,1693–1700`.

**4. Exact history scope set and queries**

Clicking the usage estimate should open a scope picker. Keep its history scope separate from the quota account/window picker: historical `providerName` is not necessarily an account identity, and no history selection changes the vendor’s quota window.

| Preset | English label / i18n key | Actual meaning |
|---|---|---|
| `today` | `Today` / `usage.presetToday` | Local midnight → now |
| `1d` | `Last 24 hours` / `usage.preset1d` | Exactly preceding 86,400 seconds |
| `7d` | `Last 7 days` / `usage.preset7d` | Local midnight six calendar days ago → now |
| `14d` | `Last 14 days` / `usage.preset14d` | Local midnight thirteen calendar days ago → now |
| `30d` | `Last 30 days` / `usage.preset30d` | Local midnight twenty-nine calendar days ago → now |
| `all` | `All` / `usage.presetAll` | Epoch 0 → now |
| `custom` | `Calendar Filter` / `usage.customRange` | Date/time bounds, optional `liveEndTime` |

Verbatim preset/label evidence: `src/types/usage.ts:190–205`; `src/i18n/locales/en.json:2232–2237,2358`; calendar/DST semantics: `src/lib/usageRange.ts:15–66`. Compact tray uses only `["today","7d","30d","all"]` (`src/tray-panel/UsageTab.tsx:35`).

Global dimensions: `appType`, `providerName`, `model`, each with “all”. Known app set verbatim: `claude, codex, gemini, grokbuild, opencode, pi, omp, mcode, kimi, dsh, agy`; visibility settings trim UI choices. Provider/model choices come from data, in a cascading menu; request logs additionally filter `statusCode`. Evidence: `src/types/usage.ts:166–177,239–251`; `src/components/usage/UsageDashboard.tsx:276–281,345–362,563–570,638–702`.

Commands: `get_usage_summary(start_date,end_date,app_type,provider_name,model)`; `get_usage_summary_by_app` (no app filter); `get_usage_trends` → `get_daily_trends`; `get_usage_first_date`; `get_provider_stats`; `get_model_stats`; `get_request_logs(filters,page,page_size)`. `get_session_usage_summary(app_type,session_id)` is a separate session-view query. Evidence: `commands/usage.rs:24–170`; `src/lib/api/usage.ts:53–157`.

The actual summary SQL **adds** aggregates from both tables: `COUNT(*)`/`SUM(CAST(l.total_cost_usd AS REAL))` from `proxy_request_logs`, plus `SUM(r.request_count)`/`SUM(CAST(r.total_cost_usd AS REAL))` from `usage_daily_rollups`; tokens/successes follow the same pattern (`services/usage_stats.rs:1031–1058`). This is valid because compaction aggregates then deletes old detail rows (`database/dao/usage_rollup.rs:59–60,173–178`). My earlier caution is resolved: reproducing its combined query is correct.

Parity requires its effective-log deduplication, fresh-input/cache semantics, inclusive timestamp filters, provider-name mapping/join on `(provider_id,app_type)`, model expression `COALESCE(NULLIF(pricing_model,''),model)`, and app folding of `claude-desktop` into `claude`. Archived rollups count only fully covered local days; historical partial-day detail cannot be reconstructed from them. Evidence: `services/usage_stats.rs:432–480,482–595,868–928,956–1026`. Provider/model tables aggregate both tables too (`:1713–1832,1906–2030`).

**5. Headers, polling, and rate limiting**

- Claude usage: bearer auth, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, 15-second timeout; no explicit User-Agent in this request/shared base builder (`services/subscription.rs:445–454`; `proxy/http_client.rs:282–295`).
- Codex usage: bearer auth, **upstream workspace** `ChatGPT-Account-Id` (not local UUID), `User-Agent: codex-cli`, JSON Accept, 15-second timeout. Reset-credit request additionally uses `OpenAI-Beta: codex-1`, eight seconds. OAuth refresh uses `cc-switch-codex-oauth` UA and 30-second timeout (`services/subscription.rs:972–987,1028–1038`; `proxy/providers/codex_oauth_auth.rs:60–69,748–762`).
- Subscription hooks default to five minutes when auto-query is enabled, minimum one minute; shared account query keys deduplicate UI reads; `retry:1` covers rejected queries. Tray hover separately has a ten-second minimum interval. Claude CLI fallback is serialized and attempted at most once per account per ten minutes, including failures; its cache-age bound is ten minutes plus 45 seconds. `src/lib/query/subscription.ts:89–113,134–158`; `tray.rs:3168–3209`; `services/claude_account/usage.rs:17–28,59–72`.
- **Do not assume CC Switch has comprehensive 429 backoff:** direct quota HTTP errors become failure snapshots; frontend recognizes 429/5xx as transient and retains dated last-good data for ten minutes (`src/lib/query/queries.ts:121,159–184`). I found no Retry-After handling in the Claude/Codex quota functions. Add per-account request coalescing, Retry-After/exponential backoff with jitter, and pause on auth rejection; label these as companion improvements. Avoid background bursts over every saved account. Matching headers does not establish protection from throttling or account restrictions.

Proposed decision: retain passive sources, add Claude’s account-matched timestamped CLI cache, and treat “fresh all-account quotas through CC Switch” as requiring a proper CC Switch export/IPC. Copy its parsing and history semantics; do not independently copy its refresh ownership.
