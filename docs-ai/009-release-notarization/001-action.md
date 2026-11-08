# 009 — Release notarization without an Xcode account: Action record

## Timeline
| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-09 | 0.1.4 release: `make release` archived and signed, then failed at export with `No Accounts`. Nothing was published. | Release log (local) |
| 2026-11-09 | The same command, commit, notes and script succeeded on retry. The cause is unknown. | Release log (local) |
| 2026-11-09 | Manual-signing export of the existing archive, and `notarytool` notarization of the app, tested without an account. | Local test, not committed |
| 2026-11-09 | `scripts/build-dmg.sh` switched to manual export and `notarytool`; full run passed. | `85fa1ee` |

## Outcome and current state (as of 2026-11-09)
`scripts/build-dmg.sh` signs with the keychain's `Developer ID Application` identity, notarizes
the app and the DMG through a `notarytool` keychain profile, and needs no Xcode account.
- `scripts/build-dmg.sh`
- `Makefile` (`release` target, which still passes `NOTARY_PROFILE` through)

The 0.1.4 release (`v0.1.4`, `6ae309e`) was built and published by the previous script, which
used the Xcode account for export and app notarization. Its DMG was checked after publishing.

## Deviations from plan
- The plan was written after the work, not before (see Origin).
- Without an account, the archive step was also run without `-allowProvisioningUpdates`; it
  succeeded.

## Validation
- Manual export and `notarytool` app notarization of the existing archive: passed. Verified with
  `codesign --verify --deep --strict`, `stapler validate`, and `spctl --assess --type execute`.
- `bash -n scripts/build-dmg.sh`: passed.
- `NOTARY_PROFILE=tidemark-notary scripts/build-dmg.sh`: exit 0. The log has no `No Accounts`
  or `error:` lines. Archive succeeded; `notarytool` accepted the app and the DMG; the DMG
  passed `stapler validate`, `spctl -a -t open`, and `shasum -c`.
- The rebuilt DMG was not published. It is local at `build/release/Tidemark-0.1.4.dmg`.

## Open questions
- Why the retry of the 0.1.4 release export succeeded when the first attempt failed is unknown.
  Whether the Xcode account state changed in between is not known either.
- No release has been cut with this script. The first release that uses it will confirm the
  whole path, including publishing.
