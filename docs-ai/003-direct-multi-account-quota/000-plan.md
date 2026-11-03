# 003 — Direct multi-account quota: Plan

| Field | Value |
| --- | --- |
| Status | Implemented — see [001-action.md](001-action.md); shared desktop refresh race remains |
| Anchor date | 2026-11-03 |
| Origin | Maintainer requested direct multi-account quota queries using CC Switch CLI as an implementation reference, rather than a runtime dependency. |
| Related | [002 live quota](../002-live-quota-native-surface/000-plan.md), [design contract](../001-companion-foundation/design.md) |

## Background

`UsageService` currently queries the active Claude and Codex accounts. Other
CC Switch managed Codex accounts receive only Tidemark's last recorded reading.
The maintainer wants direct queries for those accounts without activating them.

Inspection on 2026-11-03 found that CC Switch CLI v5.11.3 already routes quota
queries through each provider's managed account binding, but it cannot open this
machine's schema-24 desktop database: its maximum supported schema is 22. Its
OAuth manager also owns a separate in-memory credential cache and process-local
locks. Invoking it alongside the desktop app does not establish shared refresh
ownership. The current CLI `main` has the same OAuth manager implementation.

For Claude on macOS, that CLI reads Keychain through the `security` executable,
then falls back to the configured Claude directory's `.credentials.json`. It
queries usage with the access token and reports expiration rather than renewing
the Claude token. Absence of a visible permission prompt does not establish which
source was used.

## Goals

- Query each supported account independently, without switching the active agent
  or invoking CC Switch CLI.
- Preserve per-account timing, backoff, dated last-good observations and truthful
  unknown/expired states.
- Keep credentials out of quota snapshots, logs and diagnostic output.
- Use CC Switch CLI as a protocol and parsing reference, with credential ownership
  explicitly resolved before implementing renewable inactive-account access.

## Design / approach

The quota transport, credential resolution and account discovery belong in
`TidemarkData`. The existing `UsageService.swift`, `LocalSources.swift`,
`UsageEnvironment.swift`, `LiveRequestGate.swift` and `LiveUsageTests.swift` are
the integration points. Dashboard changes are needed only if the selected
credential ownership requires account setup or additional account state.

`ManagedCodexCredentials.swift` implements the selected renewal flow, preserving
unknown store fields and caching access tokens only in memory. An advisory lock
serializes Tidemark processes. A failed credential save retains the rotation in
memory and retries its write before any new exchange; shutdown before successful
write-back can still lose it. Turning Live Usage off during renewal lets that
already-started rotation be saved but prevents the subsequent quota request.

Each request must resolve credentials for its target account and attribute its
response, gate and error to that same account. Account identity must distinguish
different signed-in users sharing an upstream workspace; workspace ID alone is
insufficient for account discovery and persistence.

### Credential ownership decision

On 2026-11-03 the maintainer selected reuse: "yes, reuse. reference cc switch
cli's approach while doing so." This authorizes managed Codex token rotation and
write-back to CC Switch's OAuth store. `AGENTS.md` records this scoped exception;
Claude credentials and native Codex auth remain read-only.

| Approach | Consequence |
| --- | --- |
| Reuse CC Switch credentials (selected) | Follow the CLI's OAuth refresh protocol and persist rotated refresh/id tokens, caching access tokens only in memory. Reread before refresh and before write-back; preserve unrelated fields, reject detectable generation changes, and serialize Tidemark refreshes across processes. The unmodified desktop does not honor this lock and can retain stale tokens in memory; this remains an accepted integration limitation, not a solved concurrency guarantee. |
| Separate Tidemark-owned sign-ins | Keeps other tools' credentials read-only, but requires account authorization, secure credential storage and renewal owned by Tidemark. Copying a CC Switch refresh token into a Tidemark file would still share the same refresh chain and does not provide independence. |

Use still-valid native Codex credentials when they belong to the target managed
account; otherwise resolve the managed account independently. Active detection
must not use workspace alone when several managed users share it. Failed renewal
retains the last dated quota observation and reports an account-specific error.
Native Codex auth is not rewritten; a renewed managed session does not change the
active provider or its identity marker. Live requests and token renewal are off
when Live Usage is disabled.

## Alternatives & decisions

| Choice | Reason and alternative |
| --- | --- |
| Direct implementation | Maintainer's selected direction; avoids the installed CLI's schema dependency and process launch overhead. |
| Retain existing quota endpoints and freshness rules | Multiple accounts change credential selection and attribution, not the meaning of a quota observation. |
| Do not treat process-local locks as shared ownership | Both desktop and CLI can retain a consumed refresh token in memory despite another process saving its replacement. |

## Validation and acceptance criteria

- Focused Data tests: distinct account credentials and headers, identity and
  response attribution, isolated errors/backoff, expiration and account removal.
- The selected ownership approach determines additional renewal/persistence tests;
  tests must cover stale generations and partial failures, not only successful
  token responses.
- Run `make test` and `make build` after implementation; format only touched Swift
  files.
- Runtime acceptance: an inactive account returns a fresh dated reading while the
  active account remains unchanged. Report separately what was tested with fakes
  and what was verified against real accounts.

## References

- [CLI quota routing, v5.11.3](https://github.com/SaladDay/cc-switch-cli/blob/v5.11.3/src-tauri/src/cli/provider_quota.rs).
- [CLI credential manager, v5.11.3](https://github.com/SaladDay/cc-switch-cli/blob/v5.11.3/src-tauri/src/proxy/providers/codex_oauth_auth.rs).
- [CLI Claude credential lookup, v5.11.3](https://github.com/SaladDay/cc-switch-cli/blob/v5.11.3/src-tauri/src/services/subscription.rs#L124-L179).
- [Official OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth)
  describes native credential storage. The shared-store renewal implementation
  above follows the requested CLI reference; this is not a claim of an official
  cross-application token coordination contract.

## Amendments

- Updated 2026-11-03: User-controlled dashboard account visibility — see
  [002-account-visibility.md](002-account-visibility.md).
