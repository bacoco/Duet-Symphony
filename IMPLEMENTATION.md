# Duet-Symphony Implementation Plan

This document records the upstream import strategy and implementation
checkpoints for the Symphony-derived Elixir code. The normative behavior
remains in `spec/SPEC.md`.

## Checkpoint 1: Upstream Symphony Baseline

- Upstream remote: `https://github.com/openai/symphony.git`
- Upstream implementation language: Elixir/OTP
- Upstream runtime pin: see `elixir/mise.toml`
  - Erlang: `28`
  - Elixir: `1.19.5-otp-28`
- Main implementation subtree upstream: `elixir/`
- Upstream license: Apache-2.0

The imported implementation lives under `elixir/`. Keep `spec/` standalone and
avoid merging upstream root files over this repo's root project surface.

## Sync History

| Local step | Upstream ref | Upstream SHA | Local path | Notes |
|------------|--------------|--------------|------------|-------|
| Strategy inspection | `upstream/main` | `58cf97da06d556c019ccea20c67f4f77da124bf3` | none | Read-only inspection; no upstream code imported |
| Initial subtree import | `upstream/main` | `58cf97da06d556c019ccea20c67f4f77da124bf3` | `elixir/` | Imported upstream `elixir/` subtree; preserved Apache-2.0 files as `elixir/LICENSE` and `elixir/NOTICE` |

Each future import or upgrade MUST add a row to this table with the exact
upstream SHA that was imported.

## Upstream Sync Mechanism

Use a subtree split of upstream's `elixir/` directory, then import that split
under this repo's local `elixir/` path. Do not merge upstream root files over
this repo's root files.

Initial import procedure:

```bash
git fetch upstream main
git rev-parse upstream/main  # record this SHA in Sync History before importing
git branch -D upstream-elixir-split || true
git subtree split --prefix=elixir upstream/main -b upstream-elixir-split
git subtree add --prefix=elixir upstream-elixir-split --squash
```

Upgrade procedure:

```bash
git fetch upstream main
git rev-parse upstream/main  # record this SHA in Sync History before upgrading
git branch -D upstream-elixir-split || true
git subtree split --prefix=elixir upstream/main -b upstream-elixir-split
git subtree pull --prefix=elixir upstream-elixir-split --squash
```

The imported subtree contains only upstream's `elixir/` contents. Because the
upstream Apache-2.0 `LICENSE` and `NOTICE` files live at the upstream repo
root, the import commit MUST also preserve them as:

- `elixir/LICENSE`
- `elixir/NOTICE`

The import commit MUST update this document's sync history and the root
`NOTICE` in the same commit.

## Import Scope

Import the upstream Elixir implementation into this repo under `elixir/`, not
as a full root-level merge. Keep `spec/` standalone and untouched.

The import should include:

- `upstream/main:elixir/` -> local `elixir/`
- upstream `LICENSE` preserved under `elixir/LICENSE`
- upstream `NOTICE` preserved under `elixir/NOTICE`

Do not import upstream `.codex/skills/*` in the first slice. The upstream
skills are useful for OpenAI Symphony's own workflow, but they are not required
for the Elixir service baseline or the first Duet runner-selector milestone.
Future skill imports must be explicit, must preserve provenance, and should
either live under a clearly attributed upstream path or be rewritten as
Duet-specific skills.

Do not merge upstream root files over this repo's root `README.md`,
`spec/SPEC.md`, `LICENSE`, or `NOTICE`. This repo's root remains the Duet
project surface; OpenAI Symphony provenance is preserved inside the imported
implementation and in the root `NOTICE`.

## Boundary Verification

Inspection was performed against upstream SHA
`58cf97da06d556c019ccea20c67f4f77da124bf3`.

Observed boundary:

- `SymphonyElixir.Orchestrator` dispatches work with:
  `AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)`.
- `SymphonyElixir.AgentRunner.run/3` has this effective signature:
  `run(map(), pid() | nil, keyword()) :: :ok | no_return()`.
- `AgentRunner` creates the workspace internally via
  `Workspace.create_for_issue(issue, worker_host)`.
- `AgentRunner` then runs `Workspace.run_before_run_hook/3`, starts a Codex
  App Server session, builds prompts through `PromptBuilder`, runs Codex turns,
  streams updates back to the orchestrator, and finally runs
  `Workspace.run_after_run_hook/3`.
- The workspace is not currently passed into `AgentRunner`; it is created
  inside the runner.

Conclusion: `AgentRunner` is still the smallest useful first boundary because
the orchestrator already treats it as the worker execution unit. However, the
real `Duet.PairRunner` must not duplicate workspace lifecycle logic. Before a
real PairRunner is implemented, shared workspace/run setup should be extracted
from `AgentRunner` or delegated through a common helper. The first slice uses a
stub PairRunner precisely to avoid duplicating this lifecycle prematurely.

## Recommended Implementation Strategy

Symphony's current implementation already has the right layering for Duet:

- `SymphonyElixir.Orchestrator` owns polling, dispatch, retries, worker
  lifecycle, status tracking, and dashboard updates.
