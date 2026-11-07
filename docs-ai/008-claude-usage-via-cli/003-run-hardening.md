# 008.003 — Hardening the Claude Code run

## Context
An audit of `e3d0e2c` and `f34c262` found gaps in how Tidemark runs `claude`. The plan
called for one cached login-shell lookup, but every run that missed the known install
paths started an interactive login shell, so installs under nvm, fnm, volta, asdf or
mise ran the user's startup files every 5 minutes.

## Change
- The login shell's answer is kept in memory while that file stays executable, and is
  looked up again only when it disappears. A failed lookup is not cached, so a later
  install is still found.
- The shell writes its answer to a temporary file named by `TIDEMARK_ANSWER` instead
  of a pipe with a marker. Startup-file output can no longer mix with the answer or
  fill the pipe until the lookup times out.
- The run's environment also drops `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
  `CLAUDE_CODE_USE_BEDROCK` and `CLAUDE_CODE_USE_VERTEX`, which a Tidemark started
  from a Claude Code terminal or a cloud setup would otherwise pass on.
- A cancelled refresh terminates the process at once. Before, `try? await Task.sleep`
  returned immediately in a cancelled task, so the wait loop spun until `claude` exited.
- Turning Live Usage off during a run discards its result, as the Codex path already did.
- A cache young enough to skip the run now records a gate success, so it ends any
  backoff and restarts the 5 min automatic interval.
- The Live usage footer in Settings says that Tidemark runs Claude Code in the
  background for Claude.
- Not changed: the 5 min interval. The concurrent-write risk to `~/.claude.json` is
  unverified and is listed in the action record's open questions.

## Refs
- `Packages/TidemarkKit/Sources/TidemarkData/ClaudeUsageCommand.swift`: `locate`, `shellLookup`, `wait`, `ShellAnswer`.
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`: `liveClaude`.
- `Sources/Tidemark/SettingsView.swift`: Live usage footer.
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`: `currentClaudeCacheIsUsedWithoutRunningClaudeCode` now also checks the restarted interval.
- Validation on 2026-11-08: `swift test` in `Packages/TidemarkKit` passed 60 tests (8 Engine, 52 Data); `make build` completed; the lookup's shell command, run by hand in the maintainer's login shell, wrote `/opt/homebrew/bin/claude`. Not checked: the cached lookup against a `claude` found only by the shell, and an app run.
