# Tidemark decision-record workflow

Use `docs-ai/` to preserve decisions that future implementation depends on.
The project-owned `write-ai-doc` skill defines the plan/action/amendment workflow
and templates; this document adds Tidemark-specific selection and evidence rules.

## Select work deliberately

Create a numbered entry for a substantial feature or a fix with enduring product,
architecture, data-source, credential-handling, or distribution implications.
Record the reason and rejected alternatives when code alone would not explain the
choice. Skip routine debugging, reviews, test reports, minor UI polish, dependency
bumps, and docs-only edits unless the maintainer requests a durable record.

## Plan, implement, and reconcile

1. Read the index and amend an existing topic when the decision still fits it.
2. For a new topic, choose the next free three-digit number and kebab-case slug.
   Create `000-plan.md` before coding: background, goals, approach, alternatives,
   reasons, validation criteria, and unresolved decisions.
3. Implement within the user's authorization. A plan or skill does not authorize
   committing, publishing, or any remote mutation.
4. Write `001-action.md` after implementation: dated outcomes, key source paths,
   actual validation, deviations, and remaining uncertainty. Set the plan status
   to Implemented only when the intended scope is complete. Use In progress for
   partial delivery and Planned for proposals.
5. Add `002-<topic>.md` and later amendments for related follow-ups. Link them from
   the plan and index. For a major redesign, create a new entry and cross-link the
   superseded one. Multi-slice plans record each slice as an amendment and finish
   the aggregate action record when the final slice completes.

Use concise documents rather than a mandatory size quota. Keep long behavioral
contracts and the PRD in named Markdown reference files beside the plan; link
instead of copying the same content into every amendment.

## Record intent and evidence

- Explain what constraint led to each choice and why a plausible alternative was
  rejected. Do not fabricate an alternatives discussion from code alone.
- Label recovered discussion memory (including another agent's handoff notes) and
  distinguish it from source documents, commit messages, tests, or runtime
  observations. Mark reasoning inferred from implementation as inference.
- Separate proposed behavior, implemented source, and actual runtime verification.
- Existing source paths must exist in the checkout. Proposed new paths may be
  named when explicitly marked proposed.
- Do not cite untracked or ignored paths such as `.build/` or `tmp/` as evidence.
  Write the observed result into the record itself.
- Facts about other tools' stores (CC Switch, Claude Code, Codex) carry the tool
  version and inspection date; those formats change without notice. Never record
  credential values.
- Keep records truthful. When a follow-up invalidates plan or action text, correct
  it in place and note the correction in the dated amendment. Named reference files
  are living files and are updated in place; `historical/` sources are not edited.

## Documentation ownership

`docs-ai/` holds internal design, implementation history, contracts, and reviews.
The root READMEs stay public. If public user documentation is needed later, it goes
in `docs/`.

Tidemark sources are under `Sources/Tidemark/` and `Packages/TidemarkKit/Sources/`.
Use the Makefile, module boundaries, and testing rules from `AGENTS.md`. Use the
actual current date in new records.

## Source and local adaptation

The skill at `.agents/skills/write-ai-doc/SKILL.md` (linked from `.claude/skills/`)
was adapted from AniShelf's copy, itself adapted from
[onevcat/Prowl](https://github.com/onevcat/Prowl/blob/main/.claude/skills/write-ai-doc/SKILL.md).
It is project-owned: edit it in place; do not reinstall it from upstream.
