# 008.002 — Cache freshness for Claude Code's usage cache

## Context
After 001 shipped, the dashboard showed "Claude Code couldn't refresh usage" next to numbers that were current. Claude Code's `/usage` only rewrites `cachedUsageUtilization` when the cache is at least 60 s old. Tidemark required a rewrite on every run, so a run that Claude Code declined (because another Claude Code process had just refreshed the cache) counted as a failure.

## Change
- A cache under 60 s old for the signed-in account is used as it is, with no `claude` run.
- Otherwise the run goes ahead under the existing gate. Its result is accepted only if the cache is under 60 s old when the run ends, whether or not Claude Code rewrote it.
- A future-dated cache is never trusted, matching Claude Code's own check.
- Rejected alternative: keep requiring a rewrite but treat "not rewritten" as success. That would accept a stale cache and hide a real refresh failure.

## Refs
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`: `claudeCacheFreshness`, `liveClaude`, `currentClaudeReading`.
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`: `currentClaudeCacheIsUsedWithoutRunningClaudeCode`, `cacheOneMinuteOldIsNotCurrentSoClaudeCodeIsAsked`, and the rewritten Claude tests.
- Claude Code's threshold: `je = 60000` and the `QTi` write guard in `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe` (Claude Code 2.1.319). This is an internal detail and may change between versions.