- `SymphonyElixir.Workspace` owns isolated workspace creation, hooks, remote
  worker support, and cleanup.
- `SymphonyElixir.Config.Schema` owns typed `WORKFLOW.md` config parsing and
  validation.
- `SymphonyElixir.Codex.AppServer` is a narrow Codex App Server adapter.
- `SymphonyElixir.AgentRunner` is the runner boundary called by the
  orchestrator.

The first Duet implementation should add a runner selector and a stub
`Duet.PairRunner` while leaving the orchestrator, tracker, workspace, hooks,
remote worker, dashboard, and retry mechanics close to upstream.

## First Implementation Slice After Import

1. Import upstream `elixir/` and preserve Apache-2.0 license/notice files.
2. Run the upstream baseline tests before renaming the binary.
3. Rename the escript binary from `symphony` to `duet-symphony`, then run the
   tests again. Before the rename, sweep test references with
   `rg "symphony" elixir/test`.
4. Add `duet:` config parsing to `Config.Schema` without removing existing
   Symphony config.
5. Add a runner selector:
   - default compatibility mode: existing single Codex `AgentRunner`
   - Duet mode: new `Duet.PairRunner`
6. Keep `Duet.PairRunner.run/3` as a stub that returns
   `{:error, :not_implemented}`. Do not implement Claude, trailers, PR
   convergence, or phase persistence in this slice.
7. Add unit tests for config parsing and runner selection.

This keeps the first executable milestone small: upstream Symphony still runs,
and Duet-specific behavior is introduced behind config.

## First Slice Exit Criteria

The first slice is complete only when all of these are true:

1. Imported `elixir/` baseline runs its upstream test suite successfully with
   the binary still named `symphony`.
2. The binary is renamed to `duet-symphony` and the test suite passes again.
3. `Config.Schema` accepts a `WORKFLOW.md` front matter block with `duet:`
   settings and preserves existing Symphony config behavior.
4. `RunnerSelector.choose/1` returns the existing `AgentRunner` by default.
5. `RunnerSelector.choose/1` returns `Duet.PairRunner` when
   `duet.enabled: true`.
6. `Duet.PairRunner.run/3` is a tested stub returning
   `{:error, :not_implemented}`.
7. Unit tests cover `duet:` config parsing and runner selection.

Full Claude/Codex duet orchestration is explicitly outside this first slice.

## First Slice Status

The first slice is complete.

- Baseline import was validated before local Duet edits. The local baseline had
  one isolated upstream timing flake, documented below, and the GitHub Actions
  baseline passed on the pinned Erlang/Elixir versions.
- The escript binary is renamed from `symphony` to `duet-symphony`; `mix build`
  creates `bin/duet-symphony` and no `bin/symphony`.
- `Config.Schema` accepts a `duet:` front matter block with `enabled: true` and
  still defaults to the existing Symphony behavior when the block is absent.
- `RunnerSelector.choose/1` returns `AgentRunner` by default and
  `Duet.PairRunner` when `duet.enabled: true`.
- `Duet.PairRunner.run/3` remains a tested stub returning
  `{:error, :not_implemented}`.
- Verification after the slice: `mix format --check-formatted`, targeted unit
  tests, and full `mix test` all pass locally.

> [!WARNING]
> Do not enable `duet: enabled: true` in a production `WORKFLOW.md` until
> the pair loop is implemented. While `Duet.PairRunner` is a stub, the
> shared runner runtime can create workspaces and run hooks before returning
> `{:error, :not_implemented}`. The orchestrator dispatch wrapper then raises,
> which crashes the issue task and triggers the standard retry policy. Every
> claimed issue will burn the retry budget without producing useful work. The
> stub writes an idempotent `task_failed` marker so recovery surfaces the task
> as failed instead of indefinitely running.

The shared runtime extraction below completes the workspace lifecycle
prerequisite before real Claude/Codex behavior is added to `Duet.PairRunner`.

## Shared Runner Runtime Status

The shared workspace lifecycle extraction is complete.

- `RunnerRuntime.run/5` now owns worker-host selection, workspace creation,
  worker runtime notifications, `before_run` hooks, and `after_run` hooks.
- `AgentRunner` delegates to `RunnerRuntime` and retains ownership of Codex
  App Server sessions, prompt construction, continuation turns, and active issue
  refresh.
- `Duet.PairRunner` delegates to `RunnerRuntime` before returning its current
  `{:error, :not_implemented}` stub result. This proves the future pair runner
  will use the same workspace and hook semantics as the Symphony-compatible
  runner.
- Verification covers `PairRunner` creating a workspace, emitting
  `worker_runtime_info`, and running `after_create`, `before_run`, and
  `after_run` hooks before the stub returns.

The next implementation slice can now focus on Duet phase/routing state instead
of re-solving workspace lifecycle.

## Duet Routing Config Status

The first routing/config slice is complete.

- `Config.Schema.Duet` now parses the core Duet phase-control fields:
  `max_cycles_per_phase`, `phase_turn_timeout_ms`,
  `phase_total_timeout_ms`, `code_phase_cap_policy`, `pause_on_freeze`,
  `agent_menu`, `agent_routing`, and `human_checkpoints`.
