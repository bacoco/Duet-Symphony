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
  A stale runtime selection (profile removed from `WORKFLOW.md` after
  selection) is auto-cleared with a warning log on the next dispatch.
- The first trailer parser slice is in place: `SymphonyElixir.Duet.Trailer`
  decodes the spec §10.1 response trailer, picks the last syntactically
  valid block when several are present, enforces the 50-line position
  limit (§10.1.2), and surfaces semantic issues (`:low_confidence_approve`,
  `:synthesized_no_details`, `{:approve_with_unresolved, original}`) so the
  orchestrator can re-prompt or annotate per spec §10.1.1. Not yet wired
  into PairRunner.
- The first turn recorder slice is in place: `SymphonyElixir.Duet.Turn`
  joins `Duet.Trailer` and `Duet.EventLog`. `record_request/5` emits
  `turn_request`; `record_response/6` parses the trailer and emits
  `turn_response` (success), `trailer_rejected` (missing/malformed/
  position_invalid), or `low_confidence_approve` (warning) per spec
  §13.1, while binding the tree-hash to the orchestrator-supplied
  value rather than any agent-claimed hash. It is wired for the first
  Codex SPEC Author turn only.
- The first phase-prompt builder slice is in place:
  `SymphonyElixir.Duet.PhasePrompt.build/1` produces a deterministic
  Author/Reviewer prompt for a given phase + cycle + role + routing
  profile, embeds the §10.1 trailer schema verbatim, and surfaces the
  §10.1.2 position rule. Implementation-defined per §17. Operator
  description input is now bounded at the spec §14 default of 50 000
  chars (configurable per-call via `:max_description_chars`).
- The pair-loop scaffolding slices are in place:
  `Duet.TurnDriver` is the `@behaviour` future Codex/Claude drivers
  implement (`drive_turn(prompt, opts)`); `Duet.TurnDrivers.Mock`
  provides a stub for tests; `Duet.TurnDrivers.CodexAppServer`
  drives a real Codex App Server turn and collects streamed
  `agent_message*` deltas into response text; `Duet.TurnDrivers.ClaudeCode`
  invokes Claude Code with `--print --output-format stream-json` and
  parses assistant stream events into response text. `Duet.Branches`
  computes the §6.1 / §9.1 branch names and validates §5.2 task IDs.
  `Duet.PhaseFreezeMessage.build/1` renders the §8.4 freeze text and
  `summary_word_target/2` returns the adaptive word budget per §8.4.
  `Duet.Transcripts.write/6` persists the §13.2 per-turn prompt+response
  to `<log_dir>/tasks/<task_id>/transcripts/<phase>-<cycle>-<actor>.md`.
  `PairRunner` now consumes these pieces for the first real SPEC
  Author→Reviewer loop.
- The first wave-8 PairRunner slice is in place:
  `PairRunner` resolves the selected SPEC author/reviewer actors, selects
  their `TurnDriver`s, records `turn_request` / `turn_response`, writes
  transcripts, evaluates `Duet.ConvergenceOrchestrator`, continues cycles
  after reviewer `REQUEST_CHANGES`, and emits `phase_frozen` on SPEC
  convergence. A frozen SPEC currently stops future continuation dispatch
  with `{:error, :plan_not_implemented}` because PLAN is not wired yet.
- The convergence-engine pure helpers are in place:
  `Duet.Convergence` implements the §9.3 split-signal mapping and the
  §10.2 convergence rule (both APPROVE on same tree-hash);
  `Duet.CycleCap` covers the §10.3 counter and §10.4 tie-breakers
  (SPEC/PLAN forced freeze, CODE escalate/forced/fail policies, plus
  operator override resolution); `Duet.PathologicalDisagreement.detect/1`
  flags three consecutive cycles with equal `unresolved` after
  normalization (§10.5); `Duet.ConvergenceOrchestrator` combines these
  into the pure next-action decision (`freeze`, `continue`,
  `awaiting_operator`, `fail`) for the future phase driver;
  `Duet.Identity` resolves per-actor GitHub
  identities from app env / `DUET_*_GITHUB_IDENTITY` env vars and
  validates the §9.3 distinct-identity requirement (`Config.Schema`
  wiring is a future slice); `Duet.PhaseSummary` provides the v1 §8.4
  truncation strategy (`word_count/1`, `diff_line_count/1`,
  `summarize/2`). None wired into PairRunner yet.
