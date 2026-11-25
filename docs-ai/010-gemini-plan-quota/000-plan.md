# 010 — Gemini plan quota through the Antigravity CLI: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — see [001-action.md](001-action.md); trackpad layout check pending |
| Anchor date | 2026-11-26 |
| Origin | Maintainer request on 2026-11-26: "I want to support gemini plan usage lookups". The maintainer asked whether `agy` could mirror the Claude approach, chose "Invoke the CLI in the background to refresh/read quota (like Claude Code)", and answered an HTML plan's five decisions. |
| Related | [008-claude-usage-via-cli](../008-claude-usage-via-cli/000-plan.md), [design contract](../001-companion-foundation/design.md) |

## Background

The Google AI plan's coding quota is used through the Antigravity CLI, `agy`. Tidemark
shows Claude Code and Codex only.

Inspected on 2026-11-26 with `agy` 1.5.16 (`~/.local/bin/agy`):

- `agy -p /usage --output-format json --log-file /dev/null --print-timeout 20s` exited 0
  in about 7 s. It reported `num_turns: 0`, `usage.total_tokens: 0` and an empty
  `conversation_id`, and created no file under `~/.gemini/antigravity-cli/log/` or
  `conversations/`.
- Its stdout is one JSON object. `command.data.groups[].buckets[]` holds four buckets:
  `gemini-5h`, `gemini-weekly` (group "Gemini Models") and `3p-5h`, `3p-weekly` (group
  "Claude and GPT models"). Each has `window` (`5h` or `weekly`), `remaining_fraction`
  (0…1) and an ISO 8601 `reset_time`. It has no email or plan tier.
- With `HTTPS_PROXY` set to a closed `http://` or `socks5://` port, `agy` exited 1 and
  wrote `{"status":"ERROR","error":"… proxyconnect tcp …"}` to stdout. It calls
  `https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`.
- `agy` keeps no quota file Tidemark could read passively. The separate `gemini` CLI is
  not installed on this machine, and `~/.gemini/oauth_creds.json` does not exist.

This is the same shape as entry 008: the CLI owns its sign-in and answers its own usage
command without a model turn. Unlike Claude Code, `agy` returns the quota on stdout
instead of writing a cache file.

## Goals

- With Live Usage on, show the Gemini plan's four quota windows, refreshed by running
  `agy`, with the same gate, backoff, freshness and last-good store as other services.
- Never read Google or Antigravity credentials, including CC Switch's
  `agy_accounts.json`.
- A missing CLI, a failed run or an unreadable answer is a visible, backed-off status.
- Services refresh concurrently, so a refresh takes as long as its slowest service, not the sum.

### Non-goals

- The separate `gemini` CLI and its OAuth files.
- AI credits (`agy -p /credits`), multiple Antigravity accounts, and a passive
  statusline tap.

## Design / approach

- `TidemarkData`:
  - `QuotaService.gemini` (raw value `gemini`); account key `gemini:local`, because
    `/usage` names no account.
  - Proposed `AgyUsageCommand.swift`: an `AgyUsageCommand` seam on `UsageEnvironment`
    and `AgyCLIUsageCommand`, which locates `agy` like `ClaudeCLIUsageCommand` locates
    `claude`, runs the command above with a 40 s print timeout and a 45 s process
    timeout, writes stdout to a 0600 temporary file, and returns at most 256 KB of it.
    Raw output is parsed and dropped, never stored or logged.
  - `QuotaParser.agyUsage` maps each known bucket to a window `five_hour_<group>` or
    `seven_day_<group>` (groups `gemini` and `3p`), with used percent
    `(1 − remaining_fraction) × 100`. A missing or out-of-range fraction is unknown.
  - `UsageProxy` gives the CLI the same proxy variables as Claude Code, targeted at the
    Google host, and also passes SOCKS proxies, which `agy` reads.
  - `UsageService` runs Claude, Codex and Gemini concurrently. Gemini is included only
    when `agy` is at a known install path, found via the login shell while Live Usage is
    on (a miss is kept until Live Usage is turned on again or Tidemark relaunches), or a reading is stored.
  - Issues: CLI not found → `cliUnavailable`; timeout, or an answer without windows →
    `requestFailed`; a non-zero exit with a JSON `ERROR` answer → `requestFailed`;
    any other non-zero exit → `cliFailed`; a proxy Tidemark cannot pass →
    `proxyUnavailable`.
- App: `QuotaText` names the service "Gemini" and its windows "5-hour · Gemini",
  "Weekly · Gemini", "5-hour · 3P", and "Weekly · 3P"; issue copy names the Antigravity CLI. The dashboard shows a
  Gemini account's windows in one row that scrolls sideways with no scroller, routing
  vertical gestures to the dashboard as the request log table does.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Run `agy -p /usage` | Maintainer's choice; matches 008. Reading CC Switch's `agy_accounts.json` tokens and calling Google's internal quota API was rejected: it would read credentials and need renewal. |
| Name "Gemini", raw value `gemini` | Maintainer decision (the plan offered "Antigravity"). |
| All four buckets | Maintainer decision. The plan's Claude & GPT group is part of the same subscription. |
| One sideways-scrolling row | Maintainer comment on the plan: "show them in one single row, allowing horizontal scrolling, and hide the scroll bar". |
| Shown only when `agy` exists or a reading is stored | Maintainer decision. Users without Antigravity would otherwise see a permanent empty section, since there is no passive source. |
| Concurrent refresh | Maintainer decision. A 7 s run would otherwise add to the other services' time. Results still publish together. |
| No passive source | Maintainer decision. With Live Usage off, only the last stored reading shows. |

## Validation and acceptance criteria

- Package tests: the parser maps the observed answer, drops unknown buckets and rejects
  error answers; Live Usage off never runs `agy`; a run becomes a live reading and the
  gate limits runs; a missing CLI, an error exit and a JSON error answer map to their
  issues; Gemini is absent without `agy` or a stored reading.
- `make test` and `make build`.
- Runtime: with Live Usage on, the dashboard shows four Gemini windows in one row that
  scrolls sideways, and vertical scrolling over it still moves the dashboard.

## Amendments
- Updated 2026-11-26: results publish together, PATH-only `agy` is discovered, missed lookups are kept, and both CLIs share one locator; corrects the concurrency and discovery text — see [002-coordinated-refresh-and-lookup.md](002-coordinated-refresh-and-lookup.md)