- `SymphonyElixir.Duet.Routing` resolves the effective routing profile from
  `duet.agent_routing`, including built-in `duet_balanced`,
  `codex_only_dev`, and `claude_only_dev` profiles.
- Full Duet profiles are validated to require distinct Claude/Codex machine
  signals for SPEC, PLAN, and CODE. A full Duet Reviewer list must not include
  the Author. Profiles that intentionally skip reviewers remain valid only as
  degraded profiles.
- No external Claude/Codex calls are introduced in this slice.

## Duet Event Log Status

The first `.duet` persistence and recovery slices are complete.

- `SymphonyElixir.Duet.EventLog` appends and reads newline-delimited JSON under
  `.duet/logs/tasks/<task_id>/events.jsonl`.
- `--logs-root` now also relocates the Duet event log root to
  `<logs_root>/.duet/logs`.
- `Duet.PairRunner` emits `task_started`, `agent_routing_selected`, and
  `phase_started` for the initial `SPEC` phase before returning its current
  stub result. These initial events are idempotent across runner retries.
- While the pair runner remains a stub, it records one `task_failed` event with
  `reason = "not_implemented"` before returning `{:error, :not_implemented}`.
- `SymphonyElixir.Duet.TaskState` reconstructs task status, current phase,
  per-phase state, event count, and routing from the append-only log.
- Recovery compares the recorded routing selection with the current resolved
  `duet.agent_routing` profile and keeps the recovered state available with
  `routing_status = "diverged"` when they differ.
- No Claude/Codex runtime calls are introduced in this slice.

## Duet Routing Menu Status

The first operator routing menu slice is complete.

- `SymphonyElixir.Duet.RoutingSelection` exposes configured profiles, stores a
  runtime-selected profile in application state, and resolves the effective
  profile used by `PairRunner`.
- `GET /api/v1/duet/routing` returns the available profiles, selected profile,
  selection source, effective phase matrix, menu settings, and human
  checkpoint settings.
- `POST /api/v1/duet/routing` accepts `profile_name` and updates the runtime
  selection after validating the profile exists in `duet.agent_routing`.
- The LiveView dashboard renders a Duet routing section with a profile select
  control and the effective SPEC/PLAN/CODE/REVIEW matrix.
- This slice is runtime-global rather than per-task. A future dispatch gate
  must persist per-task overrides with `routing_override_applied` when
  `require_selection_before_dispatch` is enforced.
- A stale operator selection (profile removed from `WORKFLOW.md` after
  selection) is detected on the next `selected_profile_name/1` call,
  cleared from runtime state with a warning log, and falls back to the
  configured `default_profile`.
- No external Claude/Codex calls are introduced in this slice.

## Duet Trailer Parser Status

The first Duet trailer parsing slice is complete.

- `SymphonyElixir.Duet.Trailer.parse/1` decodes the structured response
  trailer defined in spec §10.1 into a `%Trailer{}` struct with
  `verdict`, `confidence`, `summary`, and `unresolved` fields.
- When several `---DUET-TRAILER---` blocks appear in a response, only the
  last syntactically valid block is considered. A malformed final block
  followed by an earlier valid one falls back to the earlier valid block.
- The trailer must start within the final 50 lines of the response;
  otherwise `parse/1` returns `{:error, :position_invalid}` so the
  orchestrator can emit a `trailer_rejected` event and re-prompt.
- Semantic checks from §10.1.1 are surfaced as a list of issues alongside
  the parsed trailer:
  - `:low_confidence_approve` for APPROVE with `confidence < 0.3`.
  - `:synthesized_no_details` when REQUEST_CHANGES had an empty
    `unresolved` list (the field is rewritten to `["no_details_provided"]`).
  - `{:approve_with_unresolved, original}` when APPROVE arrived with a
    non-empty unresolved list, preserving the original list for the
    orchestrator's re-prompt/REQUEST_CHANGES fallback path.
- `tree_hash` is intentionally NOT part of the schema: per §10.1.2 the
  orchestrator binds the trailer to the commit tree-hash observed at
  dispatch time, never to any agent-supplied hash.
- No orchestrator wiring or new event kinds are introduced in this slice;
  consumption of the parsed trailer comes with the Codex pair-loop slice.

## Duet Turn Recorder Status

The first Duet turn recorder slice is complete.

- `SymphonyElixir.Duet.Turn.record_request/5` appends a `turn_request`
  event with phase, cycle, actor, and the orchestrator-supplied
  tree-hash and PR number.
- `SymphonyElixir.Duet.Turn.record_response/6` parses the agent
  response via `Duet.Trailer.parse/1`. On success it appends a
  `turn_response` event capturing the verdict, confidence, summary,
  unresolved list, tree-hash, and PR number, and returns
  `{:ok, %Turn{}, [issue]}` so callers can re-prompt or annotate per
  spec §10.1.1.
- When the trailer is missing, malformed, or placed earlier than the
  last 50 lines (§10.1.2), `record_response/6` appends a
  `trailer_rejected` event with the rejection reason and returns
  `{:error, reason}` to the caller.
