# Duet-Symphony

A Symphony-compatible Claude/Codex orchestration harness with operator-selected
agent routing.

Status: **design only**. The full design lives in [`spec/SPEC.md`](./spec/SPEC.md).
No implementation yet.

## In one paragraph

Duet-Symphony aims to keep the same product shape as
[OpenAI Symphony](https://github.com/openai/symphony): tracker-driven dispatch,
isolated workspaces, lifecycle hooks, retry/reconciliation, logs, optional
dashboard/API, and autonomous handoff. The difference is the worker: instead of
one Codex agent per task, each claimed task runs a strict Claude + Codex duet
through `SPEC -> PLAN -> CODE -> REVIEW` until both agents converge on the same
artifact/revision. Operators can also choose Claude-only, Codex-only, or
custom per-phase routing profiles for degraded/local runs, and can add human
checkpoints at the end of SPEC, PLAN, CODE, or REVIEW.

## Why a separate project

This is intentionally not a Council mode. Council coordinates **N models in
parallel** with synthesis; Duet's full mode coordinates Claude and Codex in
strict alternation with PR-based artifact exchange. Explicit degraded profiles
exist for operator-directed one-model runs, but they do not claim full Duet
convergence unless a second binding review is supplied.

## Relation to Symphony

This project should preserve as much Symphony behavior as possible so upstream
fixes and improvements can be merged. The preferred implementation strategy is
a small fork/overlay: keep Symphony's orchestrator, tracker, workspace, hooks,
retry, remote worker, and observability layers, then replace the single Codex
worker internals with a Duet pair-runtime boundary.

Huge thanks to the OpenAI Symphony team for publishing the spec and reference
implementation that this project builds on. Derived code must preserve the
Apache-2.0 license and NOTICE attribution.

## Repository structure

```
Duet-Symphony/
├── spec/                  # Language-agnostic specification (standalone)
│   ├── README.md          #   Reading guide for implementers
│   └── SPEC.md            #   Normative spec v0.4.1
├── AGENTS.md              # Project handoff notes and implementation guidance
├── REVIEW.md              # Design review and risk backlog
├── README.md              # This file
├── LICENSE                # MIT
├── NOTICE                 # Attribution (OpenAI Symphony, Apache-2.0)
└── .gitignore
```

**For implementers:** everything you need to build a conformant port in any
language is in [`spec/`](./spec/). See [`spec/README.md`](./spec/README.md)
for the reading order.

**For contributors:** the implementation (a Symphony fork with Duet
pair-runtime overlay) will live alongside `spec/` once development begins.
`AGENTS.md` has the current implementation roadmap.

The spec now also defines an initial operator routing menu, per-phase
human-in-the-loop checkpoints, optional verification gates, draft PR lifecycle,
convergence metrics, tool profiles, and optional SuperPower-style artifacts
under `docs/superpowers/` for teams that want that SPEC/PLAN/REVIEW workflow.

## Quick links

- [Specification](./spec/SPEC.md) — the normative design document
- [Spec reading guide](./spec/README.md) — for implementers starting from scratch
- [Implementation guidance](./AGENTS.md) — next steps and constraints
- [Design review](./REVIEW.md) — risk backlog from spec review
- [OpenAI Symphony](https://github.com/openai/symphony) — upstream project
- [NOTICE](./NOTICE) — attribution (Apache-2.0)
- [LICENSE](./LICENSE) — MIT
