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
- No external Claude/Codex calls are introduced in this slice.

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
| `test/support/test_support.exs` | routing menu slice | added `duet_yaml` helper for emitting simple and raw `duet:` blocks in test config fixtures; clears runtime routing profile selection between tests |
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
- `lib/symphony_elixir/duet/pair_runner.ex`
- `test/symphony_elixir/duet_event_log_test.exs`
- `test/symphony_elixir/duet_routing_selection_test.exs`
- `test/symphony_elixir/duet_task_state_test.exs`
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