- `:low_confidence_approve` issues are mirrored into a dedicated event
  alongside the `turn_response`, matching the §10.1.1 warning channel.
- The tree-hash is bound by the caller, never trusted from agent
  output (§10.1.2).
- Still no orchestrator wiring; PairRunner does not yet consume
  `Duet.Turn`. The Codex pair-loop slice will plug it in as the
  per-turn convergence step.

## Duet Phase Prompt Builder Status

The first Duet phase-prompt builder slice is complete.

- `SymphonyElixir.Duet.PhasePrompt.build/1` constructs a deterministic
  pair-loop prompt for an Author or Reviewer given a typed context
  (task identity, phase, cycle, role, actor, counterpart, active
  routing profile, prior frozen-phase summaries, current artifact,
  prior reviewer feedback).
- The output embeds the spec §10.1 trailer template verbatim and
  surfaces the §10.1.2 "last 50 lines" position rule directly in the
  instruction block, so a compliant agent has the schema in front of it
  every turn.
- Role-specific phrasing covers Author/Reviewer for SPEC, PLAN, CODE,
  plus REVIEW's split-signal constraints (`coder_ack` cannot
  GitHub-APPROVE its own PR per §9.3; `review_reviewer` performs the
  fresh-context independent review).
- The prompt header records `task_id`, `cycle`, `actor`, `role`,
  `profile`, and `mode`, so an audit reader can correlate any captured
  prompt with the matching `agent_routing_selected` and
  `turn_request`/`turn_response` events.
- The builder is implementation-defined per §17. No I/O, no event
  emission, no orchestrator wiring; the Codex pair-loop slice will be
  the first consumer.

## Pair-Loop Scaffolding Status

The TurnDriver, Branches, PhaseFreezeMessage, Transcripts, and
description-length-bound slices are complete. They prepare the seams
needed by the Codex App Server pair loop; the first Codex SPEC Author
turn now consumes those seams through `PairRunner`.

- `SymphonyElixir.Duet.TurnDriver` is a `@behaviour` with one callback
  `drive_turn(prompt, opts) :: {:ok, response} | {:error, term()}`.
  `SymphonyElixir.Duet.TurnDrivers.Mock` is the in-process implementation
  used by tests and stubs: it returns `opts[:response]` if a binary,
  otherwise `opts[:error]`, otherwise `{:error, :no_canned_response}`.
  `SymphonyElixir.Duet.TurnDrivers.CodexAppServer` is the first real
  implementation behind the same behaviour; it delegates session and
  tool handling to `SymphonyElixir.Codex.AppServer` and collects streamed
  Codex agent-message deltas into the raw response text consumed by
  `Duet.Turn.record_response/6`.
- `SymphonyElixir.Duet.Branches` exposes pure helpers for the spec §6.1
  / §9.1 branch topology and the §5.2 `task_id` regex:
  `base_branch/1`, `phase_branch/2` (only `:spec`/`:plan`/`:code` —
  REVIEW shares the CODE PR per §8.1), `valid_task_id?/1`,
  `validate_task_id/1`, `base_prefix/0`, `phase_prefix/0`. Prefixes are
  hardcoded to spec defaults (`duet-base` / `duet-phase`); reading them
  from `WORKFLOW.md` is a future slice.
- `SymphonyElixir.Duet.PhaseFreezeMessage.build/1` renders the spec §8.4
  text exactly, with the three blocks (header / summary / tail) joined
  by blank lines. Terminal REVIEW freezes omit the
  `Next phase:` / `Your role next phase:` lines per spec semantics.
  `summary_word_target/2` returns the §8.4 adaptive target:
  `min(1500, words × 0.5)` for SPEC/PLAN, `min(3000, diff_lines × 2)`
  for CODE, both clamped to a 300-word floor. The summary text itself
  is generated upstream by the orchestrator and passed in.
- `SymphonyElixir.Duet.Transcripts.write/6` writes spec §13.2 per-turn
  transcripts to `<log_dir>/tasks/<task_id>/transcripts/<phase>-<cycle>-<actor>.md`,
  delegating root resolution to `Duet.EventLog.root/0` so `--logs-root`
  relocates them automatically. Re-prompts within the same
  `(phase, cycle, actor)` triple overwrite the file; multi-attempt
  audit lives in the event log.
- `Duet.PhasePrompt` now bounds `issue_description` at a default
  50 000 chars (configurable per-call via `:max_description_chars`)
  and appends a `[truncated to <max> chars per spec §14]` marker when
  truncation occurs. This enforces the §14 "operator input MUST be
  bounded in length" requirement at the prompt-rendering layer.
- The scaffolding slices do not open PRs or emit additional event kinds;
  `PairRunner` now consumes them for the first Codex SPEC Author turn.

## Codex App Server Pair-Loop Status

The first Codex runtime slice is complete, but only for the SPEC Author
half-turn when the selected routing profile assigns SPEC authoring to
`codex`.

