# Tidemark companion design

Living contract for entry [001](000-plan.md). Update it in place when a decision
changes, and note the change in a dated amendment. Code blocks are sketches, not
source; the types they name are proposed. `Engine`, `Appearance`, and `Data` mean
the `TidemarkEngine`, `TidemarkAppearance`, and `TidemarkData` targets in
`Packages/TidemarkKit`.

Facts about other tools refer to CC Switch 4.0.24 (commit `c0189078`), Claude Code,
and Codex as inspected on 2026-11-02. Their formats can change without notice.

Implementation checkpoint (2026-11-03): the first native companion and passive
quota path are implemented; see [004](004-first-companion.md). Entry
[002](../002-live-quota-native-surface/000-plan.md) replaced the SwiftUI surface with
AppKit views animated by Core Animation, added live requests, CC Switch's managed
Codex accounts and the last-good store. Entry [004](../004-usage-history/000-plan.md)
added CC Switch history (§3.6) with the compact range picker (§3.7); provider and
model filters are not implemented yet. Entry [005](../005-glass-dock-morph/000-plan.md)
replaced the edge glow with a docked glass tab that morphs into the orb. Entry
[006](../006-settings/000-plan.md) adds the settings window and configurable
interaction and quota presentation. Metal and manifest skins are not implemented yet.

## 1. Rest at the edge

The companion rests at a screen edge as a docked glass tab: a 16 × 48 pt Liquid
Glass capsule centered on the edge, so 8 pt shows. A 10 × 64 pt hover strip over it
is the only area that takes the pointer.

### 1.1 One panel, never focused

One panel floats above apps on all Spaces. It never takes focus, so typing stays
in the app below.

```swift
final class CompanionPanel: NSPanel {
  init() {
    super.init(contentRect: .zero,
               styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false            // the skin draws its own glow
    hidesOnDeactivate = false
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
```

- Settings opens in a separate ordinary, focusable window; the companion panel remains nonactivating.
- The companion **hides over full-screen apps**, so the panel does not use
  `.fullScreenAuxiliary`. Test on full-screen Spaces and Stage Manager.

### 1.2 Placement

The user drags the orb to an edge. The app keeps the display, edge, and position.

```swift
struct DockPlacement: Codable, Equatable {
  var displayUUID: String   // CGDisplayCreateUUIDFromDisplayID; survives replug
  var edge: Edge            // .left .right .top .bottom
  var along: Double         // 0…1 along the usable part of the edge
}
```

- On release, snap to the nearest **outer** edge of `visibleFrame`. An internal
  seam between two displays is not an edge.
- If the display is gone, use the main display with the same edge and `along`.
- The menu bar, Dock, and notch areas are excluded from `along`.

### 1.3 Clicks pass through

The window rect is larger than the shape; the shape decides what takes the pointer.

```swift
func pointerMoved(to p: CGPoint) {
  let inside = presentation.hitRegion.contains(p)      // from the skin + panel
  if panel.ignoresMouseEvents == inside {
    panel.ignoresMouseEvents = !inside
  }
  engine.send(.pointer(p), now: clock.now)
}
```

- Sources: global and local `.mouseMoved` monitors. While revealed, a 250 ms timer
  reconciles a still pointer. While hidden, only the hover strip listens.
- Global monitors are asynchronous; test a fast cross-and-click.

## 2. Hover lifecycle

| From | Event | To |
| --- | --- | --- |
| hidden | hover | revealed |
| revealed | leave | hidden |
| revealed | 600 ms dwell | expanded |
| revealed | click | pinned |
| expanded | leave | hidden |
| expanded | click | pinned |
| pinned | click on the orb, Esc | expanded |

- **hidden:** the docked glass tab only.
- **revealed:** the orb with a one-line summary, such as `Claude 5h 38% · Codex 7d 64%`.
- **expanded:** the full panel; it goes back when the pointer leaves.
- **pinned:** the full panel stays.

### 2.1 A pure engine

The engine turns events into one presentation state and does no I/O. Timers are
effects, not callbacks, so tests feed events and a fake clock.

