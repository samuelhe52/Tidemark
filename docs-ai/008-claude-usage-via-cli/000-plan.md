# 008 — Live Claude usage through Claude Code: Plan

| Field | Value |
| --- | --- |
| Status | Implemented |
| Anchor date | 2026-11-07 |
| Origin | Maintainer report: with Live Usage on, Tidemark keeps asking for Keychain access after the Claude OAuth token expires, while CC Switch does not. An investigation compared CC Switch's source; the maintainer asked to verify that proposal and implement it if sound. |
| Related | [002-live-quota-native-surface](../002-live-quota-native-surface/000-plan.md), [003-direct-multi-account-quota](../003-direct-multi-account-quota/000-plan.md) |

## Background

Live Claude usage reads the `Claude Code-credentials` Keychain item with
`SecItemCopyMatching` and sends its access token to `GET api/oauth/usage`
([design 3.1](../001-companion-foundation/design.md)). Tidemark never renews that
token; an expired one reports `credentialExpired` until Claude Code renews it.

The maintainer sees repeated Keychain prompts after the token expires. Inference,
not verified on this machine: Claude Code rewrites the item when it renews, and
the rewrite drops the "Always Allow" grant Tidemark received, so the next read
prompts again. Either way, every read of an item another tool owns can prompt.

CC Switch's CLI fallback (upstream
`src-tauri/src/services/claude_account/usage.rs` at `e1f8acf`) runs
`claude -p /usage --output-format json --tools "" --strict-mcp-config
--setting-sources "" --no-session-persistence` in the account's config
directory. Correction verified on 2026-11-08: CC Switch's subscription service
reads credentials and queries HTTP first; it uses this CLI path for expired
credentials. The fallback supplies CC Switch's configured HTTP proxy. Tidemark's
CLI-only approach is a local credential-ownership decision, not a copy of that
complete query flow. Claude Code answers `/usage` itself, without a model turn, renews its
token under its own lock if needed, and writes `cachedUsageUtilization` to
`.claude.json`. CC Switch then reads that cache, accepting it only for the
matching `accountUuid`, and runs the command at most once per account per ten
minutes, one at a time, with a 45 s timeout.

Checked on 2026-11-07 with Claude Code 2.1.319: that command exited 0 in about
2 s with `total_cost_usd: 0`, and moved the cache's `fetchedAtMs` from 4.4 days
old to the run time for the signed-in account. The cache had not been refreshed by
ordinary use in those days, so the passive cache alone is not a live source.

## Goals

- Live Claude usage never reads a Claude Keychain item or credentials file.
- Claude Code remains the only owner of Claude token renewal.
- A missing CLI, a timeout, or a cache that did not refresh is a visible,
  backed-off failure, not a prompt or a silent stale reading.

### Non-goals

- Codex. Native `Codex Auth` Keychain reads are unchanged; if prompts name that
  item, this entry does not fix them.
- Claude multi-account usage (CC Switch's per-account config directories).

## Design / approach

- `TidemarkData` gains a `ClaudeUsageCommand` seam on `UsageEnvironment`
  (proposed file `Packages/TidemarkKit/Sources/TidemarkData/ClaudeUsageCommand.swift`).
  The real command locates `claude` (known install paths, then one cached
  login-shell lookup), and runs it with CC Switch's arguments, cwd `~`,
  stdin/stdout/stderr discarded, a 45 s timeout, and an environment without
  `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` and
  `ANTHROPIC_BASE_URL`, plus `CLAUDE_CODE_DISABLE_AUTO_MEMORY`,
  `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER` set to 1.
  `--setting-sources ""` also keeps the user's hooks from running on every poll.
- `UsageService` keeps the per-account `LiveRequestGate` for Claude. When it
  allows, it runs the command, rereads `~/.claude.json`, and accepts the cache as
  a live observation only when its `accountUuid` equals the signed-in account and
  `fetchedAtMs` is not older than the run's start. Otherwise the gate backs off.
- Issues: the CLI cannot be found → new `QuotaReadIssue.cliUnavailable`; the
  run timed out or the cache did not refresh → `requestFailed`.
- The plan name came from the Keychain token's `subscriptionType`. It now comes
  from `oauthAccount.organizationType` in `.claude.json` (`claude_pro` → `pro`).
- The Claude HTTP request and credential read are removed.
- The design contract (3.1, 6) is updated: Tidemark still never writes `~/.claude`
  or Keychain items, but with Live Usage on it asks Claude Code to refresh, and
  Claude Code may renew its token and rewrite its own files.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Run the CLI rather than read the token | Removes Tidemark's Keychain read entirely and leaves renewal to its owner. Reading the token and asking users to re-grant access was the status quo. Renewing the Claude token in Tidemark was rejected: it would write Claude's credentials and race Claude Code. |
| Keep Tidemark's 5 min / backoff gate | One gate for every live source. CC Switch uses 10 min; a run costs about 2 s and no model turn. |
| Default config dir only | Tidemark reads only `~/.claude.json`; the run must write the same file. |
| Locate `claude` ourselves | A GUI app's `PATH` usually excludes `~/.local/bin` and Homebrew, so `Process` cannot rely on it. |

## Validation and acceptance criteria

- Package tests: a refreshed matching cache becomes a live reading; a cache for
  another account or one not refreshed is rejected and backs off; a missing CLI
  reports `cliUnavailable`; Live Usage off never runs the command; no Claude
  Keychain read happens with Live Usage on.
- `make build`.
- Runtime: with Live Usage on, Claude shows a `Live` reading with no Keychain
  prompt.

## Amendments
- Updated 2026-11-07: the run is accepted only when the cache is under 60 s old at the end, and a young cache skips the run — see [002-cache-freshness.md](002-cache-freshness.md)
- Updated 2026-11-08: the login-shell lookup is now cached as this plan intended, and the run is hardened — see [003-run-hardening.md](003-run-hardening.md)
- Updated 2026-11-08: corrected the CC Switch comparison and added shared proxy routing and truthful refresh status — see [004-proxy-routing.md](004-proxy-routing.md)