- The phase-pipeline + v0.4 opt-in pure helpers are in place:
  `Duet.Metrics` derives §13.5 convergence metrics from the event log
  (`for_phase/2`, `for_task/1`, `forced_rate/2`); `Duet.PhaseTransition`
  encodes §8.2 ordering and §8.3 freeze actions (including CODE held
  open vs SPEC/PLAN merged); `Duet.HumanCheckpoint` reads the §8.6
  config (`mode_for_phase/2`, `resolve_decision/2`, REVIEW
  `:request_changes` returns to CODE per spec); `Duet.ToolProfile`
  resolves §7.8 tool-profile constraints (`resolve/4`, `resolve/5`,
  `allows?/5`, `validate_config/1`, `known_tools/0` for the §17
  implementation-defined identifier set); `Duet.VerificationGate`
  provides the §8.7 data layer (`aggregate_status/1`, `build_block/2`,
  `timeout_block/1`, `validate_config/1`). `Config.Schema.Duet` now
  parses and validates `tool_profiles`, `verification_gate`, and
  `superpower`. None wired into PairRunner yet.
- The operator-gate + GitHub-integration pure helpers are in place:
  `Duet.AwaitingOperator` enumerates the 7 spec-defined
  `awaiting_operator` reasons and translates each (reason, decision)
  to the canonical orchestrator action (REVIEW `:request_changes`
  returns to CODE; `:phase_cap_escalation` produces
  `:operator_override_*` freeze modes). `Duet.PR` produces the §9.4
  PR title and body (description bounded at 50 000 chars per §14).
  `Duet.GithubReview` parses the GitHub PR Reviews API JSON, picks
  the latest non-dismissed review per identity per §11.1, and exposes
  the §9.3 binding-state mapping. `Duet.SuperPower` resolves §8.5
  artifact mode (mirror/enforce), per-phase enablement, and
  `<root>/<specs|plans|code|reviews>/<task_id>.md` paths.
  `Duet.PRConflict` decides §8.3.1 mergeability of the held-open
  CODE PR with `:mergeable` / `{:conflict, ...}` / `{:retry_later, ...}`
  results and builds the `code_pr_conflict` event payload. `Duet.GhCli`
  is a pure argv-building wrapper around `gh` for PR open/ready/merge,
  author comments, reviewer reviews, review listing, and mergeability.
  `Duet.RoutingOverride` adds per-task routing overrides with
  `routing_override_applied` events. `Duet.NotificationHook` defines the
  no-op default hook surface for operator/failure notifications.
  `Duet.CredentialRedaction` centralizes §14 transcript redaction and is
  used by `Duet.Transcripts`. None wired into PairRunner yet.
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
9. Auto-clear stale operator selections when the named profile is removed
   from `WORKFLOW.md`, falling back to the configured default.
10. Add the first Duet trailer parser (`SymphonyElixir.Duet.Trailer`) covering
    §10.1 syntax, §10.1.2 position rule, and §10.1.1 semantic checks, with no
    orchestrator wiring yet.
11. Add the first Duet turn recorder (`SymphonyElixir.Duet.Turn`) joining
    `Duet.Trailer` and `Duet.EventLog`. Emits `turn_request`,
    `turn_response`, `trailer_rejected`, and `low_confidence_approve` events
    per spec §13.1 with orchestrator-bound tree-hash, no orchestrator wiring
    yet.
12. Add the first Duet phase-prompt builder
    (`SymphonyElixir.Duet.PhasePrompt`) producing Author/Reviewer prompts
    that embed the spec §10.1 trailer template and the §10.1.2 position
    rule; pure, deterministic, implementation-defined per §17, no wiring
    yet.
13. Add `Duet.TurnDriver` behaviour + `Duet.TurnDrivers.Mock` so future
    Codex/Claude drivers plug in behind a stable contract.
14. Add `Duet.Branches` pure helpers for §6.1 / §9.1 branch names and §5.2
    task_id validation. Phase branches only cover SPEC/PLAN/CODE; REVIEW
    shares the CODE PR per §8.1.
