# 009 — Release notarization without an Xcode account: Plan

| Field | Value |
| --- | --- |
| Status | Implemented |
| Anchor date | 2026-11-09 |
| Origin | Reconstructed after the work shipped. The maintainer asked to avoid the Xcode sign-in after the 0.1.4 release export failed with `No Accounts`. The plan was written after implementation (commit `85fa1ee`) and is not a pre-implementation plan. |
| Related | [008-claude-usage-via-cli](../008-claude-usage-via-cli/000-plan.md) (the 0.1.4 release it was cut with) |

## Evidence and recovered rationale
- Source: `scripts/build-dmg.sh` before and after `85fa1ee`; the 0.1.4 release log (first attempt
  failed at `exportArchive` with `No Accounts: Add a new account in Accounts settings`; the
  retry with the same commit, notes and script succeeded). The cause of the retry's success is
  not known.
- Recovered discussion: the maintainer asked whether the Xcode sign-in could be avoided, then
  asked for the change to be tested first and committed if it worked.
- Inference: the old upload export and `exportNotarizedApp` used Xcode's account; the
  `notarytool` keychain profile was already used for the DMG.

## Background
The release script exported with `destination: upload` and `signingStyle: automatic`, with
`-allowProvisioningUpdates`, and notarized the app through `xcodebuild -exportNotarizedApp`.
Both need an Apple account signed in to Xcode. A release on a Mac without that account stops
at export, after the archive is built.

## Goals
- A release needs only the keychain's `Developer ID Application` identity and a `notarytool`
  keychain profile, with no Xcode account.
- The DMG is notarized and stapled as before.

### Non-goals
- Changing the release process in the Makefile or the step order in the release skill.
- Re-cutting 0.1.4. The change adds no user-facing behavior.

## Design / approach
- `scripts/build-dmg.sh` archives without `-allowProvisioningUpdates`, exports with
  `destination: export`, `signingStyle: manual`, and `signingCertificate: Developer ID
  Application`, zips the app with `ditto`, submits it with `xcrun notarytool submit
  --keychain-profile`, and staples it. The DMG is notarized and stapled as before.
- `NOTARY_PROFILE` is now required. `make release` already required it.

## Alternatives & decisions
| Choice | Reason and alternative |
| --- | --- |
| Replace the Xcode-account steps rather than keep both paths | One path is easier to verify. Keeping the old path as a fallback would hide a broken new path. The old path's failure was the reason for the change. |
| `notarytool` for the app as well as the DMG | The DMG already used it, so only one credential store is needed. |
| Keep `-allowProvisioningUpdates` on the archive | Tested: the archive succeeded without it, so it was removed. |

## Validation and acceptance criteria
- Manual export of the existing archive with no account: succeeded; `notarytool` accepted the app,
  `stapler` stapled it, and `spctl` reported `Notarized Developer ID`.
- Full `scripts/build-dmg.sh` run with `NOTARY_PROFILE=tidemark-notary`: exit 0; the log has no
  `No Accounts` or `error:` lines; the DMG is accepted and stapled; the checksum verifies.
- Not done: a publish with the new script. The 0.1.4 release was cut with the earlier script.

## Amendments
None yet.