- `SymphonyElixir.Duet.TurnDrivers.CodexAppServer` implements
  `Duet.TurnDriver` on top of the existing `SymphonyElixir.Codex.AppServer`.
  Required options are `:workspace` and `:issue`; supported pass-through
  options are `:worker_host`, `:tool_executor`, and `:on_message`.
- The driver preserves App Server runtime behavior (JSON-RPC startup,
  workspace validation, dynamic tool handling, remote worker support, and
  orchestrator update forwarding) while collecting
  `codex/event/agent_message*` stream deltas into a single response string.
- `SymphonyElixir.Duet.PairRunner` now resolves the active routing profile,
  and when the SPEC Author is `codex`, it builds a `Duet.PhasePrompt`,
  records `turn_request`, dispatches the selected `TurnDriver`, writes
  the §13.2 transcript, parses the response via `Turn.record_response/6`,
  and then records `task_failed` with `reason = "reviewer_not_implemented"`.
- Profiles whose SPEC Author is not Codex keep the earlier stub behavior:
  initial state events are emitted idempotently, a single `task_failed`
  with `reason = "not_implemented"` is recorded, and the runner returns
  `{:error, :not_implemented}`.
- A previously recorded SPEC/cycle-1 Codex `turn_response` is treated as
  already dispatched on retry; PairRunner does not re-run Codex for that
  same turn and returns `{:error, :reviewer_not_implemented}`.
- The reviewer half-turn, convergence evaluation, cycle continuation,
  phase freeze, PR operations, and Claude runtime are still future slices.

## Convergence Engine Status

The convergence-engine pure helpers are complete. Together they cover
spec §9.3, §10.2, §10.3, §10.4, and §10.5 logic without any
orchestrator wiring or GitHub I/O.

- `SymphonyElixir.Duet.Convergence.from_github_review_state/1` maps the
  GitHub PR review state strings (`"APPROVED"` / `"CHANGES_REQUESTED"`)
  to verdict atoms; everything else returns `:other`.
- `Convergence.evaluate/1` applies spec §10.2: returns `:converged` iff
  both reviewer and author APPROVE on the same non-nil tree-hash;
  otherwise `{:not_converged, reason}` with explicit reasons
  (`:reviewer_not_approved`, `:author_not_approved`,
  `:tree_hash_mismatch`, `:missing_reviewer_signal`,
  `:missing_author_signal`).
- `SymphonyElixir.Duet.CycleCap.at_cap?/2` is the §10.3 counter check;
  `default_max_cycles/0` returns 5.
- `CycleCap.tie_breaker/3` implements §10.4.1 (SPEC/PLAN: forced freeze
  on the Reviewer's last-authored revision, fallback to Author's last)
  and §10.4.2 (CODE: respect `code_phase_cap_policy` —
  `:escalate` / `:forced` / `:fail`).
- `CycleCap.resolve_operator_override/2` resolves the §10.4.2 operator
  decisions (`:approve_author`, `:approve_reviewer`, `:fail`) to either
  a freeze with `mode = operator_override_*` or a fail tuple.
- `SymphonyElixir.Duet.PathologicalDisagreement.detect/1` flags
  three consecutive cycles whose `unresolved` lists are equal after
  normalization (trim, whitespace collapse, lowercase, drop empty,
  uniq, sort) per §10.5.
- `SymphonyElixir.Duet.Identity` resolves per-actor GitHub identities
  (claude / codex) from app-env overrides or `DUET_*_GITHUB_IDENTITY`
  environment variables, and validates the §9.3 distinct-identity
  requirement. The `WORKFLOW.md` `duet.agents.<actor>.github_identity`
  schema wiring is intentionally deferred to a future slice; this
  module stands alone today.
- `SymphonyElixir.Duet.PhaseSummary` provides the v1 fixed-cap
  truncation strategy permitted by §8.4: `word_count/1`,
  `diff_line_count/1`, and `summarize/2` (first N words plus a
  `[summary truncated to first N words per spec §8.4 v1 strategy]`
  marker). It feeds `Duet.PhaseFreezeMessage.summary_word_target/2`.
- No agent runtime, GitHub call, or new event kind is introduced in
  these slices. They are pure helpers consumed by the pair-loop slice.

## Phase Pipeline + v0.4 Opt-In Helpers Status

Five further pure helpers are complete, covering the §8.2/§8.3 phase
pipeline state machine and the v0.4 opt-in features (§8.6 / §7.8 /
§8.7) that the spec marks as additive on top of the canonical pair
loop. None are wired into the orchestrator or any agent runtime yet.

- `SymphonyElixir.Duet.Metrics.for_phase/2` and `for_task/1` derive
  the spec §13.5 convergence metrics from a Duet event log:
  `cycles_to_converge`, `convergence_mode`, `confidence_delta`,
  `mean_cycle_duration_ms`, `verification_pass_rate`, plus per-task
  `total_cycles`, `convergence_velocity`, `escalation_count`,
  `degraded_phases`. `forced_rate/2` is the rolling-window helper.
  Pure event-log fold; no I/O.