15. Add `Duet.PhaseFreezeMessage` to render the spec §8.4 phase-freeze
    message, plus `summary_word_target/2` for the §8.4 adaptive summary
    budget.
16. Add `Duet.Transcripts.write/6` to persist spec §13.2 per-turn
    transcripts under `<log_dir>/tasks/<task_id>/transcripts/`. Root
    delegates to `Duet.EventLog.root/0` so `--logs-root` relocates them.
17. Bound `issue_description` rendering in `Duet.PhasePrompt` at the
    spec §14 default of 50 000 chars (per-call override via
    `:max_description_chars`), with a `[truncated to <max> chars per
    spec §14]` marker.
18. Add `Duet.Convergence` (§9.3 + §10.2 split-signal evaluation),
    `Duet.CycleCap` (§10.3 + §10.4 cycle counter and tie-breaker),
    `Duet.PathologicalDisagreement` (§10.5 detector),
    `Duet.Identity` (§9.3 distinct GitHub identity per actor with env
    var + app env fallback), and `Duet.PhaseSummary` (§8.4 v1
    truncation summary helpers). All pure, no orchestrator wiring yet.
19. Add `Duet.Metrics` (§13.5 convergence metrics derived from the event
    log), `Duet.PhaseTransition` (§8.2 + §8.3 phase pipeline state
    machine + freeze actions), `Duet.HumanCheckpoint` (§8.6 config
    resolver + decision mapping), `Duet.ToolProfile` (§7.8 tool-profile
    resolver + validator), and `Duet.VerificationGate` (§8.7 block
    builder + status aggregator). All pure, no orchestrator wiring yet;
    schema wiring for `tool_profiles` and `verification_gate` config
    blocks is a deliberate follow-up.
20. Add `Duet.AwaitingOperator` (the 7-reason / decision dispatch
    table for §8.3, §8.3.1, §8.5, §8.6, §8.7, §10.4.2, §11.1
    operator gates), `Duet.PR` (§9.4 PR title and body),
    `Duet.GithubReview` (parser for `gh api .../pulls/<n>/reviews`
    with §11.1 latest-non-dismissed-per-identity reduction),
    `Duet.SuperPower` (§8.5 mode + path resolver, validate_config),
    and `Duet.PRConflict` (§8.3.1 mergeability decider + event attrs).
    All pure, no orchestrator wiring yet.
21. Add `Duet.TurnDrivers.CodexAppServer` and wire the first Codex SPEC
    Author turn through `PairRunner` for profiles whose SPEC Author is
    `codex`; the runner now records request/response events and
    transcripts for that one turn, then stops before the missing reviewer.
22. Finish the remaining wave-6 pure helpers: v0.4 config schema wiring,
    centralized §14 credential redaction, `ConvergenceOrchestrator`,
    per-task routing overrides, `gh` CLI wrapper, and notification hook
    surface. Still no PairRunner wiring beyond the existing Codex SPEC
    Author half-turn.
23. Add `Duet.TurnDrivers.ClaudeCode`, a tested Claude Code CLI adapter
    behind `Duet.TurnDriver`. It uses the spec-backed
    `--print --output-format stream-json` command shape, sends prompts on
    stdin, parses assistant/result stream events into response text, and
    exposes an injectable runner for tests. Not wired into `PairRunner` yet.
24. Wire the first real SPEC phase pair loop in `PairRunner`: configured
    Author and Reviewer actors dispatch through `TurnDriver`, responses are
    recorded/transcribed, convergence/cycle-cap/pathological helpers decide
    continue/freeze/fail, and converged SPEC emits `phase_frozen`. PLAN is
    still not implemented.

Next slice:

1. Extend the phase driver from SPEC to PLAN: start PLAN after a frozen SPEC,
   reuse the same Author/Reviewer loop, preserve idempotent recovery from
   existing events, and stop before CODE wiring.

Subsequent slices:

1. Add Codex Cloud as an
   optional asynchronous runtime once the local pair loop works.
2. Keep Claude Code structured print/stream-json as the Claude runtime path;
   do not rely on fragile TTY automation unless no better option exists.
3. Add optional SuperPower artifact support under `docs/superpowers/` for
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
