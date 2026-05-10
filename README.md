# Duet-Symphony

A two-agent (Claude + Codex) adversarial collaboration harness.

Status: **design only**. The full design lives in [`SPEC.md`](./SPEC.md). No
implementation yet.

## In one paragraph

Duet-Symphony drives two LLM agents through a structured pipeline of phases —
specification, plan, code, review — with **GitHub Pull Requests as the
artifact and convergence substrate**, and **git worktrees as the
parallel-task isolation mechanism**. Each phase ends with both agents
explicitly approving a frozen artifact; SPEC and PLAN freeze by merging their
phase PRs, while CODE stays open until REVIEW completes. Multiple tasks run in
parallel, each in its own worktree, with an isolated pair of long-running CLI
sessions per task so that each agent retains its own conversation history
across phases.

## Why a separate project

This is intentionally not a Council mode. Council coordinates **N models in
parallel** with synthesis; Duet coordinates **exactly two agents in strict
alternation** with PR-based artifact exchange. The abstractions are
different enough that mixing them would compromise both.

## Inspiration: Symphony

The harness layer (per-task worktrees, lifecycle hooks, path containment,
isolation invariants, optional dashboard) is borrowed and adapted from
[**OpenAI Symphony**](https://github.com/openai/symphony). What Duet
**replaces** is Symphony's single-Codex-per-workspace agent model, swapping
in a two-agent (Claude + Codex) pair-loop with PRs as the convergence
substrate. See `SPEC.md` §1.1 for the full mapping of what was kept,
adapted, and dropped.

## Standalone repository

This is the standalone **Duet-Symphony** repository, seeded from the original
design snapshot in the Bacos skills monorepo.

## Reading order

1. [`SPEC.md`](./SPEC.md) §1–4 — purpose, non-goals, glossary, architecture
2. §5–7 — task lifecycle, worktrees, persistent sessions
3. §8–10 — phase pipeline, PR substrate, convergence protocol
4. §11–14 — failure modes, configuration, logging, security
5. §15–20 — CLI surface, conformance, implementation-defined items, open
   questions

## Repository status

```
Duet-Symphony/
├── AGENTS.md
├── README.md
├── SPEC.md
├── LICENSE
└── .gitignore
```

No code. No implementation. No language commitment. The spec is the
deliverable for this iteration.
