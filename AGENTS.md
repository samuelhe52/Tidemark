# Tidemark - Developer Notes

## Project Nature

- Tidemark is a native macOS companion that docks at a screen edge, emerges on hover, and shows Claude Code and Codex quota and usage.
- Design records live in `docs-ai/`. Start with [`docs-ai/README.md`](docs-ai/README.md); the design contract is [`docs-ai/001-companion-foundation/design.md`](docs-ai/001-companion-foundation/design.md), with its decisions in that entry's `000-plan.md`.

## Architecture

- Keep the three concerns in separate `TidemarkKit` targets. The app target (`Sources/Tidemark`) is the only code that imports more than one of them.
  - `TidemarkEngine`: placement, docking, hover and pin state, interaction timing. No networking, no file reads, no drawing.
  - `TidemarkAppearance`: skins and rendering. A skin never moves windows, reads credentials, or changes usage data.
  - `TidemarkData`: quota and usage sources, normalization, freshness. No AppKit or SwiftUI imports.
- The dashboard is shared and not skinnable.
- Read other tools' stores (`~/.cc-switch`, `~/.claude`, `~/.codex`) read-only. Never refresh, rotate, or write another tool's credentials.
- Missing or stale quota data is shown as unknown with its age, never as full.

## Workflow

- Use Makefile targets for routine tasks (`make help` lists them). Verify with `make build`; launch with `make run` only when validating runtime behavior.
- Run `make format` only when the user asks; it rewrites the whole repository. Format only the files you touched with `swift format -i <paths>`.
- The Xcode project uses synchronized folders: new files under `Sources/` and `Resources/` join the app target automatically. New package files only need to sit under the right `Packages/TidemarkKit/Sources/<Target>/` folder.
- If the user asks to perform a change in a new worktree, create that worktree under `.worktrees/` in the repository root.
- Use the `write-ai-doc` skill for substantial features and decision-shaping fixes, as defined in [`docs-ai/workflow.md`](docs-ai/workflow.md).

## Code Style

- When creating new Swift source files, include the standard Xcode file comment header. Attribute authorship to the agent (OpenAI Codex or Claude Code) on behalf of Samuel He, and use the real creation date in `YYYY/M/D` format:
  ```
  //
  //  FileName.swift
  //  Tidemark
  //
  //  Created by <agent> on behalf of Samuel He on YYYY/M/D.
  //
  ```
  Omit this header only when the user explicitly requests it.
- Pass plain string literals to SwiftUI APIs that already take a `LocalizedStringKey`; use `LocalizedStringResource` for user-facing strings held in properties, models, or enums.

## Testing

- Add the smallest set of tests that protects distinct behavior. Engine state transitions and Data parsing are the main candidates; simple wiring, copy, or layout changes may need no new tests.

## Commits

- Commit only when the maintainer asks; pushing requires explicit authorization.
- Other agents may be editing the same working tree. Stage only changes within the commit's scope, by path (`git add <paths>`); never use `git add -A`, `git add .`, or `git commit -a`.
- Use conventional commits: `<type>: <subject>`, with imperative, capitalized, concise subjects and no trailing period.
