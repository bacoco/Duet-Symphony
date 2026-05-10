# AGENTS.md

This repository contains the standalone Duet-Symphony design. It was extracted
from the Bacos skills monorepo so future work should happen here.

## Project Intent

Duet-Symphony is a two-agent Claude + Codex orchestration harness inspired by
OpenAI Symphony. The goal is strict sequential collaboration: one agent authors
an artifact, the other reviews it, and the loop continues until both approve
the same Git revision.

This is not Council. Council is multi-model parallel deliberation; Duet is
exactly two agents in alternating author/reviewer roles with GitHub PRs as the
artifact and convergence substrate.

## Current State

- Design/spec only. There is no implementation yet.
- `SPEC.md` is the source of truth.
- The branch topology in the spec intentionally uses separate namespaces:
  `duet-base/<task_id>` for the long-lived task branch and
  `duet-phase/<task_id>/<phase>` for phase PR branches. Do not change this back
  to `duet/<task_id>` plus `duet/<task_id>/spec`; that ref layout is invalid in
  Git.
- `github_bot` is specified, but current Claude workflows from the source repo
  are only examples. A conformant bot flow must produce parseable Duet trailers
  and/or GitHub review states.

## Next Implementation Step

Build a minimal local `cli_session` MVP before adding GitHub bot automation:

1. Create a small CLI, probably `duet`, with `run`, `status`, `logs`,
   `abandon`, `prune`, and `config validate`.
2. Implement worktree creation and cleanup using the `duet-base/*` and
   `duet-phase/*` branch scheme.
3. Implement the phase loop: `SPEC -> PLAN -> CODE -> REVIEW`.
4. Start with one transport: local CLI sessions for Claude and Codex using
   resume mode or stdin mode, whichever is reliable.
5. Parse only the final `---DUET-TRAILER---` block from each agent response.
6. Persist structured events to `.duet/logs/tasks/<task_id>/events.jsonl`.
7. Add GitHub PR creation/review state after the local phase loop works.

## Known Design Constraints

- Claude-side and Codex-side GitHub operations need distinct GitHub identities
  for binding PR approvals. A single shared bot account is not enough for the
  split-signal convergence model.
- CODE must not auto-merge reviewer-rejected code by default. The default
  policy is `code_phase_cap_policy: escalate`.
- Restart recovery should reconstruct from the event log, PRs, and branch tips.
  A CODE phase that is frozen but not merged must resume from the held-open CODE
  PR and recorded tree hash.
- Treat agent prose as audit text only. Machine decisions come from structured
  trailers and GitHub review state.

## Repo Hygiene

- Keep generated task data under `.duet/`; it is ignored by Git.
- Keep this repository focused on Duet-Symphony. Do not reintroduce Bacos
  monorepo-specific paths except in historical notes.
- Do not add unrelated cost, token counting, billing, or IDE-extension features.
