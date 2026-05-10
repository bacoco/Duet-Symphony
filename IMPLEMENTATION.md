# Duet-Symphony Implementation Plan

This document records the implementation strategy before importing upstream
Symphony code. The normative behavior remains in `spec/SPEC.md`.

## Checkpoint 1: Upstream Symphony Baseline

- Upstream remote: `https://github.com/openai/symphony.git`
- Upstream implementation language: Elixir/OTP
- Upstream runtime pin: see `elixir/mise.toml`
  - Erlang: `28`
  - Elixir: `1.19.5-otp-28`
- Main implementation subtree upstream: `elixir/`
- Upstream license: Apache-2.0

The local repo is intentionally still design-only at this checkpoint. No
upstream source code has been imported yet.

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

Do not merge upstream root files over this repo's root `README.md`, `SPEC.md`,
`LICENSE`, or `NOTICE`. This repo's root remains the Duet project surface;
OpenAI Symphony provenance is preserved inside the imported implementation and
in the root `NOTICE`.

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

No `elixir/` source or fixture was modified after the subtree import. Do not
start the rename/config/runner-selector slice until GitHub Actions validates
the baseline, or until a reviewer explicitly accepts a different documented
gate.

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
