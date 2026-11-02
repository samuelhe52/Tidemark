# Tidemark companion design

Living contract for entry [001](000-plan.md). Update it in place when a decision
changes, and note the change in a dated amendment. Code blocks are sketches, not
source; the types they name are proposed. `Engine`, `Appearance`, and `Data` mean
the `TidemarkEngine`, `TidemarkAppearance`, and `TidemarkData` targets in
`Packages/TidemarkKit`.

Facts about other tools refer to CC Switch 4.0.24 (commit `c0189078`), Claude Code,
and Codex as inspected on 2026-11-02. Their formats can change without notice.

## 1. Rest at the edge

The companion rests at a screen edge as a thin glow: a 4 px pill, not the orb.
An 8 px hover strip around it is the only area that takes the pointer.

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
  reconciles a still pointer. While hidden, only the 8 px strip listens.
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

- **hidden:** the glow only; nothing renders.
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

- These are starting values to tune, not validated numbers.
- The dwell timer stops if the pointer leaves or a drag starts.
- The leave grace starts only outside the union of the orb, the panel, and the
  travel corridor between them.
- No retract while pinned, while dragging, or while a menu is open.
- A click on a panel control never changes the pin.

### 2.3 Motion and render budget

```swift
enum Motion {
  static let emerge  = Spring(response: 0.42, dampingRatio: 0.72) // slight overshoot
  static let expand  = Spring(response: 0.36, dampingRatio: 0.86)
  static let retract = Spring(response: 0.28, dampingRatio: 1.0)  // no bounce on exit
}
enum RenderBudget {
  case off           // hidden, asleep, screen locked: display link stopped
  case idle(fps: 30) // revealed, still pointer: breathe only
  case full          // transitions and drag: display max, 120 on ProMotion
}
```

- Nothing renders while hidden.
- Under Reduce Motion or Low Power Mode: no idle motion, and fades replace springs.

## 3. Dashboard

The panel shows, for each account, every quota window it reports: the percent left,
the reset time, and the source with its age (for example "statusline · 40 s ago").
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
| Codex | Live, opt-in | Keychain item `Codex Auth`, account `cli\|<first 16 hex of SHA-256(codex home)>`, falling back to `~/.codex/auth.json`; `https://chatgpt.com/backend-api/wham/usage` with `ChatGPT-Account-Id` (the upstream workspace ID) and `User-Agent: codex-cli` |
| Both | Last dated numbers only | CC Switch's other managed accounts |

- Live sources serve only the account the agent is logged in with. Tidemark never
  refreshes, rotates, or writes another tool's credentials; CC Switch owns refresh
  for its managed Codex accounts.
- Live requests coalesce per account and honor `Retry-After`, with exponential
  backoff and jitter. CC Switch does neither, so Tidemark must.
- Refresh triggers: a timer, reveal, and wake, coalesced in one usage service.
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
  `account_id` (a local UUID) and `chatgpt_account_id`. Windows are named by length:
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

Clicking the estimate changes its scope, using CC Switch's set:

- Time presets: `today`, `1d`, `7d`, `14d`, `30d`, `all`, `custom`. The compact
  picker shows `today`, `7d`, `30d`, `all`.
- Filters: app type, provider name, and model, each with "all".

The history scope is separate from the quota account picker.

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