```swift
enum Phase { case hidden, revealed, expanded, pinned, dragging }

enum EngineEvent {
  case pointer(CGPoint), click, escape
  case dragBegan, dragEnded(CGPoint)
  case deadline(Date), displaysChanged, wake
}

struct Presentation: Equatable {
  var phase: Phase
  var progress: Double        // 0 hidden … 1 out; springs drive it
  var anchor: CGPoint         // orb center, from DockPlacement
  var hitRegion: CGPath       // skin shape ∪ panel ∪ travel corridor
}

func reduce(_ s: inout EngineState, _ e: EngineEvent, now: Date) -> [Effect]
```

### 2.2 Timing

```swift
enum Timing {
  static let dwellToExpand = 0.600  // s; pointer stays inside the revealed orb
  static let leaveGrace    = 0.400  // s; starts only outside the hit union
}
```

- These are the defaults. Settings allows expansion and retraction delays from 0 to 3 seconds in 0.1-second steps. Click-only activation keeps the docked glass tab until clicked and skips hover reveal/expansion. Changing behavior reschedules pending deadlines; reset-position and sleep/wake preserve the saved behavior.
- The dwell timer stops if the pointer leaves or a drag starts.
- The leave grace starts only outside the union of the orb, the panel, and the
  travel corridor between them.
- No retract while pinned, while dragging, or while a menu is open.
- A click on a panel control never changes the pin.

### 2.3 Motion and render budget

Every transition animates only layer `transform` and `opacity`, so the render server
composites it. The one exception is the orb's glass body, whose frame springs between
the docked tab and the sphere; it resizes no window (see
[005](../005-glass-dock-morph/000-plan.md)). Springs start from the on-screen (presentation) value, so a reversal
mid-flight continues instead of jumping. The panel grows to its full frame before an
emerge and shrinks to the hover strip only after a retract settles.

```swift
extension MotionCurve {   // TidemarkAppearance/CompanionMotion.swift
  static let emerge  = MotionCurve(response: 0.42, bounce: 0.22) // slight overshoot
  static let expand  = MotionCurve(response: 0.36, bounce: 0.1)
  static let retract = MotionCurve(response: 0.26, bounce: 0)    // no bounce on exit
}
```

- Reveal morphs the docked tab into the sphere and retract morphs it back; a reversal
  mid-flight continues from the on-screen shape. The summary and dashboard scale from
  the point nearest the orb. Opacity eases rather than springs.
- While hidden, only the static tab renders. Idle breathing is a Core Animation loop
  that runs only while the orb is undocked.
- Under Reduce Motion or Low Power Mode: no idle motion, and short fades replace springs.
- Dashboard content changes (hiding or restoring accounts, quotas finishing loading)
  animate per row: stable rows move into place, entering and leaving rows fade, and
  the glass resizes without a crossfade. Reduce Motion and Low Power Mode use short
  fades.

## 3. Dashboard

The panel shows, for each visible account, every quota window it reports: the percent remaining (or used, as chosen in Settings),
the reset countdown (or local clock time, including the date on later days), and the source with its age (for example "statusline · 40 s ago").
Below the quotas, CC Switch history shows tokens and an estimated API-equivalent
cost, which is not a bill.

CC Switch keeps quota results in memory only; its database has history, not quota
windows. So quota comes from the agents' own files or the vendors' endpoints.

### 3.1 Quota sources

Passive sources are the default; they read files that the agents write and need no
credentials. Live sources are an opt-in setting.

| Service | Kind | Source |
| --- | --- | --- |
| Claude | Passive | `~/.claude.json` `cachedUsageUtilization {fetchedAtMs, accountUuid, utilization}`; `fetchedAtMs` is the capture time |
| Claude | Passive | The statusline tap (3.2) |
| Codex | Passive | Newest `token_count.rate_limits` in `$CODEX_HOME/sessions/**/rollout-*.jsonl` (3.3) |
| Claude | Live, opt-in | Keychain item `Claude Code-credentials`, falling back to `~/.claude/.credentials.json`; `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` |
| Codex | Live, opt-in | The store `cli_auth_credentials_store` in `$CODEX_HOME/config.toml` names: `auth.json` (default `file`), Keychain item `Codex Auth`, account `cli\|<first 16 hex of SHA-256(codex home)>` (`keyring`), or both (`auto`); `https://chatgpt.com/backend-api/wham/usage` with `ChatGPT-Account-Id` (the upstream workspace ID) and `User-Agent: codex-cli` |
| Codex managed accounts | Live, opt-in | CC Switch's `~/.cc-switch/codex_oauth_auth.json` v2; reuse each account's refresh token to obtain an access token and query `wham/usage`, independently of the active provider. See [003](../003-direct-multi-account-quota/000-plan.md). |

