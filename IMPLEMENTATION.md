# Duet-Symphony Implementation Plan

This document records the implementation strategy before importing upstream
Symphony code. The normative behavior remains in `spec/SPEC.md`.

## Checkpoint 1: Upstream Symphony Baseline

- Upstream remote: `https://github.com/openai/symphony.git`
- Inspected ref: `upstream/main`
- Upstream HEAD inspected: `58cf97da06d556c019ccea20c67f4f77da124bf3`
- Upstream implementation language: Elixir/OTP
- Main implementation subtree upstream: `elixir/`
- Upstream license: Apache-2.0

The local repo is intentionally still design-only at this checkpoint. No
upstream source code has been imported yet.

## Recommended Import Strategy

Import the upstream Elixir implementation into this repo under `elixir/`, not
as a full root-level merge. Keep `spec/` standalone and untouched.

The import should include:

- `upstream/main:elixir/` -> local `elixir/`
- upstream `LICENSE` preserved under `elixir/LICENSE`
- upstream `NOTICE` preserved under `elixir/NOTICE`
- upstream `.codex/skills/*` copied only if needed by the runnable workflow

Do not merge upstream root files over this repo's root `README.md`, `SPEC.md`,
`LICENSE`, or `NOTICE`. This repo's root remains the Duet project surface;
OpenAI Symphony provenance is preserved inside the imported implementation and
in the root `NOTICE`.

## Rationale

Symphony's current implementation already has the right layering for Duet:

- `SymphonyElixir.Orchestrator` owns polling, dispatch, retries, worker
  lifecycle, status tracking, and dashboard updates.
- `SymphonyElixir.Workspace` owns isolated workspace creation, hooks, remote
  worker support, and cleanup.
- `SymphonyElixir.Config.Schema` owns typed `WORKFLOW.md` config parsing and
  validation.
- `SymphonyElixir.Codex.AppServer` is a narrow Codex App Server adapter.
- `SymphonyElixir.AgentRunner` is the smallest useful seam: it creates a
  workspace, starts Codex, builds prompts, runs turns, and streams updates back
  to the orchestrator.

The first Duet implementation should therefore replace or wrap
`AgentRunner.run/3` with a `duet_pair` runner while leaving the orchestrator,
tracker, workspace, hooks, remote worker, dashboard, and retry mechanics close
to upstream.

## First Implementation Slice After Import

1. Import upstream `elixir/` and preserve Apache-2.0 license/notice files.
2. Rename the escript binary from `symphony` to `duet-symphony` only after the
   upstream baseline tests run.
3. Add `duet:` config parsing to `Config.Schema` without removing existing
   Symphony config.
4. Add a runner selector:
   - default compatibility mode: existing single Codex `AgentRunner`
   - Duet mode: new `Duet.PairRunner`
5. Add unit tests for config parsing and runner selection before adding Claude.
6. Add phase/event persistence under `.duet/` before implementing full PR
   convergence.

This keeps the first executable milestone small: upstream Symphony still runs,
and Duet-specific behavior is introduced behind config.

## First Review Checkpoint

Before importing code, ask a reviewer to validate this strategy against
`spec/SPEC.md` and upstream Symphony's current Elixir layout. In particular,
review whether `AgentRunner` is the right first boundary and whether importing
only `elixir/` creates any licensing, update, or operability problem.
