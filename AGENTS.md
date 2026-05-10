# AGENTS.md

This repository contains the standalone Duet-Symphony design. It was extracted
from the Bacos skills monorepo so future work should happen here.

## Project Intent

Duet-Symphony is intended to be OpenAI Symphony with a Claude/Codex
worker and operator-selected routing profiles. Keep Symphony's feature set and
operating model wherever possible:
tracker-driven dispatch, isolated workspaces, lifecycle hooks, retry/backoff,
reconciliation, remote-worker support, logs, and dashboard/API. The goal is
strict sequential collaboration inside each claimed Symphony task: one agent
authors an artifact, the other reviews it, and the loop continues until both
approve the same Git revision. Claude-only, Codex-only, and custom profiles are
allowed for degraded/operator-assisted runs, but they do not satisfy full Duet
convergence without a second binding review.
- Human checkpoints are additive gates, not replacements for Claude/Codex
  convergence. A full Duet run can still require human approval after SPEC,
  PLAN, CODE, or REVIEW.

This is not Council. Council is multi-model parallel deliberation; Duet's full
mode is Claude and Codex in alternating author/reviewer roles with GitHub PRs
as the artifact and convergence substrate.

## Current State

- Design/spec only. There is no implementation yet.
- `spec/SPEC.md` is the source of truth.
- The current target is Symphony parity plus Duet pair-runtime behavior, not a
  reduced local CLI MVP.
- Preserve upstream compatibility. Prefer a fork/subtree/overlay strategy that
  keeps OpenAI Symphony's orchestrator, tracker, workspace, hook, retry, remote
  worker, and observability code close to upstream.
- The branch topology in the spec intentionally uses separate namespaces:
  `duet-base/<task_id>` for the long-lived task branch and
  `duet-phase/<task_id>/<phase>` for phase PR branches. Do not change this back
  to `duet/<task_id>` plus `duet/<task_id>/spec`; that ref layout is invalid in
  Git.
- `github_bot` is specified, but current Claude workflows from the source repo
  are only examples. A conformant bot flow must produce parseable Duet trailers
  and/or GitHub review states.

## Next Implementation Step

Study and import the OpenAI Symphony implementation with the smallest possible
Duet patch set:

1. Add OpenAI Symphony as an upstream remote, subtree, or vendored baseline and
   preserve Apache-2.0/NOTICE attribution.
2. Identify the narrow worker boundary around Symphony's `AgentRunner` and keep
   the existing single-Codex runner as compatibility mode.
3. Add a `duet_pair` runtime that coordinates Claude + Codex while emitting
   Symphony-compatible worker updates.
4. Add the initial operator routing menu/UI so a task can choose Claude,
   Codex, both, human checkpoints, or a custom per-phase profile before
   dispatch.
5. Keep `WORKFLOW.md` as the primary repo-owned workflow contract and add Duet
   settings under a `duet:` front-matter key.
6. Use Codex App Server for the Codex half first; add Codex Cloud as an
   optional asynchronous runtime once the local pair loop works.
7. Use Claude Code structured print/resume/streaming or GitHub bot mode for the
   Claude half; do not rely on fragile TTY automation unless no better option
   exists.
8. Parse only the final `---DUET-TRAILER---` block from each agent response and
   persist structured events to `.duet/logs/tasks/<task_id>/events.jsonl`.
9. Add optional SuperPower artifact support under `docs/superpowers/` for
   SPEC/PLAN/REVIEW, keeping `.duet/` as the machine-state source of truth.

## Known Design Constraints

- Claude-side and Codex-side GitHub operations need distinct GitHub identities
  for binding PR approvals. A single shared bot account is not enough for the
  split-signal convergence model.
- Single-agent routing profiles are explicitly degraded. They are useful for
  local drafting or operator-directed runs, but must not be presented as full
  Duet convergence unless a second binding review is supplied.
- CODE must not auto-merge reviewer-rejected code by default. The default
  policy is `code_phase_cap_policy: escalate`.
- Restart recovery should reconstruct from the event log, PRs, and branch tips.
  A CODE phase that is frozen but not merged must resume from the held-open CODE
  PR and recorded tree hash.
- Treat agent prose as audit text only. Machine decisions come from structured
  trailers and GitHub review state.
- A pure plugin without touching Symphony is likely not enough unless upstream
  exposes a stable worker runtime extension point. Assume a small maintained
  fork/patch stack.

## Repo Hygiene

- Keep generated task data under `.duet/`; it is ignored by Git.
- Keep this repository focused on Duet-Symphony. Do not reintroduce Bacos
  monorepo-specific paths except in historical notes.
- Do not add unrelated cost, token counting, billing, or IDE-extension features.