- Managed Codex accounts use their CC Switch local account IDs, so users in the
  same workspace remain distinct. The maintainer authorized reuse and renewal on
  2026-11-03. Tidemark caches access tokens only in memory and saves rotated refresh
  and ID tokens back to CC Switch, preserving unrelated fields and accounts.
  Native Codex auth and Claude credentials remain read-only.
- Tidemark rereads credentials before renewing and before saving, rejects detected
  generation changes, and locks its own renewal processes. The unmodified CC Switch
  desktop does not honor that lock and can retain a consumed refresh token in memory.
  Reuse therefore does not guarantee safe concurrent desktop refresh. An unsaved
  rotation is retained in memory for write-back retry; exiting before it is saved
  can still lose that rotation.
- Expired native access tokens are never sent. Managed Codex accounts can renew
  them; expired Claude sign-ins and rejected renewals report `credentialExpired`.
- Live requests are gated per account: at most every 5 minutes automatically, 20 s
  when the user refreshes, `Retry-After` on 429, otherwise exponential backoff from
  60 s to 30 min with ±20 % jitter. A user refresh never skips a backoff.
- Refresh triggers: a 60 s timer (passive files; the gate limits live requests),
  reveal, wake, and the refresh button, coalesced in `UsageService`.
- The Codex app-server (`account/rateLimits/read`) is not used: it can refresh
  tokens in `~/.codex/auth.json`.

### 3.2 The Claude statusline tap

An addition to the user's `~/.claude/statusline-command.sh`, after `input=$(cat)`.
Only `rate_limits` leave the script; its existing output is unchanged.

```sh
# Tidemark: keep only rate_limits; write atomically; never fail the statusline
snap="$HOME/Library/Application Support/Tidemark/claude-rate-limits.json"
printf '%s' "$input" | jq -ce 'select(.rate_limits) | {rate_limits, received_at: now}' \
  > "$snap.$$" 2>/dev/null && mv -f "$snap.$$" "$snap" || rm -f "$snap.$$"
```

- `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`; `resets_at` is
  Unix seconds. `jq -e` skips a payload without `rate_limits`.
- The tap reports what Claude Code last learned; it does not see Desktop or web use
  on its own.

### 3.3 The Codex rollout reader

```swift
/// Newest token_count.rate_limits in $CODEX_HOME/sessions/**/rollout-*.jsonl
func read() throws -> Observation? {
  let file = try newestRollout(under: codexHome / "sessions")   // by mtime
  for line in try file.reverseLines(limit: 400) {               // tail only
    guard line.contains("\"rate_limits\"") else { continue }
    let ev = try decoder.decode(TokenCountEvent.self, from: line)
    return Observation(
      service: .codex, source: .rollout, observedAt: ev.timestamp,
      windows: [ev.rateLimits.primary, ev.rateLimits.secondary]
        .compactMap { $0.map(QuotaWindow.init(codex:)) })      // keeps window_minutes
  }
  return nil
}
```

- **Never assume `primary` is the five-hour window.** An observed payload had
  `primary {used_percent: 64, window_minutes: 10080}`, `secondary: null`, and
  `plan_type: prolite`; its primary was weekly.

### 3.4 Accounts and windows

Several Claude and Codex accounts can be logged in, and each may or may not have a
five-hour limit. Every window is optional.

- Claude accounts are keyed `accountUuid:organizationUuid`, with `localId`, `email`,
  `orgName`, and `plan`. Windows: `five_hour`, `seven_day`, `seven_day_opus`,
  `seven_day_sonnet`, `seven_day_fable`, and `limits[]` rows with
  `kind = "weekly_scoped"`, which override the legacy windows.
