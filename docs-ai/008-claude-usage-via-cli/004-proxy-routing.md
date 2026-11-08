# 008.004 — Proxy routing and truthful refresh status

## Context
On 2026-11-08, replaying Claude Code 2.1.319 with the running Tidemark GUI environment
returned exit 0 but did not update its usage cache. Adding only the terminal's HTTP
proxy variables updated the account-matched cache immediately. macOS had a system
HTTP/HTTPS proxy, which the CLI did not inherit. Unauthenticated endpoint probes
returned HTTP 403 directly and HTTP 401 through the proxy.

The original comparison was incomplete: CC Switch v4.0.26 (and the cited `e1f8acf`
revision) queries HTTP with credentials first and uses the CLI for expired credentials.
Its CLI fallback also passes its configured HTTP proxy. Tidemark intentionally keeps
Claude credential access delegated to Claude Code; restoring Keychain reads is not
required to fix routing.

## Change
- Share proxy selection across the Claude subprocess, Codex quota GET, and managed
  Codex OAuth POST. Prefer CC Switch's explicit global proxy, then environment
  proxies, then current macOS proxy settings. Read CC Switch settings read-only.
- Preserve explicit bypasses and reject malformed or unsupported explicit proxy
  configurations instead of silently sending the request directly. Reevaluate on
  each request so network and proxy changes do not require restarting Tidemark.
- Translate system HTTP proxies to Claude's environment. Native URLSession retains
  system PAC support; a CLI route requiring PAC or SOCKS reports an unsupported
  proxy rather than going direct. No new proxy credential store is introduced.
- Keep account matching, the 60-second Claude cache check, and Tidemark's existing
  request gates. These are Tidemark policies, not a copy of CC Switch's 10-minute
  fallback cache and invocation limits.
- Clear the full set of Claude authentication/backend selectors. Preserve a nonzero
  CLI exit status, keep raw output discarded, use a network-neutral error message,
  and label the dashboard completion time “Checked” rather than “Updated”.

## Validation
- `make test`: 66 tests passed (8 Engine, 58 Data). Six new proxy tests cover
  precedence and bypasses for quota and renewal, GUI environment injection and
  authentication-selector clearing, invalid/SOCKS/PAC handling, live settings changes,
  actual CONNECT requests to both vendor hosts through a local rejecting proxy
  (quota GET and OAuth POST), and preservation of a nonzero CLI exit status.
- `make build`: passed. `make run`: passed; Xcode reported both arm64 and x86_64
  matching destinations and selected the first (arm64).
- A temporary runtime probe compiled the actual TidemarkData sources, removed shell
  proxy variables while preserving the login environment, and ran the revised Claude
  command. The matching cache refreshed successfully. Native unauthenticated probes
  returned HTTP 401 for the Codex quota host and HTTP 400 for the OAuth POST host.
  An explicit unreachable proxy produced URL error -1004 instead of an origin response.
- The rebuilt GUI app launched through LaunchServices without proxy environment
  variables. Its Claude cache refreshed immediately; the dashboard accessibility
  state showed 28% five-hour / 6% weekly, “Cache · just now”, no Claude refresh error,
  fresh Codex live readings, and “Checked just now”. The verified no-proxy-environment
  process started at 23:49:41 local time and Claude's matching cache was captured at
  23:49:43.214. The first app relaunch had inherited terminal proxy variables; it
  was repeated with those removed before accepting this result. No visual screenshot inspection
  or post-token-expiry prompt validation was performed.
- `git diff --check` passed. Touched-file Swift format lint completed with existing
  documentation-comment warnings in older code; new-file warnings were corrected.

Validation corrections: initial compile checks exposed a misplaced error mapping
and Swift CFString switch-pattern conversion errors; both were corrected. An initial
no-failover test used a loopback origin and failed because macOS bypasses its proxy
for loopback destinations. It was removed: the actual fixed usage hosts are public
DNS names, covered by CONNECT tests and the unreachable-proxy live probe. An initial
runtime probe also omitted login environment variables and exited 0 without updating
the cache; preserving the login environment while removing only proxy variables
produced the successful result above.

## Current state
Implemented; uncommitted. Claude credentials still belong to Claude Code. All live
usage network entry points were checked: Claude's subprocess, Codex quota GET, and
managed Codex OAuth POST. Local history and snapshot readers do not query the network.

## Limits
- Native URLSession keeps system PAC evaluation and supports SOCKSv5. Claude Code
  accepts HTTP(S) proxies; PAC/SOCKS-only routes report `proxyUnavailable`. No runtime
  PAC, authenticated-proxy, or SOCKS handshake verification was performed.
- Direct routes remain valid when no proxy is configured or the destination matches
  an explicit bypass. PAC may intentionally choose DIRECT. Proxy failure is not
  interpreted as permission to retry the fixed vendor hosts directly.
- The observed loopback bypass is a native networking behavior, not evidence of a
  vendor-host fallback. Tidemark does not expose arbitrary usage endpoint URLs.

## Refs
- `Packages/TidemarkKit/Sources/TidemarkData/UsageProxy.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/ClaudeUsageCommand.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageProxyTests.swift`
- [CC Switch v4.0.26 CLI proxy bridge](https://github.com/farion1231/cc-switch/blob/v4.0.26/src-tauri/src/services/claude_account/login.rs#L480)
- [Apple proxy configurations](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/proxyconfigurations)
- [Apple direct failover policy](https://developer.apple.com/documentation/network/proxyconfiguration/allowfailover)
