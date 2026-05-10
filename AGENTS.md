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

- `spec/SPEC.md` is the source of truth.
- `elixir/` contains the Symphony-derived Elixir implementation imported from
  OpenAI Symphony. It preserves Apache-2.0 license/NOTICE attribution.
- The first Duet implementation slice is in place: the escript binary is
  `duet-symphony`, `Config.Schema` parses a minimal `duet:` block,
  `RunnerSelector` keeps `AgentRunner` as the default compatibility runner,
  and `Duet.PairRunner.run/3` is a tested `{:error, :not_implemented}` stub.
- The shared runner runtime slice is also in place: `RunnerRuntime` owns
  worker-host selection, workspace creation, runtime notifications, and
  run hooks for both `AgentRunner` and `Duet.PairRunner`.
- The first routing/config slice is in place: `Config.Schema.Duet` parses core
  phase-control settings, and `SymphonyElixir.Duet.Routing` validates and
  resolves built-in/custom routing profiles.
- The first `.duet` persistence/recovery slices are in place: `Duet.EventLog`
  writes JSONL under `.duet/logs/tasks/<task_id>/events.jsonl`, `PairRunner`
  emits the initial `task_started`, `agent_routing_selected`, and
  `phase_started` events idempotently plus the current stub `task_failed`
  marker, and `Duet.TaskState` reconstructs task/phase state while surfacing
  routing divergence without discarding recovered state.
- The first operator routing menu slice is in place: the observability
  dashboard and `/api/v1/duet/routing` can select the runtime Duet profile
  from the configured profiles, and `PairRunner` consumes that selection.
- Full Claude/Codex duet orchestration is not implemented yet.
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
- `elixir/AGENTS.md` is OpenAI Symphony's upstream contributor guide preserved
  as part of the imported baseline. This root `AGENTS.md` is the canonical
  guidance for Duet-Symphony work.

## Next Implementation Step

Follow `IMPLEMENTATION.md` for the exact upstream sync procedure, imported SHA
tracking, licensing requirements, and implementation checkpoints. Stay on
`main` unless the user explicitly asks for a branch.

Completed first slice:

1. Import upstream Symphony's `elixir/` subtree under local `elixir/` and
   preserve Apache-2.0 license/NOTICE attribution.
2. Run the upstream baseline tests before any rename.
3. Rename the escript binary from `symphony` to `duet-symphony`, sweep test
   references with `rg "symphony" elixir/test`, and rerun tests.
4. Add `duet:` config parsing to `Config.Schema` without removing existing
   Symphony config.
5. Add a runner selector that keeps the existing single-Codex `AgentRunner` as
   the default compatibility mode.
6. Add `Duet.PairRunner.run/3` only as a tested stub returning
   `{:error, :not_implemented}` when `duet.enabled: true`.
7. Stabilize the initial event log/recovery contract: PairRunner startup
   events are idempotent across retries, the stub records `task_failed`, and
   `TaskState.recover/2` returns recovered state even when routing diverges.
8. Add the first operator routing menu/API so a runtime can choose the active
   Duet profile before future tasks dispatch.

Next slice:

1. Use Codex App Server for the Codex half of the real pair loop while keeping
   the existing `AgentRunner` compatibility path intact.

Subsequent slices:

1. Add Codex Cloud as an
   optional asynchronous runtime once the local pair loop works.
2. Use Claude Code structured print/resume/streaming or GitHub bot mode for the
   Claude half; do not rely on fragile TTY automation unless no better option
   exists.
3. Parse only the final `---DUET-TRAILER---` block from each agent response and
   persist structured events to `.duet/logs/tasks/<task_id>/events.jsonl`.
4. Add optional SuperPower artifact support under `docs/superpowers/` for
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