- Codex accounts are `{version, accounts, default_account_id}`, each with
  `account_id` (a local UUID) and `chatgpt_account_id` (a workspace). Managed quota
  rows use `codex:managed:<localId>`; the workspace is an HTTP header, not a unique
  user. Old workspace-keyed snapshots migrate only for a uniquely mapped account
  with a matching stored email and no contradictory active identity.
  Windows are named by length:
  `limit_window_seconds` maps to `five_hour`, `seven_day`, or `30_day`.

### 3.5 Freshness

Old data shows its age. Unknown data never shows as full.

```swift
enum Freshness { case live, aging(TimeInterval), stale(TimeInterval), unknown }

func freshness(of w: QuotaWindow, now: Date) -> Freshness {
  guard let seen = w.observedAt else { return .unknown }
  if let reset = w.resetsAt, now >= reset { return .unknown }  // window rolled over
  let age = now.timeIntervalSince(seen)
  switch age {
  case ..<120:  return .live
  case ..<1800: return .aging(age)
  default:      return .stale(age)
  }
}
```

- After a reset passes, the window shows "refresh needed", never 100 % left.
- Stale windows retain their source age but display remaining quota as unknown.
  Future capture timestamps also yield unknown; missing percentages stay missing.
- The countdown runs locally from `resetsAt`; it needs no new data.

### 3.6 History from CC Switch

Tidemark opens `~/.cc-switch/cc-switch.db` read-only (`mode=ro`; the database uses
WAL) and follows CC Switch's own summary query in
`src-tauri/src/services/usage_stats.rs` (around lines 1031–1058):

- **Add** the `proxy_request_logs` totals and the `usage_daily_rollups` totals.
  CC Switch rolls detail rows older than 30 days into the daily table and deletes
  them, so neither table alone is complete.
- Take rollup rows only for whole local days the range fully covers.
- Filter detail rows with CC Switch's `effective_usage_log_filter`. Session-log rows
  (`session_log`, `codex_session`, …) can duplicate proxy rows, and summing both
  double-counts.
- Count input tokens with `fresh_input_sql` (`services/sql_helpers.rs`), which
  handles rows whose input total includes cache tokens.
- Fold `claude-desktop` into `claude`. The model is
  `COALESCE(NULLIF(pricing_model, ''), model)`.

### 3.7 History scope

A range pop-up beside the estimate changes its scope, using CC Switch's set:

- Time presets: `today`, `1d`, `7d`, `14d`, `30d`, `all`, `custom`. The compact
  picker shows `today`, `7d`, `14d`, `30d`, `all`.
- Views: a bar chart over the range (hours, days, or months; hovering a bar shows its
  tokens, cost and requests), per harness (app type), and per model. All three
  add up to the same total. See [004.002](../004-usage-history/002-views-and-14-day.md).
- Filters: app type, provider name, and model, each with "all".

The history scope is separate from account visibility, ordering, and compact-summary selection. History range/view and dock placement continue to be remembered automatically.

## 4. Appearance

The user can change the shape and the behavior; all skins use one contract. The
first version ships the orb and one sprite pet. The orb's art direction is open;
see [orb-concepts.html](orb-concepts.html).

### 4.1 One context for every skin

A skin draws only itself. It cannot move windows, read credentials, or change data.

```swift
protocol Appearance: AnyObject {
  var descriptor: SkinDescriptor { get }       // sizes, hit shape, panel anchor
  func makeView() -> NSView                    // CAMetalLayer, SKView or layers
  func update(_ ctx: AppearanceContext)        // every frame in the budget
  func handle(_ cue: Cue)                      // one-shot events
}

struct AppearanceContext {
  var phase: Phase; var progress: Double       // from the engine
  var edge: Edge; var inward: CGVector
  var pointer: CGPoint?; var proximity: Double // 0 far … 1 on the orb
  var freshness: Freshness                     // from the data layer
  var behavior: BehaviorProfile
  var reduceMotion: Bool; var time: TimeInterval
}

enum Cue { case greet, open, close, pinned, reset }
```

### 4.2 Skins are data

A skin is a folder with a manifest and assets. It runs no code.