- `SymphonyElixir.Duet.PhaseTransition` encodes spec §8.2 ordering
  and §8.3 freeze semantics: `next_phase/1`, `terminal?/1`,
  `freeze_merges_phase_pr?/1`, `freeze_actions/1`,
  `has_phase_branch?/1`, `validate_transition/2`. The
  `freeze_actions/1` list is the spec-defined sequence of side
  effects per phase (e.g. CODE returns
  `[:hold_open_for_review, :record_code_tree_hash, :emit_phase_freeze_message]`)
  for the orchestrator to wire later.
- `SymphonyElixir.Duet.HumanCheckpoint` reads the existing
  `Config.Schema.Duet.human_checkpoints` map field and returns
  `mode_for_phase/2` (`:blocking` / `:advisory` / `:disabled`),
  `blocking?/2`, `timeout_ms/1`, `blocking_phases/1`, plus
  `resolve_decision/2` mapping operator decisions
  (`:approve` / `:request_changes` / `:fail`) to the §8.6 freeze-flow
  actions (REVIEW `:request_changes` correctly returns to CODE
  per spec). `validate_config/1` checks the structure of the map.
- `SymphonyElixir.Duet.ToolProfile` resolves the spec §7.8
  `tool_profiles` config: `enabled?/1`, `default_profile_name/1`,
  `resolve/4` / `resolve/5` (returns `:all` or a sorted tool list, or
  `{:error, ...}` for unknown profile/phase/role/tool), including the
  SPEC/PLAN/CODE `author` + `reviewers.default` / actor override shape,
  `allows?/5`, `validate_config/1`. The §17 implementation-defined
  tool identifier set is exposed via `known_tools/0`. Schema wiring
  for `Config.Schema.Duet.tool_profiles` is intentionally a future
  slice; this module operates on the raw config map.
- `SymphonyElixir.Duet.VerificationGate` provides the spec §8.7
  data layer: `aggregate_status/1` (combines per-check statuses with
  all-timeout → `:timeout`, timeout mixed with completed checks →
  `:partial`, mixed pass/fail → `:partial`),
  `build_block/2` (renders the `---DUET-VERIFICATION---` block per
  the §8.7 example shape with escaped name/summary fields),
  `timeout_block/1` (synthetic timeout block for §8.7 step 2), and
  `start_marker/0` / `end_marker/0` constants. CI execution / GitHub
  status polling is a future orchestrator slice.
- None of these slices touches an agent runtime, opens a PR, or
  emits new event kinds. They form the pure substrate that the
  upcoming orchestrator wiring slices will consume.

## Operator Gates + GitHub Integration Helpers Status

Five further pure helpers are complete. They cover the operator-facing
gate surface (`awaiting_operator` reasons, §8.3.1 PR conflicts), the
spec §9.4 PR title/body format, the §9.3 GitHub PR Reviews API parser,
and the §8.5 SuperPower artifact mode resolver.

- `SymphonyElixir.Duet.AwaitingOperator` enumerates the seven spec-defined
  `awaiting_operator` reasons (`:pause_on_freeze`, `:code_pr_conflict`,
  `:human_checkpoint`, `:verification_timeout`,
  `:superpower_artifact_invalid`, `:phase_cap_escalation`,
  `:state_divergence`) with `valid_decisions/1`, `valid?/2`, and
  `apply_decision/3` translating each (reason, decision) into the
  canonical orchestrator action. `:human_checkpoint` `:request_changes`
  returns to CODE for REVIEW per §8.6; `:phase_cap_escalation`
  emits `{:freeze_with_mode, :operator_override_*}` per §10.4.2.
- `SymphonyElixir.Duet.PR` produces the spec §9.4 PR title
  (`[duet:<task_id>] <phase>: <title>`) and a markdown body that
  includes the operator description (bounded at 50 000 chars per §14
  with the same marker as `Duet.PhasePrompt`), the current cycle, and
  the event log path.
- `SymphonyElixir.Duet.GithubReview` parses already-decoded JSON from
  `gh api .../pulls/<n>/reviews` into `%GithubReview{}` structs
  (`parse_reviews/1`), reduces them to the latest non-dismissed review
  per identity per spec §11.1 (`latest_per_reviewer/1`), and exposes
  the §9.3 binding-state mapping (`binding_state/1`) consistent with
  `Duet.Convergence.from_github_review_state/1`. DISMISSED reviews
  remove the identity from the latest map.
- `SymphonyElixir.Duet.SuperPower` resolves the spec §8.5 SuperPower
  config from a raw map: `enabled?/1`, `mode/1` (defaults to
  `:mirror`), `root/1` (defaults to `docs/superpowers`),
  `phase_enabled?/2`, `artifact_path/3` (returns
  `<root>/<specs|plans|code|reviews>/<sanitized_task_id>.md`),
  `template_check/2` (v1 stub returning `:ok`), and
  `validate_config/1`. `Config.Schema` wiring is intentionally
  deferred.
- `SymphonyElixir.Duet.PRConflict` decides the §8.3.1 mergeability of
  the held-open CODE PR via `evaluate/1`, returning `:mergeable`,
  `{:conflict, %{paths, base_head}}`, or
  `{:retry_later, mergeable_state}` when GitHub has not yet computed
  mergeability. `event_attrs/3` builds the `code_pr_conflict` event
  payload per the spec.
