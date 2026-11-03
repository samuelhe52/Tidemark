# 003 — Direct multi-account quota: Action record

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-03 | Plan written; account ownership left unresolved before implementation | `000-plan.md` |
| 2026-11-03 | Maintainer explicitly selected CC Switch credential reuse; scoped the credential-write exception | `AGENTS.md` |
| 2026-11-03 | Implemented direct per-account renewal, write-back, usage and account identity handling | Uncommitted working tree |
| 2026-11-03 | Fake-transport tests, app build and real three-account Data-service probe | Validation below |
| 2026-11-03 | Dual Codex review; integer token timestamp, Keychain refusal and identity fixes | Review fixes below |

## Outcome and current state (as of 2026-11-03)

With Live Usage enabled, Tidemark queries inactive managed Codex accounts directly.
It references CC Switch CLI v5.11.3's refresh form and quota headers, without
invoking the CLI or opening CC Switch's database.

- `ManagedCodexCredentials` reads the v2 managed OAuth store afresh, renews with the
  account's refresh token, and saves rotated refresh/ID tokens and their timestamp
  back to that same account. Unknown fields, other accounts and the default account
  are preserved. Access tokens remain in memory and are reused until near expiry.
- Before committing, it rereads the account generation. A detected replacement or
  removal prevents stale write-back. After a failed renewal it retries at most once,
  and only using a changed disk generation. HTTP 429 honors `Retry-After`.
- A mode-0600, same-directory temporary file is synchronized and renamed over the
  store. A failed write keeps the rotation in memory for a write-only retry, rather
  than exchanging its consumed predecessor again. If the process exits before
  that write succeeds, recovery is not guaranteed.
- An advisory file lock prevents simultaneous Tidemark-process renewals. CC Switch
  does not participate in this lock. It can retain an older refresh token in memory,
  and it can change the file between Tidemark's final read and rename. These shared
  ownership races remain; this implementation does not claim otherwise.
- Managed rows, gates and snapshots use CC Switch's local account ID. The workspace
  ID is only the usage-request header. Different users in a workspace stay separate;
  a contradictory native user identity is not marked as the managed account.
  Legacy workspace-keyed snapshots migrate only for a unique mapping with a matching
  email and no contradictory active identity.
- Native Codex auth and the active-account marker are not rewritten. A valid native
  access token is reused for its matching managed active account. Rejected access
  tokens are invalidated so a later permitted attempt can renew the managed account.
- Live-off sends no network requests. If it is switched off during an exchange,
  the already-started rotation is still saved, but the subsequent usage GET is skipped.
- Claude keeps its existing read-only Keychain/file lookup; the CLI's alternate
  `claude.ai_oauth` JSON key is also accepted. No Claude token renewal was added.

Key source files:

- `Packages/TidemarkKit/Sources/TidemarkData/ManagedCodexCredentials.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageService.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/LocalSources.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/QuotaParser.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/QuotaObservation.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/ManagedCodexTests.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/LiveUsageTests.swift`
- `Sources/Tidemark/QuotaText.swift`

## Review fixes

A two-reviewer Codex review with a debate pass found these before commit; all are fixed:

- `token_updated_at_ms` was written as fractional milliseconds. CC Switch declares the
  field `i64` and deserializes the whole store at once, so one fractional value makes
  every managed account unavailable to it. Tidemark now writes whole milliseconds.
  The real probe above had already written fractional values into two rows of the
  maintainer's store; those rows need integer values before CC Switch reloads it.
- A denied Keychain read for native Codex was discarded and read again on every
  60-second refresh, so the prompt kept returning. A refusal is now remembered until
  a user-initiated refresh; managed renewal still runs.
- After a native token and then a managed token were rejected, the native token was
  no longer marked rejected and was tried again. Only native-token rejections are recorded.
- The native Keychain identity was not kept, so turning Live Usage off fell back to
  CC Switch's older marker and showed another account as active.
- A managed account with no user identity was matched to a known, different native
  user in the same workspace, whose quota was then saved under the managed account.
  A known native user now needs an equal identity.

Left as P3: a retry exchange after a rejected renewal does not re-check Live Usage.

## Deviations from plan

- Full dashboard runtime validation did not complete: the launched app waited in
  its pre-existing Claude Keychain read before reaching the sequential Codex refresh.
  A one-second process sample located the wait in `SecItemCopyMatching` through
  `UsageService.claudeCredential()`. Computer Use could not obtain a Tidemark window.
  The app launched for this check was stopped afterwards.
- Real Codex validation instead used the public `UsageService` with a credential
  adapter that returned no Claude Keychain item and a real network transport.
  This exercised real native Codex auth, managed renewal/write-back, quota parsing
  and snapshot persistence. It does not prove the dashboard or desktop-app renewal
  interoperability.

## Validation

| Check | Result |
| --- | --- |
| `make test` | After the review fixes, 32 tests passed (4 Engine, 28 Data); three added tests cover an integer timestamp under a strict `Int64` decoder, no repeated Keychain read after a denial, and an identity-less managed account not taking a known native user. Before them, 29 tests passed: 4 Engine and 25 Data. Ten added tests cover inactive users sharing a workspace, incompatible active identity and snapshot migration, concurrent unrelated updates, replaced/deleted accounts, recovery using a newer disk generation, isolated account failures, write-failure recovery without replaying a spent refresh token, another process's lock, renewal rate limiting, and live-off during renewal. |
| `make build` | Passed; `make run` also built and launched the app. |
| Touched-file formatting / `git diff --check` | Formatted only touched Swift files; whitespace check passed. Swift format lint still reports documentation-summary warnings and pre-existing snake-case Decodable fields. |
| Real Codex Data-service probe | All three managed accounts returned live readings with no issue: active weekly 72% used; inactive 30-day 0% used; inactive five-hour 5% and weekly 82% used. These are one-time observations, not fixed expectations. |
| Rotation and active-state metadata checks | Two managed account token timestamps advanced. All three accounts had new live snapshots. SHA-256 checks confirmed native Codex auth and the CC Switch active-account marker were unchanged. No credential values were printed or copied into this record. |
| Dual Codex review | Two reviewers plus a debate thread; findings and fixes listed under Review fixes. |
| Manual code review | Reviewed account attribution, generation checks, secret persistence, lock lifetime and live-off behavior; tightened legacy snapshot migration to avoid assigning an unmanaged user's workspace reading to a managed account. No independent agent review was run. |

## Open questions

- Shared refresh remains best-effort until CC Switch and Tidemark use a single
  refresh owner or mutually implemented coordination protocol. This includes the
  native Codex refresh chain if it shares the managed session: keeping its file
  unchanged does not prove its future renewal will remain valid.
- The existing sequential refresh can wait on Claude's interactive Keychain read.
  The full app/dashboard path needs validation after that read completes; the real
  Data-service result above deliberately isolates it.
- Claude multi-account discovery/renewal is outside this Codex reuse change.
