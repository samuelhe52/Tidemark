# 008.005 — Proxy address setting

## Context
[004](004-proxy-routing.md) routes live requests by Tidemark's own environment, then the
user's login shell, then the macOS proxy settings. On 2026-11-09 the maintainer decided
that users should be able to set a proxy explicitly in Tidemark's settings, rather than
depend on shell startup files or system settings. The decision was made in conversation
before the 0.1.4 release; the reason is not recorded beyond that. It is inferred that the
shell lookup is invisible to users and runs startup files every five minutes (004, Limits).

## Change
Settings → Usage → Network has one optional **Proxy** field. When it holds a valid
address, that proxy is the first routing source:

1. **The settings proxy**, for every live request, with no bypass list. All traffic is to
   the vendors' hosts, so a bypass list would have nothing to bypass.
2. Then the 004 order, unchanged: Tidemark's own environment, the login shell, the system.

Decisions:

| Choice | Reason and alternative |
| --- | --- |
| Additive; the shell and system sources stay | The request was to add a setting. Removing the shell lookup is a separate decision, not made here. |
| One address field, not a mode picker | Empty means automatic, so there is no state to keep in sync. A mode picker was not needed. |
| Credentials in the URL are rejected | The address is saved in `UserDefaults` in the clear. An authenticated proxy still works through the shell or system sources. (Inference: a Keychain item would be the way to support them here; not built.) |
| An explicit SOCKS proxy is allowed for Codex requests but reports `proxyUnavailable` for Claude Code | Claude Code accepts only HTTP(S). Unlike a SOCKS variable (004), the user chose this proxy, so falling through to another source would route traffic the user did not ask for. |
| The field saves on Return or loss of focus, and only a valid address | Saving each keystroke would refresh usage for every partial URL. An invalid address stays in the field with an error and is not saved; the previous one stays in force. |
| The address reaches `TidemarkData` through `ProxyOverride`, a lock-protected box read on every request | The data target imports no settings or UI. Requests are already built per call, so a change applies to the next one. `UsageModel` refreshes at once when it changes and Live Usage is on. |

## Current state
Implemented and shipped in 0.1.4 (2026-11-09; tag `v0.1.4` at `6ae309e`). The code is in
`6ae0aba`, and this record is in `fba5ace`. `UsageSettingsView` and `ProxyAddressField` in
`SettingsView.swift` hold the UI. `SettingsStore.proxyAddress` saves under
`DefaultsKey.proxyAddress` and drops a saved value that is no longer valid at launch.

## Validation
Run by Claude Code on 2026-11-09: `make test` passed (65 Data tests, 8 Engine tests), and
`make build` passed. New tests cover precedence over the shell, system, and `NO_PROXY`;
both vendor hosts; the Claude environment replacing inherited variables; SOCKS failing for
Claude only; malformed, port 0 and credential addresses failing for both; clearing the
address restoring the other sources.

Settings pane: the maintainer reviewed it in the running app and approved it before the
release. Claude Code did not run the app, so the pane's layout (480 pt height), Return and
focus-loss saving, the immediate refresh, and an end-to-end request through a real proxy
are not verified by Claude Code.

## Refs
- `Packages/TidemarkKit/Sources/TidemarkData/UsageProxy.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/UsageEnvironment.swift`
- `Packages/TidemarkKit/Tests/TidemarkDataTests/UsageProxyTests.swift`
- `Sources/Tidemark/SettingsView.swift`
- `Sources/Tidemark/SettingsStore.swift`
- `Sources/Tidemark/UsageModel.swift`