- None of these slices touches an agent runtime, opens a PR, or emits
  new event kinds. They are pure helpers for the upcoming
  orchestrator wiring.

## Local Modifications Inside elixir/

The files listed below carry Duet-specific deltas on top of the upstream
baseline at SHA `58cf97da06d556c019ccea20c67f4f77da124bf3`. They will need
three-way merge attention at each `git subtree pull --prefix=elixir`. Keep
this section in sync with the modifications applied per slice.

### Modified files (carry deltas vs upstream)

| File | Slice | Reason |
|------|-------|--------|
| `mix.exs` | routing config slice | escript `name` and `path` renamed `symphony` → `duet-symphony`; operational runner/routing modules added to coverage ignore list like `AgentRunner`/`Workspace` |
| `lib/symphony_elixir/cli.ex` | first runner slice | usage message updated to new binary name |
| `lib/symphony_elixir/orchestrator.ex` | first runner slice | dispatch routed through `RunnerSelector`; raise wrapper surfaces runner module name in error message |
| `lib/symphony_elixir/config/schema.ex` | routing config slice | added embedded `Duet` schema with core phase/routing fields and routing validation |
| `lib/symphony_elixir/agent_runner.ex` | shared runner runtime slice | workspace lifecycle moved into `RunnerRuntime`; Codex turn behavior remains in `AgentRunner` |
| `lib/symphony_elixir_web/controllers/observability_api_controller.ex` | routing menu slice | adds Duet routing profile GET/POST endpoints |
| `lib/symphony_elixir_web/live/dashboard_live.ex` | routing menu slice | renders the operator Duet routing profile select and phase matrix |
| `lib/symphony_elixir_web/presenter.ex` | routing menu slice | includes Duet routing payload in the observability state payload |
| `lib/symphony_elixir_web/router.ex` | routing menu slice | routes `/api/v1/duet/routing` before issue detail routes |
| `lib/symphony_elixir/log_file.ex` | event log slice | exposes the default Duet event log root for `--logs-root` integration |
| `priv/static/dashboard.css` | routing menu slice | styles the Duet routing select, metadata row, and phase table |
| `test/support/test_support.exs` | identity slice | added `duet_yaml` helper for emitting simple and raw `duet:` blocks in test config fixtures; clears runtime routing profile selection and Duet GitHub identity overrides between tests |
| `test/symphony_elixir/extensions_test.exs` | routing menu slice | covers routing API payload, profile selection, and dashboard form behavior |
| `test/symphony_elixir/log_file_test.exs` | event log slice | covers the default Duet event log root |
| `test/symphony_elixir/core_test.exs` | timing stabilization slice | added assertions covering `duet.enabled` defaulting and parsing; widened two retry timing assertion windows near lines 562 and 604 after the same upstream timing flake failed on pinned GitHub Actions run `25628886607` |
| `README.md` | first runner slice | repath SPEC link, removed unavailable screenshot, binary rename, license clause clarified, Apache-2.0 §4(b) modification notice added |

### New Duet-only files (no upstream conflict expected)

- `lib/symphony_elixir/runner_runtime.ex`
- `lib/symphony_elixir/runner_selector.ex`
- `lib/symphony_elixir/duet/event_log.ex`
- `lib/symphony_elixir/duet/routing.ex`
- `lib/symphony_elixir/duet/routing_selection.ex`
- `lib/symphony_elixir/duet/task_state.ex`
- `lib/symphony_elixir/duet/trailer.ex`
- `lib/symphony_elixir/duet/turn.ex`
- `lib/symphony_elixir/duet/turn_driver.ex`
- `lib/symphony_elixir/duet/turn_drivers/mock.ex`
- `lib/symphony_elixir/duet/turn_drivers/codex_app_server.ex`
- `lib/symphony_elixir/duet/branches.ex`
- `lib/symphony_elixir/duet/phase_prompt.ex`
- `lib/symphony_elixir/duet/phase_freeze_message.ex`
- `lib/symphony_elixir/duet/transcripts.ex`
- `lib/symphony_elixir/duet/convergence.ex`
- `lib/symphony_elixir/duet/cycle_cap.ex`
- `lib/symphony_elixir/duet/pathological_disagreement.ex`
- `lib/symphony_elixir/duet/identity.ex`
- `lib/symphony_elixir/duet/phase_summary.ex`
- `lib/symphony_elixir/duet/metrics.ex`
- `lib/symphony_elixir/duet/phase_transition.ex`
- `lib/symphony_elixir/duet/human_checkpoint.ex`
- `lib/symphony_elixir/duet/tool_profile.ex`
- `lib/symphony_elixir/duet/verification_gate.ex`
- `lib/symphony_elixir/duet/awaiting_operator.ex`
- `lib/symphony_elixir/duet/pr.ex`
- `lib/symphony_elixir/duet/pr_conflict.ex`
- `lib/symphony_elixir/duet/github_review.ex`
- `lib/symphony_elixir/duet/super_power.ex`
- `lib/symphony_elixir/duet/pair_runner.ex`
- `test/symphony_elixir/duet_event_log_test.exs`
- `test/symphony_elixir/duet_routing_selection_test.exs`
- `test/symphony_elixir/duet_task_state_test.exs`
- `test/symphony_elixir/duet_trailer_test.exs`
- `test/symphony_elixir/duet_turn_test.exs`
- `test/symphony_elixir/duet_turn_driver_mock_test.exs`
- `test/symphony_elixir/duet_turn_driver_codex_app_server_test.exs`
- `test/symphony_elixir/duet_branches_test.exs`
- `test/symphony_elixir/duet_phase_prompt_test.exs`
- `test/symphony_elixir/duet_phase_freeze_message_test.exs`
- `test/symphony_elixir/duet_transcripts_test.exs`
- `test/symphony_elixir/duet_convergence_test.exs`
- `test/symphony_elixir/duet_cycle_cap_test.exs`
- `test/symphony_elixir/duet_pathological_disagreement_test.exs`
- `test/symphony_elixir/duet_identity_test.exs`
- `test/symphony_elixir/duet_phase_summary_test.exs`
- `test/symphony_elixir/duet_metrics_test.exs`
- `test/symphony_elixir/duet_phase_transition_test.exs`
- `test/symphony_elixir/duet_human_checkpoint_test.exs`
- `test/symphony_elixir/duet_tool_profile_test.exs`
- `test/symphony_elixir/duet_verification_gate_test.exs`
- `test/symphony_elixir/duet_awaiting_operator_test.exs`
- `test/symphony_elixir/duet_pr_test.exs`
- `test/symphony_elixir/duet_pr_conflict_test.exs`
- `test/symphony_elixir/duet_github_review_test.exs`
- `test/symphony_elixir/duet_super_power_test.exs`
- `test/symphony_elixir/runner_selector_test.exs`
- `test/symphony_elixir/duet_routing_test.exs`

