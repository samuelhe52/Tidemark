# 008.004 — Proxy routing and truthful refresh status

## Context
On 2026-11-08, Live Claude usage in the Dock-launched app stayed stale with no error.
The Codex thread `01a1bbc4` investigated and reported the cause. It replayed Claude Code
2.1.319 with the GUI app's environment: the run exited 0 but left the usage cache
unchanged. Adding the terminal's HTTP proxy variables refreshed the account-matched
cache at once. A GUI app inherits no shell variables, and Claude Code (Node) does not read
macOS proxy settings. The thread also reported that unauthenticated probes returned HTTP
403 direct and HTTP 401 through the proxy.

The original CC Switch comparison in [000-plan.md](000-plan.md) was also incomplete. CC
Switch v4.0.26 queries HTTP with stored credentials first and uses the CLI only for
expired credentials. Its CLI path passes CC Switch's own global proxy as
`HTTPS_PROXY`/`HTTP_PROXY` (HTTP(S) only), and passes nothing for SOCKS
(`src-tauri/src/services/claude_account/login.rs`, `apply_global_proxy_env`, checked
by Claude Code against the v4.0.26 tag). Tidemark keeps Claude credentials delegated to
Claude Code. Restoring Keychain reads is not needed to fix routing.

## Change
The work landed in four commits:

| Commit | Change |
| --- | --- |
| `f1d8a45` | The Codex thread's fix: shared proxy routing (`UsageProxy`) for the Claude subprocess, the Codex quota GET, and the managed Codex OAuth POST. A new `proxyUnavailable` issue. A non-zero CLI exit is preserved. All Claude auth and backend selectors are cleared. A network-neutral `requestFailed` message for Claude, and the dashboard header reads "Checked" instead of "Updated". |
| `f34bc57` | Proxy variables come from the user's shell, not CC Switch. |
| `88584c7` | Claude Code skips a SOCKS proxy it cannot use. |
| `21433a3` | A Claude Code error exit is its own issue, `cliFailed`. |

Current routing, by source and in this order:

1. **Tidemark's own environment**, when it names a proxy (`http_proxy`, `https_proxy` or
   `all_proxy`, either case). This happens when Tidemark is started from a terminal. A
   lone `NO_PROXY` does not count.
2. **Otherwise, the user's interactive login shell.** `$SHELL -l -i -c` writes
   `/usr/bin/env -0` to a 0600 temporary file that is deleted right after it is read.
   Only the proxy variables are kept. Proxy variables inherited by the shell are removed
   first, so only what the startup files set counts. The result is cached for five
   minutes, and concurrent requests share one shell run (`ShellProxyVariables`). A shell
   that fails or takes longer than 10 s gives no variables.
3. **Otherwise, the current macOS proxy settings** (`CFNetworkCopyProxiesForURL`). For
   native requests these include PAC and exceptions.

Native requests (Codex quota and OAuth renewal) use `<scheme>_proxy`, then `all_proxy`,
then the system route. They support HTTP(S) and SOCKSv5 with failover disabled.
`NO_PROXY` is honored. A malformed proxy value fails the request rather than going
direct.

For the Claude subprocess, all inherited proxy variables are replaced. Each scheme takes
the first HTTP(S) proxy among `<scheme>_proxy` and `all_proxy`. A SOCKS value there is
skipped, because Claude Code ignores it in a terminal too. Then the system route applies.
`NO_PROXY` comes from the source that set the HTTPS route: the variables' `no_proxy`, or
the system exception list. A malformed variable, or a system route that is SOCKS-only or
PAC, reports `proxyUnavailable`.

A non-zero `claude` exit now reports `cliFailed`: "Claude Code exited with an error. Check
that it runs in Terminal." A separate message is needed because signed out, `claude -p
/usage` exits 0 with no cache (Claude Code checked this with an empty `CLAUDE_CONFIG_DIR`
on 2026-11-09), so an error exit means the CLI itself failed, not the sign-in. A
signed-out account is already caught earlier as `signedOut`.

Rejected options:
- **CC Switch's `settings.global_proxy_url` as the first source** (in `f1d8a45`). The
  maintainer ruled that Tidemark reads CC Switch only where a feature requires it, and
  routing does not. Reading the database also made every live read fail when
  `cc-switch.db` lacked a `settings` table or stayed locked past the busy timeout.
- **Reading the shell on every request.** A login shell takes about 0.5 s on the
  maintainer's machine, and requests can run per account. Five minutes keeps edits to
  `.zshrc` effective without a restart.

Kept unchanged: account matching, the 60-second Claude cache check, and Tidemark's
request gates. CC Switch's 10-minute limits belong to its fallback flow, not to this
design.

## Validation
Run by Claude Code, on 2026-11-08 and 2026-11-09:
- `make test` after `f1d8a45`: 58 Data tests passed. `make build` passed.
- `swift test --package-path Packages/TidemarkKit` after `21433a3`: 63 Data tests and 8
  Engine tests passed. `make build` passed after each commit.
- Tests cover:
  - variable precedence, bypasses, and the system fallback for both native hosts;
  - own-environment selection;
  - the login-shell read, with startup output ignored, non-proxy variables dropped, and
    one run shared by concurrent and later calls;
  - a failing shell;
  - the Claude environment from the system proxy, with selectors and `ALL_PROXY` cleared;
  - SOCKS fall-through and its failure cases;
  - invalid values and PAC;
  - CONNECT through a local proxy for both vendor hosts;
  - the error exit preserved and mapped to `cliFailed`.
- The exact shell command, run against the maintainer's real `zsh` with proxy variables
  unset, returned `https_proxy`/`http_proxy` (HTTP) and `all_proxy` (SOCKS) in about 0.5 s.

Reported by the Codex thread for `f1d8a45`, not reproduced by Claude Code:
- A runtime probe of the revised command refreshed the matching cache.
- The rebuilt GUI app, launched without proxy variables, refreshed Claude's cache and
  showed fresh readings with "Checked just now".
- An explicit unreachable proxy produced URL error -1004 instead of a direct response.

## Current state
Implemented and committed. No runtime GUI check has been run since `f34bc57`, so the
login-shell source has not been seen working in the Dock-launched app.

## Limits and open questions
- A PAC-only or SOCKS-only system proxy still blocks the Claude run. Evaluating the PAC
  file for `api.anthropic.com` (`CFNetworkExecuteProxyAutoConfigurationURL`) was
  identified but not done.
- The login shell runs startup files on each read (at most every five minutes). Before
  this change, startup files ran only once, for locating `claude`.
- PAC, authenticated proxies, and SOCKS handshakes have no runtime verification.

## Refs
- `Packages/TidemarkKit/Sources/TidemarkData/UsageProxy.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/ClaudeUsageCommand.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageProxyTests.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`
- [CC Switch v4.0.26 CLI proxy bridge](https://github.com/farion1231/cc-switch/blob/v4.0.26/src-tauri/src/services/claude_account/login.rs#L480)
