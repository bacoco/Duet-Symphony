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
> claimed issue will burn the retry budget without producing useful work.

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

## Local Modifications Inside elixir/

The files listed below carry Duet-specific deltas on top of the upstream
baseline at SHA `58cf97da06d556c019ccea20c67f4f77da124bf3`. They will need
three-way merge attention at each `git subtree pull --prefix=elixir`. Keep
this section in sync with the modifications applied per slice.

### Modified files (carry deltas vs upstream)

| File | Slice | Reason |
|------|-------|--------|
| `mix.exs` | first runner slice | escript `name` and `path` renamed `symphony` → `duet-symphony`; shared runtime added to coverage ignore list like `AgentRunner`/`Workspace` |
| `lib/symphony_elixir/cli.ex` | first runner slice | usage message updated to new binary name |
| `lib/symphony_elixir/orchestrator.ex` | first runner slice | dispatch routed through `RunnerSelector`; raise wrapper surfaces runner module name in error message |
| `lib/symphony_elixir/config/schema.ex` | first runner slice | added embedded `Duet` schema with `enabled` boolean field |
| `lib/symphony_elixir/agent_runner.ex` | shared runner runtime slice | workspace lifecycle moved into `RunnerRuntime`; Codex turn behavior remains in `AgentRunner` |
| `test/support/test_support.exs` | first runner slice | added `duet_yaml` helper for emitting `duet:` blocks in test config fixtures |
| `test/symphony_elixir/core_test.exs` | first runner slice | added assertions covering `duet.enabled` defaulting and parsing |
| `README.md` | first runner slice | repath SPEC link, removed unavailable screenshot, binary rename, license clause clarified, Apache-2.0 §4(b) modification notice added |

### New Duet-only files (no upstream conflict expected)

- `lib/symphony_elixir/runner_runtime.ex`
- `lib/symphony_elixir/runner_selector.ex`
- `lib/symphony_elixir/duet/pair_runner.ex`
- `test/symphony_elixir/runner_selector_test.exs`

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

CI validation:

- Workflow: `Elixir Baseline`
- Run ID: `25627600029`
- Commit: `2027f152a7dc4af099d9cc9c8ea151fba3c8c881`
- Result: pass

No `elixir/` source or fixture was modified after the subtree import. Do not
start the rename/config/runner-selector slice if future baseline CI runs fail,
or if the local failure expands beyond this isolated timing assertion.

If CI fails, re-classify this baseline failure as one of:

- an environment-specific timing flaky that may be annotated or tolerated;
- a CI-only pass that should be validated in GitHub Actions before proceeding;
- an upstream test issue to patch locally with a clearly attributed delta; or
- a true baseline blocker.

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