```json
{
  "id": "pebble",
  "renderer": "sprite",
  "size": [72, 64], "hiddenShape": "pill",
  "hitShape": "hit.svg",
  "panelAnchor": [0.0, 0.5],
  "clips": {
    "idle":      { "sheet": "idle.png", "fps": 12, "loop": true },
    "cue.greet": { "sheet": "wave.png", "fps": 18 }
  }
}
```

- `renderer` is `orb-shader` or `sprite`; Rive may come later, once a real pet asset
  needs it.

### 4.3 Behavior presets

Presets (Shy, Calm, Curious) change timing and idle motion, not only color.

```swift
struct BehaviorProfile: Codable {
  var idle: IdleMotion          // .breathe(period: 4.5) | .drift | .still
  var emergeSpring: Spring      // Shy: stiff and quick; Curious: bouncy
  var leaveGrace: TimeInterval  // Shy 0.25 s … Calm 0.4 s … Curious 0.7 s
  var followPointer: Double     // 0…1 how much the orb leans toward the pointer
}
```

## 5. Shared usage snapshot

The panel and the skins read one snapshot. It is stored as the last good copy,
without secrets.

```swift
struct UsageSnapshot: Codable {
  var services: [ServiceUsage]       // one per service and account
  var history: [DailyUsage]          // from CC Switch; optional
}
struct ServiceUsage: Codable {
  var service: Service; var account: AccountLabel?  // label only, never a token
  var windows: [QuotaWindow]
  var error: SourceError?                           // .authNeeded .rateLimited .missing
}
struct QuotaWindow: Codable {
  var id: String                    // "five_hour", "seven_day", "seven_day_opus", …
  var usedPercent: Double?          // 0…100, vendor value
  var resetsAt: Date?
  var duration: TimeInterval?       // known or nominal
  var observedAt: Date?; var source: SourceKind
}
```

## 6. Out of scope

- Tidemark never writes CC Switch's database or switches providers, and never
  writes `~/.codex/auth.json`, `~/.claude`, or Keychain items.
- No agent activity tracking in the first version; the orb does not show "working".
- No orb mood (quota pressure shown through motion and color), and no pace
  heuristic. Deferred by the maintainer.
- No CC Switch export or IPC; no phone sync.
- From Codenotch, keep the non-activating panel, the pin, and the dated last good
  data; drop its provider list.
- Direct download, Developer ID signed and notarized, macOS 15 or later. No App Store.

## 7. Settings

The menu's **Settings…** action, the dashboard's gear button, and Command-comma (while Tidemark is active) open a toolbar-style settings window with General, Companion, Usage, and Accounts panes of grouped forms. Settings covers only the controls below; there are no appearance, history, refresh-frequency, or notification controls. See [006](../006-settings/000-plan.md).

- Launch at login reflects ServiceManagement's actual main-app registration status, reports errors, and links to Login Items when approval is needed. Opening settings never registers a login item.
- The optional global shortcut shows/hides the companion. The recorder requires Command, Control, or Option; Escape cancels and Delete clears. Recording suspends the previous shortcut, restores it on cancellation, and reports registration failures. No shortcut is assigned by default.
- Hover/click-only activation, expansion delay, retraction delay, and Reset Position are available in Companion. Click still pins; explicit shortcut dismissal stays hidden until the pointer leaves and reenters.
- Live Usage remains off by default. Its menu and settings controls share one persisted value; the dashboard has no Live Usage control or footer, and shows the last refresh age in its header. Existing credential ownership and request gates are unchanged.
- Account visibility is shared with inline dashboard hide/restore controls. Settings reorders accounts by dragging, with context-menu and accessibility move actions. The saved order applies globally, including interleaved providers; consecutive provider runs get separate headings with unique row identities. Unknown/new accounts append; temporarily absent accounts retain their saved slots.
- Compact summary is chosen per service: Automatic (the visible account in use, else the first visible one), one visible account of that service, or Off. Choosing an account affects only its service. A missing explicit selection shows that service as unknown instead of substituting another account. Hiding the selected account resets that service to Automatic.
- Remaining/used applies to labels, gauge progress, compact summary, tooltips, and accessibility descriptions. Reset countdown/clock applies to quota reset labels. Freshness rules remain fixed.