## Baseline Test Status

### 2026-05-10 local run

Environment:

- Runtime manager: `mise 2026.5.4` installed via Homebrew for this validation.
- Erlang/OTP: `28` (`erts-16.4`)
- Elixir: `1.19.5-otp-28`

Commands run from `elixir/`:

```bash
mise trust
mise install
mise exec -- mix deps.get
mise exec -- mix test
mise exec -- mix test test/symphony_elixir/core_test.exs:557
```

Result:

- Full suite: `230 tests, 1 failure, 2 skipped`
- Targeted rerun: `1 test, 1 failure`
- Failing test:
  `test/symphony_elixir/core_test.exs:557`
  `"abnormal worker exit increments retry attempt progressively"`
- Failure signal:
  `assert remaining_ms >= min_remaining_ms`, with observed remaining time
  below the lower bound by roughly 200 ms.

Follow-up:

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  mise exec -- mix test test/symphony_elixir/core_test.exs:557 --no-color
done
```

Follow-up result: `9 pass, 1 fail`. The single follow-up failure was the same
timing assertion, with observed remaining time 24 ms below the lower bound.

Classification: environment-specific timing flaky in an upstream
retry-scheduling test. The failure is not treated as a functional regression in
the imported baseline as long as it remains isolated to this test and the CI
baseline passes on the pinned Erlang/Elixir versions.

Initial CI validation:

- Workflow: `Elixir Baseline`
- Run ID: `25627600029`
- Commit: `2027f152a7dc4af099d9cc9c8ea151fba3c8c881`
- Result: pass

Later CI reclassification:

- Workflow: `Elixir Baseline`
- Run ID: `25628886607`
- Commit: `c1d1689c3ad0bbf78bf8be3f4678a531770fc80e`
- Result: fail on the same abnormal worker retry timing assertion, with
  `remaining_ms = 39020` against lower bound `39500`.

Classification update: upstream timing-flaky requiring a local test tolerance
delta. The test windows in `test/symphony_elixir/core_test.exs` were widened
without changing production retry logic. The short retry assertion remains
bounded at `450..1200` ms to preserve sensitivity to retry-order regressions.
This is a test-only Duet local delta and should be reviewed on each upstream
sync. If future runs fail outside these same retry timing assertions, stop and
re-classify before continuing.

## Post-Import Root NOTICE Text

Apply this root `NOTICE` wording in the same commit that imports upstream code:

```text
Duet-Symphony
Copyright 2024 bacoco

The Elixir implementation under elixir/ is derived from OpenAI Symphony
(https://github.com/openai/symphony) at upstream ref <SHA>, licensed under
Apache-2.0. See elixir/LICENSE and elixir/NOTICE.

The Duet-Symphony specification under spec/ and the design overlay are
licensed under MIT. See LICENSE.
```

Replace `<SHA>` with the imported upstream SHA from the sync history.

## First Review Checkpoint

Before importing code, ask a reviewer to validate this strategy against
`spec/SPEC.md` and upstream Symphony's current Elixir layout. In particular,
review whether `AgentRunner` is the right first boundary, whether the subtree
split sync mechanism is suitable for future upstream upgrades, and whether the
first slice exit criteria are small enough to keep the import reviewable.
