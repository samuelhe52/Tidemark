# 008 — Live Claude usage through Claude Code: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-07 | Verified CC Switch's `claude -p /usage` approach against upstream source and the installed Claude Code 2.1.319 | Plan background |
| 2026-11-07 | Replaced the Claude Keychain read and `api/oauth/usage` request with the Claude Code run | `e3d0e2c` |

## Outcome and current state (as of 2026-11-07)

- With Live Usage on, `UsageService.liveClaude` asks `environment.claudeUsage` to run,
  under the same per-account `LiveRequestGate` as before. It then rereads
  `~/.claude.json` and accepts the cache as an observation only if both
  `oauthAccount.accountUuid` and the cache's `accountUuid` match the signed-in account
  and `fetchedAtMs` is under 60 s old when the run ends (see [002](002-cache-freshness.md)). Anything else counts
  as a gate failure with backoff.
- `ClaudeCLIUsageCommand` finds `claude` in known install paths, or else through an
  interactive login-shell `command -v claude` whose answer is kept while it stays
  executable (see [003](003-run-hardening.md)). It runs with CC Switch's arguments,
  cwd `~`, discarded stdio, and a 45 s timeout (terminate, then `SIGKILL`). Before
  running, it strips `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  the Anthropic key/token/base-URL variables, and the inherited Claude Code session
  and Bedrock/Vertex variables, and sets `CLAUDE_CODE_DISABLE_AUTO_MEMORY`,
  `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING` and `DISABLE_AUTOUPDATER` to 1. It
  prefixes `PATH` with the executable's directory, its resolved directory, and the
  Homebrew and `/usr/local` bin directories.
- New issue `QuotaReadIssue.cliUnavailable`. For Claude, `requestFailed` now reads
  "Claude Code couldn't refresh usage. Open it to check the sign-in."
- The Claude plan comes from `oauthAccount.organizationType` without its `claude_`
  prefix, and is attached to the passive cache reading as well.
- Removed: `claudeCredential()`, the Claude branch of the usage request and parser
  (`QuotaParser.claudeUsage`), and `UsageEnvironment.claudeCredentialsFile`. The
  Keychain refusal memory is now Codex-only (`codexKeychainRefused`).

Key files:

- `Packages/TidemarkKit/Sources/TidemarkData/ClaudeUsageCommand.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/LocalSources.swift`
- `Sources/Tidemark/QuotaText.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`
- `docs-ai/001-companion-foundation/design.md` (3.1 and 6)

## Deviations from plan

- The accepted reading keeps the `claudeCache` source, so the dashboard labels it
  "Cache" with its age, not "Live". The windows are Claude Code's own cache, so this
  label is accurate; the plan's runtime criterion said "Live".

## Validation

| Check | Result |
| --- | --- |
| Manual `claude -p /usage …` with the planned flags and environment | Exit 0 in about 2 s, `total_cost_usd: 0`; cache age went from 4.4 days to under 1 s. |
| `make test` | 58 tests passed (8 Engine, 50 Data). The new and rewritten Claude tests cover: a refreshed matching cache becomes the reading, with no Claude Keychain read or Anthropic request and the gate limiting runs; an unrefreshed cache and a cache for another account fail and back off; a missing CLI reports `cliUnavailable`; the account-switch statusline rule and the future-dated rule still hold; Live Usage off never runs the command. |
| `make build` | Build completed. |
| `make run` with Live Usage on | About 2 s after launch, `~/.claude.json` `fetchedAtMs` was 0.7 s old; no `claude -p /usage` process remained. |

## Open questions

- Each run is another Claude Code process that may rewrite `~/.claude.json` while the
  user's sessions also write it. Whether that can lose or corrupt their writes is
  not verified. Tidemark runs at most every 5 min; CC Switch uses 10 min.

- Not checked: whether macOS shows a Keychain prompt after the next Claude token
  renewal. That needs an expiry to happen. Tidemark no longer reads a Claude
  Keychain item, but Claude Code itself could still prompt if its own Keychain
  access is broken.
- Unverified inference: the original prompts came from Claude Code rewriting its
  item on renewal and dropping Tidemark's grant.
- Native Codex `Codex Auth` Keychain reads are unchanged and can still prompt.
