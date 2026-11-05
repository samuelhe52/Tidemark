---
name: release
description: Take a new Tidemark version from main to a published GitHub release, covering preflight, version bump, user-facing notes, push, signed and notarized DMG, publish, and post-publish verification. Use whenever the maintainer wants to release, ship, cut, publish, or tag a Tidemark version (e.g. "release 0.1.2", "ship a patch", "cut a new version", "发个新版本"), even if they only name the version. Not for building a local DMG with no publish (`make dmg`), and not for questions about past releases.
---

# Release Tidemark

Publish one version end to end. The work splits around a single approval gate:
everything before it is read-only, and everything after it runs without stopping
unless something fails.

Invoking this skill does not itself authorize commits or pushes
(`docs-ai/workflow.md`). The maintainer's OK at the gate does, and it covers the
whole of steps 4-6 for that version. Hold the gate even when the request names a
version, because the notes and the list of commits are what is being approved.

## 1. Preflight (read-only)

Run `git fetch origin --tags`, then check each of these. Stop and report on any
failure, without working around it.

- **On `main`, with a clean tree** (`git status --porcelain` is empty). The archive
  builds from the working tree, so stray edits, including another agent's, would
  ship in a DMG that matches no commit.
- **Not behind `origin/main`.** Being ahead is fine: those commits ship and get
  pushed in step 4, so list them at the gate.
- **There is something to release.** Take the last version from
  `gh release view --json tagName -q .tagName` and run `git log <tag>..HEAD`. If
  nothing but chores landed, say so and ask whether to continue.
- **Tools and credentials:** `command -v create-dmg`, `gh auth status`, and a
  `Developer ID Application` identity in `security find-identity -v -p codesigning`.
- **Notary profile:** use `$NOTARY_PROFILE`, or `tidemark-notary` when it is unset.
  Check it with `xcrun notarytool history --keychain-profile <profile>`.
- **`make test` and `make build` pass.** Do not gate on `make lint`; it already
  reports many doc-comment warnings.

## 2. Choose the version and draft the notes

Use the version the maintainer gave. Otherwise propose the next patch version, which
is what 0.1.1 did even with new features in it, and propose a minor bump only for a
headline feature. The tag `v<version>` must not already exist.

Draft the notes from the commits since the last tag. Read the diff when a subject
doesn't show what a user would notice. Compare `gh release view <last tag>` for
tone. The format:

```markdown
## Added

- Request logs on the dashboard.

## Fixed

- The orb animates to the nearest edge when a drag ends.

## Improved

- Request logs load larger pages.

**Full Changelog**: https://github.com/samuelhe52/Tidemark/compare/v<last>...v<version>
```

- Write for someone using the app: what changed for them, not how it was built.
  Merge related commits into one line.
- Leave out `chore`, `build`, `docs`, `test`, and refactors with no visible effect.
- Leave out fixes for bugs that never reached a release, such as a fix to a feature
  added in this same version. Users never saw the bug.
- Omit empty sections. Add a `## Notes` section when behavior around credentials,
  other tools' stores, or requirements changes.

Save the notes to a temp file outside `build/`, because `scripts/build-dmg.sh`
deletes `build/release`.

## 3. Approval gate

Show the maintainer the version and why, the commits being released, which of those
are unpushed, the full notes, and what happens next (commit the bump, push `main`,
build, publish). Wait for an explicit OK. If they change something, revise and show
it again.

## 4. Bump and push

Set `MARKETING_VERSION` to the new version in `Tidemark.xcodeproj/project.pbxproj`.
It appears on two lines, for Debug and Release, and both must change. Leave
`CURRENT_PROJECT_VERSION` at its current value, as past releases did. If the project
already has the new version, skip the commit.

```sh
git add Tidemark.xcodeproj/project.pbxproj
git commit -m "chore: Bump version to <version>"
git push origin main
```

The push has to come first. `make release` tags the commit it builds and refuses to
start unless that commit is on `origin/main`. Past releases tag the bump commit, and
this order keeps it that way.

Before building, confirm that the tree is still clean and that `HEAD` equals
`origin/main`.

## 5. Build and publish

```sh
NOTARY_PROFILE=<profile> make release VERSION=<version> NOTES=<notes file>
```

Run this in the background. The app and the DMG are notarized one after the other,
which can outlast the foreground command timeout, and the script alone allows the
app 30 minutes.

Always pass `NOTES`. Without it the target falls back to `--generate-notes`, which
yields only a changelog link in this PR-less repo.

### If it fails

- **Before anything was published** (signing, notarization, `create-dmg`): no
  release or tag exists. Rerun the same command for transient failures. For a
  rejected submission, read `xcrun notarytool log <submission id> --keychain-profile
  <profile>`. Leave the pushed bump commit in place.
- **The DMG built but `gh release create` failed:** don't rebuild. Rerun the
  `gh release create` line from the `Makefile` by hand, with `--target` set to the
  commit that was built and `--notes-file` set to the notes.
- **The fix needs a code change:** stop and report. New commits weren't part of what
  was approved.
- **Anything is wrong after publishing:** report it. Deleting or moving a published
  release or tag needs a fresh OK.

## 6. Verify what users will download

Check the published release, not the local build:

```sh
git fetch origin --tags
git rev-parse "v<version>^{commit}"      # must equal HEAD
gh release view v<version> --json isDraft,isPrerelease,assets,body
gh release list --limit 1                # the new version is Latest

dir=$(mktemp -d) && cd "$dir"
gh release download v<version> --repo samuelhe52/Tidemark
shasum -a 256 -c Tidemark-<version>.dmg.sha256
xcrun stapler validate Tidemark-<version>.dmg
spctl -a -t open --context context:primary-signature -vv Tidemark-<version>.dmg
hdiutil attach -nobrowse -readonly -mountpoint "$dir/mnt" Tidemark-<version>.dmg
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dir/mnt/Tidemark.app/Contents/Info.plist"
hdiutil detach "$dir/mnt"
```

A signed DMG isn't necessarily a notarized one, as 0.1.0 showed, so `stapler` and
`spctl` test notarization itself rather than the signature alone.

## 7. Report

Give the release URL, the version, the tagged commit, and the result of each check
in step 6. Say plainly if any check failed or was skipped.
