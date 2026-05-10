# Duet-Symphony Specification

**Version:** 0.3.0 (draft)
**Status:** Design — not yet implemented
**Audience:** implementers building a Symphony-compatible Duet fork

---

## 1. Purpose

Duet-Symphony is an **upstream-friendly two-agent fork of OpenAI Symphony**. It
keeps Symphony's product shape and operational contract — tracker-driven
dispatch, isolated workspaces, hooks, retries, observability, optional remote
workers, and autonomous handoff — while replacing the single Codex worker with a
strict **Claude + Codex duet**.

The target is not a smaller local CLI inspired by Symphony. The target is:

> Symphony's features and operator experience, with two cooperating models
> running inside each claimed task.

The goal is not "more deliberation," but **structured disagreement that
produces verifiable artifacts**. The pair loop still uses the Duet phases
`SPEC -> PLAN -> CODE -> REVIEW`, but those phases run inside Symphony's
issue-oriented service lifecycle instead of replacing it. Multiple tasks run in
parallel just as in Symphony; each task gets an isolated workspace and one
Duet worker. The default, fully conformant Duet profile supervises two agent
runtimes, while operator-selected degraded profiles may run one model or a
human-assisted subset for local development.

This document is **implementation-oriented**. A port may be written in any
language, but the recommended path is to fork or vendor OpenAI Symphony and keep
the Duet-specific patch set as small as practical.

### 1.1 Acknowledgement

Duet-Symphony is only possible because the OpenAI Symphony team published a
clear orchestration spec and a reference implementation. This project should
keep that provenance visible in code, docs, release notes, and NOTICE files.
When code is copied or derived from OpenAI Symphony, preserve the Apache-2.0
license, copyright notices, and NOTICE attribution.

### 1.2 Relation to Symphony

The harness model in this spec is **directly derived from OpenAI's Symphony**
(<https://github.com/openai/symphony>, see its `SPEC.md`). Duet should preserve
Symphony behavior by default and add the pair-loop at the narrowest feasible
boundary.

| Symphony concept                                       | Duet-Symphony equivalent |
|--------------------------------------------------------|---------------------|
| Tracker polling and reconciliation                     | Preserved; Linear remains the first-class tracker |
| Per-issue isolated workspace                           | Preserved; Duet phase branches live inside the workspace |
| Single-authority orchestrator with in-memory state     | Preserved unless upstream changes it |
| Lifecycle hooks (`after_create`, `before_run`, etc.)   | Preserved with the same fatal-vs-logged semantics |
| Workspace path containment + key sanitization          | Preserved |
| `WORKFLOW.md` front matter + prompt body               | Preserved and extended with optional `duet:` settings |
| Codex App Server integration                           | Preserved for the Codex half of the duet |
| Optional SSH workers / remote execution                | Preserved; Duet workers may run locally or remotely |
| Optional HTTP API + dashboard                          | Preserved and extended to show pair-loop state |
| Single Codex worker                                    | Replaced by a Duet worker that coordinates Claude + Codex |

The highest-priority implementation constraint is **upstream mergeability**:
avoid broad rewrites of Symphony's orchestrator, tracker, workspace, config,
and observability layers. The preferred change is to introduce an agent-runtime
boundary under the existing worker contract, then make the default runtime
either `codex_single` (Symphony-compatible) or `duet_pair`.

Pure plugin compatibility is not assumed. Symphony's current reference
implementation hardcodes meaningful Codex behavior in the worker path, so Duet
should expect a maintained fork or vendored subtree with a small patch stack.

### 1.3 Upstream Compatibility Strategy

Duet should be structured so upstream Symphony updates can be pulled regularly.
The recommended repository strategy is:

1. Keep an `upstream/openai-symphony` branch or vendored subtree that mirrors
   OpenAI Symphony without Duet edits.
2. Keep Duet changes in small, reviewable commits on top of that baseline.
3. Prefer adding explicit extension boundaries over editing unrelated
   scheduler, workspace, tracker, dashboard, or config code.
4. Maintain a short "upstream merge checklist" that runs Symphony's original
   tests plus Duet pair-loop tests after every upstream sync.

The recommended code boundary is:

- Keep the Symphony orchestrator dispatch contract: one worker per claimed
  issue.
- Replace the worker internals with an `AgentRuntime`/`PairRuntime` boundary.
- Preserve the existing single-Codex runtime as a compatibility mode.
- Add `duet_pair` as another runtime that coordinates Claude + Codex and emits
  Symphony-compatible worker updates.

This is feasible as a fork/overlay. It is not currently feasible as a zero-patch
plugin unless upstream exposes a stable worker runtime extension point.

---

## 2. Non-Goals (v1)

The following are **explicitly out of scope** for v1 and MUST NOT be added
without a spec amendment:

- Dropping Symphony's tracker-driven service model. Linear ingestion,
  reconciliation, and status-driven automation are part of the target product.
- A ground-up rewrite that loses the ability to merge upstream Symphony
  improvements without repeated manual reconstruction.
- A pure plugin architecture that assumes OpenAI Symphony already exposes every
  Duet extension point. If upstream does not expose the needed seam, Duet may
  maintain a small fork patch.
- Container or VM sandboxing beyond what Symphony, Codex App Server, remote
  workers, and the host OS already provide.
- Multi-repository tasks. A task targets exactly one repository.
- More than two agents per task. The harness is a *duet*, not an *ensemble*.
- Removing Symphony observability, logs, hooks, retry/backoff, or remote worker
  behavior in the name of a smaller MVP.
- Cost tracking and budget enforcement beyond upstream Symphony's runtime
  metrics. Operators are assumed to choose their own account-level controls.
- IDE integration or editor extensions.
- Automatic deployment or release beyond the workflow's configured handoff and
  merge policy.

---

## 3. Glossary

| Term | Meaning |
|------|---------|
| **Task** | A single unit of work, identified by `task_id`. Has a title and a free-form description. |
| **Phase** | One of: `SPEC`, `PLAN`, `CODE`, `REVIEW`. Phases run sequentially per task. |
| **Artifact** | The frozen output of a phase. `SPEC` → `SPEC.md`; `PLAN` → `PLAN.md`; `CODE` → source-file changes; `REVIEW` → an approval record. |
| **Author** | The agent whose turn it is to draft or revise the artifact. |
| **Reviewer** | The agent whose turn it is to critique the artifact. |
| **Agent routing profile** | Operator-selected policy assigning Author, Reviewer, and coder-acknowledgement roles per phase to Claude, Codex, a human, or no actor in degraded mode. |
| **Cycle** | One Author → Reviewer round-trip within a phase. |
| **Convergence** | Both agents emit `APPROVE` for the same revision of the artifact in the same cycle. |
| **Phase Freeze** | The point at which a phase's artifact is locked and the next phase can begin. SPEC/PLAN freeze by merging their phase PRs; CODE freezes without merge so REVIEW can run on the held-open CODE PR. |
| **SuperPower artifacts** | Optional human-facing SPEC, PLAN, and REVIEW documents following the SuperPower artifact conventions, normally under `docs/superpowers/{specs,plans,reviews}`. |
| **Workspace** | A Symphony-style isolated filesystem directory assigned to one issue/task. It may contain a clone, git worktree, or other repository copy. |
| **Agent runtime** | A Claude or Codex execution backend, such as Codex App Server, Codex Cloud, Claude Code print/resume, or a GitHub bot. |
| **Duet worker** | The per-task worker that runs the phase loop and supervises the effective agent runtime set selected by the active routing profile. |
| **Orchestrator** | The single process that polls the tracker, manages workspace allocation, supervises workers, retries, and reconciliation. |

---

## 4. System Architecture

```
                  ┌──────────────────────────┐
   Linear/API ──▶ │ Symphony-style           │
                  │ Orchestrator             │
                  └────────────┬─────────────┘
                               │ dispatch (bounded concurrency)
             ┌─────────────────┼─────────────────┐
             ▼                 ▼                 ▼
         Issue α           Issue β           Issue γ
      ┌───────────┐     ┌───────────┐     ┌───────────┐
      │ Workspace │     │ Workspace │     │ Workspace │
      │ + hooks   │     │ + hooks   │     │ + hooks   │
      └─────┬─────┘     └─────┬─────┘     └─────┬─────┘
            ▼                 ▼                 ▼
      ┌───────────┐     ┌───────────┐     ┌───────────┐
      │ Duet      │     │ Duet      │     │ Duet      │
      │ Worker    │     │ Worker    │     │ Worker    │
      └─────┬─────┘     └─────┬─────┘     └─────┬─────┘
            │
      ┌─────┴────────────┐
      ▼                  ▼
  Claude runtime     Codex runtime
  (Claude Code,      (Codex App Server,
   bot, or cloud)     Codex Cloud, or bot)
            │
            ▼
  PRs, tracker state, workpad, logs, dashboard
```

### 4.1 Process model

- **One** orchestrator process per host. It is the single source of truth for
  issue dispatch, retry scheduling, reconciliation, and worker lifecycle.
- **N** concurrent issues (configurable; inherit Symphony's concurrency and
  per-state concurrency controls where available).
- Per issue: **one** isolated workspace + **one** Duet worker + the runtime set
  resolved from the active agent routing profile. A full Duet profile supervises
  Claude and Codex. A single-agent profile is allowed only as an explicitly
  degraded/operator-assisted mode (§7.7).
- Restart behavior should follow Symphony's tracker/filesystem recovery first,
  then use Duet event logs, branch tips, PR state, and phase summaries to
  resume pair-loop state.

---

## 5. Task Lifecycle

### 5.1 States

Duet has pair-loop phase state, but it does not replace the tracker state
machine. Symphony-compatible tracker states such as `Todo`, `In Progress`,
`Human Review`, `Rework`, `Merging`, and `Done` remain the operator-facing
control plane. The internal Duet state overlays a claimed issue while the
worker is active:

```
queued
  └─▶ running
       ├─▶ spec_phase  ──┐
       ├─▶ plan_phase  ──┼─▶ completed
       ├─▶ code_phase  ──┤
       └─▶ review_phase─┘
       └─▶ awaiting_operator  (CODE phase cap reached; see §10.4.2)
              └─▶ resumed by operator → completed | failed
       └─▶ failed (any phase, terminal)
       └─▶ abandoned (operator action, terminal)
```

Transitions are atomic and recorded in a structured log
(`<log_dir>/tasks/<task_id>/events.jsonl`).

### 5.2 Task identity

A task has:
- `task_id` (string, MUST match `[a-z0-9][a-z0-9-]{2,63}` — used in branch
  names and filesystem paths)
- `title` (string, ≤ 200 chars)
- `description` (string, ≤ 50 000 chars; this is the operator's brief)
- `created_at` (ISO 8601)

For tracker-ingested work, `task_id` is a Duet-safe identifier derived from the
tracker issue identifier or internal ID. It MUST be recorded in the event log so
the Symphony issue record, workspace key, and Duet branch names can be
reconciled after restart.

### 5.3 Task ingestion (v1)

Primary ingestion is Symphony-compatible tracker polling. Linear is the first
supported tracker and MUST remain compatible with Symphony's active/terminal
state model, blocker handling, retry/reconciliation, and workpad-driven
workflow.

Manual CLI submission is permitted as an implementation extension for local
testing and one-off runs:

```
duet run --id auth-refactor --title "Refactor auth to JWT" \
         --description-file ./brief.md
```

The CLI extension MUST feed the same normalized issue/task model used by the
tracker path. It must not become the only supported ingestion mechanism.

---

## 6. Workspace And Branch Harness

### 6.1 Invariants

1. Duet MUST preserve Symphony's workspace manager contract: each claimed
   issue/task gets a deterministic isolated workspace under the configured
   workspace root.
2. Workspace paths MUST stay inside the configured root after path expansion and
   canonicalization.
3. Workspace population remains implementation-defined, as in Symphony. A
   repository may use `hooks.after_create` to clone, `git worktree add`, or any
   other safe bootstrap process.
4. When Duet uses GitHub PRs for phase artifacts, the repository inside the
   workspace MUST have a configured GitHub remote before the pair loop starts.
5. Duet branch names MUST keep the valid two-namespace topology:
   `duet-base/<task_id>` for long-lived task branches and
   `duet-phase/<task_id>/<phase>` for phase branches.
6. The orchestrator MUST NOT run agent work in the operator's main checkout
   unless that checkout is itself the isolated Symphony workspace for the
   claimed issue.

### 6.2 Lifecycle

| Hook | When | On failure |
|------|------|------------|
| `before_create` | Before workspace creation or population | Fatal — task transitions to `failed` |
| `after_create` | Immediately after the workspace exists | Fatal |
| `before_run` | Before the Duet worker starts agent runtimes | Fatal |
| `after_run` | After all phases complete (success or fail) | Logged, ignored |
| `before_remove` | Before workspace removal | Logged, ignored |

Hook scripts run with `cwd = <workspace>`, inherit a sanitized environment
plus `DUET_TASK_ID`, `DUET_PHASE`, and `DUET_BRANCH`. Default timeout per
hook: 60 s.

### 6.3 Workspace creation

Duet should reuse Symphony's workspace creation and cleanup behavior wherever
possible. A Git-backed workflow may choose one of two population modes:

1. **Clone mode** (closest to Symphony): create an empty workspace, then clone
   the target repository in `after_create`.
2. **Worktree mode**: create the workspace by running `git worktree add` from a
   configured repository root.

After the repository exists in the workspace, Duet creates or checks out
`duet-base/<task_id>` from the configured base branch and uses
`duet-phase/<task_id>/<phase>` branches for phase PRs.

### 6.4 Worktree teardown

On task completion (success or failed):
1. Orchestrator emits `before_remove` hook.
2. Workspace cleanup follows the configured Symphony cleanup policy. Worktree
   mode uses `git worktree remove <path>` (with `--force` only if explicitly
   configured); clone mode removes the workspace directory.
3. Branch `duet-base/<task_id>` is **not** deleted automatically; it is preserved
   for audit until the operator runs `duet prune`.

### 6.5 Concurrency

- Duet inherits Symphony's global and per-state concurrency controls.
- Claimed issues beyond available capacity remain unclaimed or retry-queued
  according to Symphony's scheduler rules.
- Workspaces are not shared across tasks under any circumstance.

---

## 7. Agent Runtime Management

### 7.1 Per-task agent runtimes

Each Duet worker owns the agent runtimes required by the active routing
profile. A full Duet profile owns exactly two machine runtimes:

- `agent_a`: Claude (Claude Code local CLI, GitHub bot, remote worker, or
  another conformant Claude-capable runtime)
- `agent_b`: Codex (Codex App Server, Codex Cloud, Codex CLI, GitHub bot, or
  another conformant Codex-capable runtime)

Both are bound to the same isolated workspace and persist logically across all
phases of that task. A degraded profile may instantiate only one of them, or
may replace a binding role with `human`, but the missing role MUST be visible
in task state and logs (§7.7). The physical process model is runtime-specific:
Codex App Server may keep a long-lived JSON-RPC server and thread, Codex Cloud
is asynchronous, and Claude Code may use print/resume or streaming mode.

### 7.2 Strict per-task isolation

An agent runtime MUST NOT be shared across tasks. Cross-task history bleed is a
correctness bug, not a performance issue. The Duet worker MUST guarantee that
runtime IDs, on-disk logs, cloud task IDs, thread IDs, and process IDs are
unique per issue/task.

### 7.3 Session protocol

The Duet worker interacts with each runtime through a turn-based protocol:

```
DUET ──prompt──▶ AGENT RUNTIME
DUET ◀─response─ AGENT RUNTIME   (containing a structured trailer; see §10)
```

Implementations SHOULD prefer structured/headless protocols over interactive
TTY automation:

- Codex: Codex App Server is preferred for local/remote runs because it exposes
  the Codex harness over JSON-RPC/JSONL. Codex Cloud is permitted as an
  asynchronous CODE-phase runtime when configured.
- Claude: use Claude Code `--print --output-format stream-json` (with
  `--resume` and `--session-id` for persistence) where available, or a GitHub
  bot/runtime that can return parseable trailers.
- Interactive stdin/stdout CLI driving is a fallback, not the preferred
  production integration.

Stored conversation state is the agent runtime's responsibility. The Duet
worker stores only the metadata needed to resume, audit, and reconcile.

### 7.4 Session lifecycle

| Event | Action |
|-------|--------|
| Task moves to `running` | Resolve the agent routing profile, then start or attach the required agent runtimes; record runtime IDs. |
| Phase transition | Send a *phase-freeze* message (§8.4) to each active runtime for the next phase. |
| Runtime crash | Detect via exit code, cloud failure, or heartbeat timeout; resume from runtime ID with a *recovery* message replaying frozen artifacts. |
| Task terminal | Send a *shutdown* message where supported; terminate local processes with grace. |

### 7.5 Context window pressure

By the end of a long task (SPEC + PLAN + CODE + REVIEW with multiple cycles),
session histories can be large. Mitigations:

- The orchestrator MUST send an explicit *phase-freeze* message at every
  phase boundary (see §8.4) summarizing the frozen artifact. Agents are
  instructed to anchor on this summary going forward.
- Implementations MAY trigger agent-side compaction at phase boundaries when
  supported by the CLI.
- If an agent runtime signals context exhaustion (or a sentinel error), the
  Duet worker MUST restart or fork the runtime with a recovery message and a
  summary of all frozen artifacts. This is **not** a task failure.

### 7.6 Transport modes

The Duet worker drives turns through one of several transports. The choice
is per-task and per-agent (configurable; default applies repo-wide).

| Mode | Turn driver | Memory across turns | Latency / turn | Best for |
|------|-------------|---------------------|----------------|----------|
| `local_pair` | Claude Code local runtime + Codex App Server | Native runtime histories | Fast | Default development and trusted devbox operation |
| `cloud_pair` | Cloud-backed Claude/Codex runtimes where configured | Runtime-specific | Slow/async | Expensive CODE work, remote compute, laptop-independent runs |
| `github_bot` | `@claude` / `@codex` mentions on the PR; bot workflow handles the turn | None unless bot reconstructs context | ~30 s – 2 min | REVIEW phase and human-triggered side turns |
| `hybrid` | Per-phase mix of local, cloud, and bot runtimes | Mixed | Mixed | Recommended production mode |

The convergence substrate is **identical across modes** — both transports
manifest as PR review state (`APPROVED` / `CHANGES_REQUESTED`), parsed per
§9.3 and §10. The structured trailer (§10.1) MAY appear in bot reviews
when the bot is prompted to emit it; if absent, the orchestrator falls
back to the GitHub review state alone (`APPROVED` ↔ `verdict: APPROVE`,
`CHANGES_REQUESTED` ↔ `verdict: REQUEST_CHANGES`, `unresolved` synthesized
from the bot's review-comment threads).

#### 7.6.1 `github_bot` mode requirements

- Both agents MUST have GitHub bot integrations installed on the parent
  repo. As of v0.1: Anthropic's
  [`claude-code-action`](https://github.com/anthropics/claude-code-action)
  (triggered by `@claude` in PR/issue comments — similar to the workflows in
  the parent repo), and OpenAI's Codex GitHub integration (triggered by
  `@codex`). A workflow that only posts a plain PR comment is useful for
  feedback, but is not conformant for Duet convergence unless the orchestrator
  can also derive `APPROVED` / `CHANGES_REQUESTED` review state or a
  trailer-bearing author acknowledgement from it.
- Per-turn invocation: the orchestrator pushes the artifact commit, then
  posts a structured PR comment of the form:

  ```
  @<reviewer-handle> please review revision <sha> per Duet protocol.
  Phase: <SPEC|PLAN|CODE|REVIEW>  Cycle: <n>
  Required output: a PR review (APPROVE or REQUEST_CHANGES) plus,
  optionally, a ---DUET-TRAILER--- block in the review body.
  ```
- The orchestrator detects review completion via webhook (`pull_request_review.submitted`)
  or by polling the PR review API. A per-turn timeout
  (`github_bot.turn_timeout_ms`, default 600 000 ms) applies; on timeout
  the turn is retried up to 3 times before falling back to
  `REQUEST_CHANGES` synthesized with `unresolved: [bot_timeout]`.
- Rate limits and Actions-minute quotas apply; operators SHOULD
  rate-limit `github_bot`-mode tasks separately from local/cloud runtime
  tasks via `max_parallel_tasks` overrides per transport.

#### 7.6.2 Memory considerations

Persistent runtime memory is useful but not the source of truth. Duet phase
state MUST be reconstructable from tracker state, workspace contents, event
logs, branch tips, PR state, and phase-freeze summaries. Bot and cloud turns may
start from fresh context, so the *phase-freeze message* (§8.4) SHOULD be posted
as a canonical PR/workpad anchor whenever a fresh runtime might be invoked.

#### 7.6.3 Hybrid mode mapping

In `hybrid` mode the default phase-to-transport mapping is:

| Phase   | Transport     | Rationale |
|---------|---------------|-----------|
| SPEC    | `local_pair` | Iterative drafting benefits from low latency |
| PLAN    | `local_pair` | Same |
| CODE    | `local_pair` or `cloud_pair` | Local is fastest; cloud is useful for remote compute or laptop-independent execution |
| REVIEW  | `github_bot`  | Fresh-context independent review is the entire point of REVIEW |

Operators MAY override the per-phase mapping via `transport.phases.<phase>`
in `WORKFLOW.md` front matter under `duet.transport`. Transport selection
decides *how* an assigned actor runs; agent routing profiles (§7.7) decide
*which* actor is assigned to each phase role.

### 7.7 Agent routing profiles

Before a task is dispatched, the orchestrator MUST resolve an effective
agent routing profile. The profile assigns phase roles to `claude`, `codex`,
`human`, or `none` and is recorded in the event log. Implementations MAY ship
multiple named profiles, but MUST identify which profiles are full Duet
profiles and which are degraded.

The canonical full Duet profile is `duet_balanced`:

| Phase | Author | Reviewer(s) | Notes |
|-------|--------|-------------|-------|
| `SPEC` | `claude` | `codex` | Claude drafts the spec, Codex challenges implementability |
| `PLAN` | `codex` | `claude` | Codex drafts implementation plan, Claude challenges product/spec fit |
| `CODE` | `codex` by default | `claude` by default | PLAN may designate another implementer |
| `REVIEW` | `code_author` acknowledgement | `non_coder` GitHub review | GitHub split-signal constraints still apply (§9.3) |

Operators MAY choose profiles such as `codex_led`, `claude_led`,
`codex_only_dev`, `claude_only_dev`, or a custom profile. The following rules
apply:

- A **full Duet** profile MUST assign two distinct machine agents to the
  binding Author/Reviewer signals required by §9.3 and §10.2.
- A profile that assigns only one machine agent, disables reviewers, or uses
  `human`/`none` for a binding role is a **degraded profile**. It is useful for
  local development, exploratory drafting, or operator-directed work, but it
  MUST be labeled as not satisfying split-signal Duet convergence unless a
  second binding GitHub review is supplied later.
- Phase ordering and artifact rules do not change when a profile skips a
  reviewer. The orchestrator still records the skipped role and the freeze mode
  so the audit trail shows that the run was operator-directed.
- The orchestrator MUST NOT silently replace a profile in `WORKFLOW.md`.
  Runtime UI selections are local overrides unless the operator explicitly
  approves a configuration update.

Example: an operator MAY select Codex as SPEC Author with Claude as SPEC
Reviewer, then skip Claude for PLAN review and bring it back for CODE review.
That routing is valid as an operator-directed custom profile; skipped binding
reviews are recorded as degraded for the affected phase.

---

## 8. Phase Pipeline

### 8.1 Phase definitions

The table below defines the canonical `duet_balanced` defaults. The effective
Author/Reviewer assignment for a task comes from the active agent routing
profile (§7.7), and operator overrides MUST be reflected in prompts, PR
authors, phase-freeze messages, and events.

| Phase | Artifact | Author rule (cycle 1) | Reviewer rule (cycle 1) |
|-------|----------|-----------------------|-------------------------|
| `SPEC` | `SPEC.md` (in workspace, path: `.duet/spec.md`) | Claude | Codex |
| `PLAN` | `PLAN.md` (path: `.duet/plan.md`) | Codex | Claude |
| `CODE` | Source-file changes in the workspace repository | Whichever agent the PLAN designates as implementer; default Codex | The other agent |
| `REVIEW` | An approval record on the held-open CODE PR | The agent that DID code (acknowledges via trailer-comment; they are the CODE PR author and cannot self-approve) | The agent that did NOT code (submits the independent fresh-context PR review via GitHub's review API) |

**Default role rotation rationale:** alternating who drafts first across phases
avoids systematic anchoring on either agent's framing. The CODE phase
implementer is decided by the agents themselves during PLAN; default falls to
Codex as the more code-specialized model.

**REVIEW role assignment is constrained by GitHub** (not by symmetry) for
full Duet profiles:
the CODE PR's GitHub author is the coder, and GitHub blocks PR authors
from submitting `APPROVE` reviews on their own PRs. Therefore the
non-coder MUST be the Reviewer in REVIEW phase — they hold the only
identity that can produce the binding GitHub `APPROVE` review state on
the CODE PR. The coder's "acknowledgement" comes through the
trailer-comment channel (§9.3). This also matches the design intent of
REVIEW as a *fresh-context independent pass by the non-coder*.

If the active profile disables REVIEW or assigns it to a human, the task MAY
continue only under a degraded/operator-assisted policy and MUST NOT claim
full Duet convergence until §9.3 has been satisfied by two distinct binding
signals.

### 8.2 Phase ordering

Phases run strictly in order: SPEC → PLAN → CODE → REVIEW. A phase MUST NOT
begin until the previous phase has reached *frozen* state.

"Frozen" does **not** always mean "PR merged" (§8.3 below). For SPEC and
PLAN, freeze coincides with the phase PR's merge. For CODE, freeze means
"convergence achieved on the CODE PR" — the PR is **not** merged yet; it is
deliberately held open so the REVIEW phase can run on the same CODE PR
before it lands. This avoids the SPEC→§9.2 deadlock that would otherwise
arise (REVIEW cannot start until CODE is merged; CODE only merges after
REVIEW).

### 8.3 Phase frozen state

A phase is *frozen* when:
1. The convergence rule (§10.2) is satisfied for the current artifact
   revision, OR
2. The cycle cap is reached and the tie-breaker rule (§10.4) applies.

On freeze, behavior depends on phase:

**SPEC / PLAN** (doc-only phases, freeze = merge):
1. Orchestrator finalizes the phase's PR.
2. Orchestrator merges the PR into `duet-base/<task_id>`.
3. Orchestrator deletes the phase sub-branch.
4. Orchestrator emits a *phase-freeze* message (§8.4) to each active runtime
   for the next phase.
5. Next phase begins.

**CODE** (freeze ≠ merge — REVIEW runs on the same PR before merge):
1. Orchestrator finalizes the CODE PR (it stays open).
2. Orchestrator records the CODE-frozen tree-hash for the REVIEW phase.
3. Orchestrator emits a *phase-freeze* message to each active runtime for the
   REVIEW phase.
4. REVIEW phase begins, operating on the still-open CODE PR.

**REVIEW** (terminal — merges the CODE PR on freeze):
1. Orchestrator merges the CODE PR into `duet-base/<task_id>`.
2. Orchestrator deletes the CODE sub-branch.
3. Orchestrator emits a *phase-freeze* message and a `task_completed` event.

**Operator pause gate.** When `duet.pause_on_freeze` is `true`, the
orchestrator MUST transition the task to `awaiting_operator` with
`reason = pause_on_freeze` after emitting the phase-freeze message for
SPEC, PLAN, and CODE (not REVIEW, which is terminal). The operator resumes
via `duet resolve <task_id> --continue`. Default is `false` (no pause).
This is intended for early adoption and trust-building; operators who want
autonomous end-to-end runs leave it off.

#### 8.3.1 External conflict during held-open CODE PR

Each task's `duet-base/<task_id>` branch is exclusive to that task, so
concurrent Duet tasks cannot cause conflicts on it. However, external
modifications — an operator rebasing or pushing directly to the task branch,
or merge conflicts discovered when landing `duet-base/<task_id>` onto
`main` — may make the CODE PR unmergeable after REVIEW convergence.

The orchestrator MUST check mergeability of the CODE PR into
`duet-base/<task_id>` immediately before executing the REVIEW-freeze merge
(§8.3, REVIEW step 1). If the merge cannot be completed cleanly:

1. The task transitions to `awaiting_operator` with
   `reason = code_pr_conflict`.
2. The orchestrator emits a `code_pr_conflict` event including the CODE PR
   permalink, the conflicting paths, and the current `duet-base` HEAD.
3. The operator resolves the conflict manually and resumes via
   `duet resolve <task_id> --continue`.

Conflicts between `duet-base/<task_id>` and the parent repo's main branch
at final land time are outside Duet's scope — they are the operator's
responsibility, as with any feature branch.

### 8.4 Phase-freeze message

Sent to each active agent runtime at the moment of freeze. Schema (rendered as
text):

```
[DUET PHASE FREEZE]
Task: <task_id> — <title>
Frozen phase: <phase>
Artifact: <path or PR url>
Convergence: cycles=<n>, mode=<consensus|forced|tie_breaker>

Summary of frozen artifact:
<adaptive-length summary, generated by the orchestrator from the merged artifact>

Next phase: <next_phase>
Your role next phase: <author|reviewer|coder_ack|skipped>
Active routing profile: <profile_name>
```

**Summary length.** The summary length SHOULD be proportional to the
artifact size rather than a fixed cap:

- SPEC / PLAN: `min(1500, artifact_word_count × 0.5)` words.
- CODE: `min(3000, diff_lines × 2)` words.
- Minimum in all cases: 300 words (enough context to anchor the next phase).

Implementations MAY use a fixed cap as a simplification in v1, but SHOULD
document the chosen heuristic.

The summary is the agents' anchor for the rest of the task. They are
instructed not to relitigate decisions captured in the summary.

### 8.5 Optional SuperPower artifact mode

Implementations MAY support a SuperPower artifact mode for operators who want
SPEC, PLAN, and REVIEW documents to follow the SuperPower repository's
artifact conventions. This mode is optional and MUST NOT replace the Duet
machine state under `.duet/`.

When `duet.superpower.enabled` is `true`:

- SPEC artifacts SHOULD be written or mirrored under
  `docs/superpowers/specs/` using a design-spec structure suitable for a
  separate implementer to read without hidden context.
- PLAN artifacts SHOULD be written or mirrored under
  `docs/superpowers/plans/` and SHOULD include task checkboxes, gates, files
  to create/modify, validation commands, and implementation notes.
- REVIEW artifacts SHOULD be written or mirrored under
  `docs/superpowers/reviews/` and SHOULD use explicit verdicts plus P0/P1
  findings and required corrections.
- In `mirror` mode, SuperPower artifacts are human-facing copies of the
  canonical Duet phase artifact; Duet convergence still uses PR state,
  trailers, tree hashes, and event logs.
- In `enforce` mode, the orchestrator MAY reject a phase artifact that does
  not satisfy the configured SuperPower template checks, but those checks are
  additional policy and not a substitute for §10 convergence.

The effective SuperPower setting for a task MUST be logged at task start. If
an implementation imports templates or skills from a SuperPower repository, it
MUST document the source and version in its §17 implementation-defined notes.

---

## 9. PR-as-Artifact Protocol

### 9.1 Branch topology

```
main
 └── duet-base/<task_id>                   (long-lived feature branch)
      ├── duet-phase/<task_id>/spec        (sub-branch, ephemeral)
      ├── duet-phase/<task_id>/plan        (sub-branch, ephemeral)
      └── duet-phase/<task_id>/code        (sub-branch, ephemeral)
```

- `duet-base/<task_id>` is created at task start, branched from `origin/<base>`.
- Each phase sub-branch is created from the current tip of `duet-base/<task_id>`,
  contains the phase's artifact commits, and is merged back into
  `duet-base/<task_id>` at phase freeze.
- The parent repo's main branch is touched only at task end, when the
  operator decides whether to land `duet-base/<task_id>` (manually or via a final
  PR — out of scope for this spec).

### 9.2 PR per phase

| Phase  | PR base | PR head | Convergence signal source |
|--------|---------|---------|---------------------------|
| SPEC   | `duet-base/<task_id>` | `duet-phase/<task_id>/spec`  | Reviewer = GitHub PR review state; Author = `---DUET-TRAILER---` in a regular PR comment (see §9.3) |
| PLAN   | `duet-base/<task_id>` | `duet-phase/<task_id>/plan`  | Same |
| CODE   | `duet-base/<task_id>` | `duet-phase/<task_id>/code`  | Same |
| REVIEW | (no separate PR — runs on the still-open CODE PR; merges it on freeze) | — | Reviewer (= non-coder) GitHub PR review; Coder acknowledgement via trailer-comment |

The CODE PR is held open across CODE *and* REVIEW phases; the merge into
`duet-base/<task_id>` happens only on REVIEW freeze (§8.3). This is what
makes the "fresh-context independent reviewer" property of REVIEW
implementable without a separate REVIEW PR.

### 9.3 PR review semantics — split signal model

Both agents emit machine-readable verdicts, but **through different
GitHub channels** because GitHub does not allow PR authors to submit
`APPROVE` reviews on their own PRs. The spec splits the convergence
signal accordingly:

- **The Reviewer** (whichever agent is *not* the PR author for that
  phase) submits a GitHub PR review via the standard review API. State
  is `APPROVE` ↔ trailer `verdict: APPROVE`; `REQUEST_CHANGES` ↔
  trailer `verdict: REQUEST_CHANGES`. Inline comments from the agent's
  output, when present, are attached as PR review comments anchored to
  the relevant lines.
- **The Author** (the agent who pushed the artifact commits, and is
  therefore the PR creator) emits their verdict as a `---DUET-TRAILER---`
  block (§10.1) inside a **regular PR issue-comment**, *not* a review.
  The orchestrator parses the trailer the same way; this is the
  Author's binding signal of "I agree with the current revision."

The orchestrator constructs convergence by combining both channels
(§10.2). Author and Reviewer trailers MUST reference the same revision
tree-hash, otherwise convergence is not satisfied.

**Distinct GitHub identities are required.** The two agents MUST be
configured with distinct GitHub identities — i.e. the GitHub author of a
phase sub-branch's commits MUST differ from the identity used by the
other agent to submit PR reviews on that PR. Without this, the
split-signal model collapses (a single identity cannot be both PR
author *and* the entity submitting an `APPROVE` review on the same PR),
which makes §10.2 convergence unreachable. Operators MAY use two
service accounts, two GitHub Apps, or one human + one service account;
running both agents under a single shared identity is **not
conformant** (§16).

### 9.4 PR titles and bodies

```
PR title:  [duet:<task_id>] <phase>: <title>
PR body:   <auto-generated, includes task description, current cycle,
            and a link to the task's event log>
```

### 9.5 Author of commits

Commits within a phase sub-branch are authored under the agent's identity
(configurable; default `Duet <agent>` with a host-level email). Co-author
trailers are added when both agents materially contribute to a single
commit, but the standard pattern is one author per commit.

### 9.6 Bot identity

If the operator configures bot accounts, the Claude-side and Codex-side
operations still MUST resolve to distinct GitHub identities for approval
purposes (§9.3). A single shared bot account may be used only for
non-binding comments or local commit authorship when a separate review
identity exists; it is not sufficient for the split-signal convergence model.
The agent identity is also recorded in commit trailers to preserve attribution.

---

## 10. Convergence Protocol

### 10.1 Structured response trailer

Every agent response in a pair-loop turn MUST end with a fenced trailer:

```
---DUET-TRAILER---
verdict: APPROVE | REQUEST_CHANGES
confidence: 0.0..1.0
summary: <one-line summary of position>
unresolved: [<list of unresolved concerns; empty if APPROVE>]
---END-DUET-TRAILER---
```

The orchestrator parses only the trailer. Prose above the trailer is
informational and is preserved verbatim in PR comments.

If a response contains **multiple** `---DUET-TRAILER---` blocks (e.g. the
agent quoted a previous turn or echoed instructions), the orchestrator MUST
consider only the **last syntactically valid** block and ignore all earlier
ones. This prevents trailer-injection from agent output that incorporates
prior context verbatim.

If a response is missing the trailer or it cannot be parsed, the orchestrator
re-prompts the agent **once** with an explicit reminder. A second failure is
treated as `REQUEST_CHANGES` with `unresolved: [malformed_response]`.

#### 10.1.1 Semantic validation

A syntactically valid trailer MAY still be semantically incoherent. The
orchestrator MUST apply the following checks before accepting a trailer:

- `verdict: APPROVE` with a non-empty `unresolved` list → re-prompt the agent
  once, citing the contradiction. If the second response still contradicts,
  treat as `REQUEST_CHANGES` with the original `unresolved` list preserved.
- `confidence < 0.3` with `verdict: APPROVE` → accept the verdict but emit a
  `low_confidence_approve` warning in the event log.
- `verdict: REQUEST_CHANGES` with an empty `unresolved` list → accept the
  verdict and synthesize `unresolved: [no_details_provided]`.

#### 10.1.2 Trailer anchoring to revision

The trailer schema does not contain a tree-hash field. The orchestrator MUST
associate each parsed trailer with the commit tree-hash at `HEAD` of the phase
sub-branch at the moment the turn was dispatched. This observed tree-hash — not
any hash claimed by the agent — is the binding revision for convergence
checks (§10.2).

A trailer MUST appear within the final 50 lines of the agent's response. If
the last valid `---DUET-TRAILER---` block starts earlier than 50 lines from
the end, the orchestrator MUST reject it, emit a `trailer_rejected` event
(§13.1) with `reason = position_invalid`, and re-prompt once.

### 10.2 Convergence rule

A phase reaches *convergence* iff **both** of the following hold for the
same revision of the artifact within the same cycle:

1. The **Reviewer's** GitHub PR review state is `APPROVED` (equivalent
   to trailer `verdict: APPROVE`), AND
2. The **Author's** most recent `---DUET-TRAILER---` comment on the PR
   carries `verdict: APPROVE`.

Both signals MUST reference the same revision (commit tree-hash on the
phase sub-branch's HEAD; see below). Either signal alone is
insufficient; the split exists because GitHub PR authors cannot submit
`APPROVE` reviews on their own PRs (§9.3).

If the active routing profile disables one of these two binding signals,
the phase cannot reach full Duet convergence. It MAY still freeze under a
degraded/operator-assisted policy, but the freeze event MUST record
`convergence = degraded`, the active profile name, and the missing binding
role. Production implementations SHOULD require an explicit operator approval
before such a run can land code on the parent repository's main branch.

A revision is "the same" iff the **commit tree-hash** — i.e. the tree
object referenced by the phase sub-branch's `HEAD` commit — is identical
between the two responses. By construction this includes only tracked
files that are part of that commit; untracked files, files matched by
`.gitignore`, and any agent-generated build artifacts in the working tree
(`node_modules/`, `__pycache__/`, coverage reports, etc.) are explicitly
**excluded** from the convergence check. The orchestrator MUST compute
this hash from the commit object, not from `git write-tree` against the
live working tree, so convergence is unaffected by filesystem noise. If
the Reviewer approves and the Author then amends the artifact in their
next turn, convergence is reset.

### 10.3 Cycle cap

`max_cycles_per_phase` (default **5**). Counted as Author→Reviewer
round-trips.

### 10.4 Tie-breaker (cycle cap reached)

Behavior at cap depends on the phase. Doc-only phases (SPEC, PLAN) are
permitted to force-converge; the CODE phase is not, by default.

#### 10.4.1 SPEC and PLAN phases

When the cap is reached without convergence:
1. The orchestrator selects the **last revision authored by the Reviewer**
   (i.e. the most recent revision the Reviewer touched, even if to
   `REQUEST_CHANGES`). Rationale: the reviewer's terminal position is the
   more critical one.
2. If the Reviewer never authored a revision, the most recent Author
   revision is used.
3. The phase is frozen with `mode = forced`. The event log records
   `forced_convergence = true` and lists the unresolved items.

#### 10.4.2 CODE phase

The CODE phase MUST NOT auto-merge a Reviewer-rejected revision. When the
cap is reached without convergence, the **default** behavior is:

1. The task transitions to state `awaiting_operator` (terminal pause —
   it is no longer running, but not yet `failed` or `completed`).
2. The orchestrator emits a `phase_cap_escalation` event containing:
   the Reviewer's last verdict, the unresolved list, the Author's last
   revision SHA, the Reviewer's last authored revision SHA (if any),
   and a permalink to the CODE PR.
3. If a notification hook is configured, it is invoked with the same
   payload.
4. The operator may resume the task by invoking one of:
   - `duet resolve <task_id> --approve-author` — merges the Author's
     last revision; phase frozen with `mode = operator_override_author`.
   - `duet resolve <task_id> --approve-reviewer` — merges the Reviewer's
     last authored revision (rejected if the Reviewer never authored);
     phase frozen with `mode = operator_override_reviewer`.
   - `duet resolve <task_id> --fail` — marks the task `failed` with
     `reason = code_phase_unresolved`.

**Operator-configured override:** an operator MAY opt to skip escalation
and apply the SPEC/PLAN tie-breaker rule to CODE as well. This is
explicitly weaker (it can ship Reviewer-rejected code) and is intended
only for harnesses where merge protection is enforced elsewhere — e.g.
required human approvals on the parent-repo PR before `duet-base/<task_id>`
lands on `main`. The override is configured via `code_phase_cap_policy`
in `WORKFLOW.md` front matter under `duet.code_phase_cap_policy`:

```yaml
code_phase_cap_policy: escalate   # default — pause for operator
# code_phase_cap_policy: forced   # apply SPEC/PLAN rule; ships rejected code
# code_phase_cap_policy: fail     # auto-fail the task; never ships
```

The default is `escalate`. Implementations MUST log the chosen policy at
task start so the operator's choice is visible in the audit trail.

### 10.5 Pathological-disagreement detector

If three consecutive cycles in the same phase produce identical
`unresolved` lists (string-equal after normalization), the orchestrator
MUST:
1. Halt the phase.
2. Mark the task `failed` with `reason = pathological_disagreement`.
3. Surface the unresolved list to the operator via the event log and
   (if configured) a notification hook.

Restarting requires operator action; the harness does not auto-recover from
deadlock.

---

## 11. Failure Modes and Recovery

| Failure | Detection | Action |
|---------|-----------|--------|
| Agent runtime crash | Process exit, cloud failure, or bot failure before turn complete | Resume runtime by ID where possible; replay phase summary; retry turn (max 3 retries) |
| Agent runtime hang | Per-turn timeout (default 600 s) | Kill/cancel runtime where possible; resume/fork; retry turn |
| Bot turn timeout (`github_bot`) | No PR review within `github_bot.turn_timeout_ms` | Re-post `@<reviewer>` comment; max 3 retries; then `REQUEST_CHANGES` with `unresolved: [bot_timeout]` |
| Bot integration missing (`github_bot`) | `@mention` produces no review and no app-installed signal | Mark task `failed` with `reason = bot_integration_missing` |
| Malformed trailer | Trailer regex fails | Re-prompt once; second failure → `REQUEST_CHANGES` synthesized |
| GitHub API error | Non-2xx, non-rate-limit | Exponential backoff (2s/4s/8s/16s); after 4 attempts, surface to operator |
| Rate limit | 403/429 | Honor `Retry-After`; pause all GitHub-bound work for that duration |
| Workspace or Git corruption | Workspace or Git command fails | Mark task `failed`; do NOT auto-recreate (preserve evidence) |
| Cycle cap reached (SPEC/PLAN) | Counter ≥ `max_cycles_per_phase` | Apply §10.4.1 tie-breaker; freeze with `mode = forced` |
| Cycle cap reached (CODE, default) | Counter ≥ `max_cycles_per_phase` | Transition to `awaiting_operator`; emit `phase_cap_escalation`; await `duet resolve` (§10.4.2) |
| Cycle cap reached (CODE, override) | Operator set `code_phase_cap_policy: forced` or `fail` | Apply chosen override (§10.4.2) |
| Pathological disagreement | §10.5 detector | Mark task `failed` |
| Context exhaustion | Agent runtime signal or sentinel | Restart/fork runtime with recovery message; not a task failure |
| Orchestrator restart | Process exit | Reconstruct state from event log, PRs, and branch tips; resume from last frozen phase when possible; discard only non-frozen mid-phase work |
| External branch modification | `duet-base` HEAD differs from expected | Detect at next phase transition or REVIEW merge; transition to `awaiting_operator` with `reason = code_pr_conflict` (§8.3.1) |

### 11.1 Recovery truth hierarchy

On orchestrator restart, multiple sources may describe task state. They are
consulted in priority order:

1. **GitHub PR review state** (submitted reviews on phase PRs) — primary
   observable signal. Submitted review records are durable; the binding state
   is the latest non-dismissed review per identity. PR bodies and
   issue-comments can be edited by third parties, so only review states carry
   binding weight for convergence reconstruction.
2. **Branch tips** (`duet-base/<task_id>`, `duet-phase/<task_id>/*`) —
   confirmation of which phases have been merged and which sub-branches
   still exist.
3. **Structured event log** (`events.jsonl`) — complement for data not
   observable through GitHub: internal cycle counts, verdicts from
   `local_pair` and other non-GitHub runtime turns, phase-freeze metadata.

If the event log and GitHub/branch state conflict (e.g. the log says
"SPEC frozen, PLAN in progress" but no SPEC phase PR exists as merged), the
orchestrator MUST NOT attempt automatic reconciliation. It MUST:

1. Transition the task to `awaiting_operator` with
   `reason = state_divergence`.
2. Emit a `state_divergence` event listing the conflicting signals.
3. Await operator resolution before resuming.

---

## 12. Configuration

Duet preserves Symphony's `WORKFLOW.md` repository contract: YAML front matter
for runtime configuration plus a Markdown prompt body for the issue workflow.
Duet-specific settings live under a `duet:` front-matter key so upstream
Symphony fields can remain recognizable and mergeable.

`duet.config.yaml` MAY exist as a local developer override, but it MUST NOT
replace `WORKFLOW.md` as the primary repository-owned workflow contract.

```yaml
tracker:
  kind: linear
  project_slug: "my-project"
  active_states: ["Todo", "In Progress", "Rework", "Merging"]
  terminal_states: ["Done", "Closed", "Cancelled", "Duplicate"]

polling:
  interval_ms: 30000

workspace:
  root: ~/code/symphony-workspaces

hooks:
  after_create: |
    git clone git@github.com:myorg/myrepo.git .
  before_run: null
  after_run: null
  before_remove: null
  timeout_ms: 60000

agent:
  max_concurrent_agents: 10
  max_turns: 20

codex:
  # Preserved Symphony/Codex settings used by the Codex half of the duet.
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write

duet:
  enabled: true
  max_cycles_per_phase: 5
  phase_turn_timeout_ms: 600000
  phase_total_timeout_ms: 7200000
  code_phase_cap_policy: escalate      # escalate | forced | fail
  pause_on_freeze: false               # if true, task pauses after each phase freeze for operator review
  agent_menu:
    enabled: true
    require_selection_before_dispatch: true
  agent_routing:
    default_profile: duet_balanced
    allow_single_agent_profiles: true  # allowed only as degraded/operator-assisted runs
    profiles:
      duet_balanced:
        mode: full_duet
        phases:
          spec:   { author: claude, reviewers: [codex] }
          plan:   { author: codex, reviewers: [claude] }
          code:   { author: codex, reviewers: [claude] }
          review: { coder_ack: code_author, reviewer: non_coder }
      codex_led:
        mode: full_duet
        phases:
          spec:   { author: codex, reviewers: [claude] }
          plan:   { author: codex, reviewers: [claude] }
          code:   { author: codex, reviewers: [claude] }
          review: { coder_ack: code_author, reviewer: non_coder }
      claude_led:
        mode: full_duet
        phases:
          spec:   { author: claude, reviewers: [codex] }
          plan:   { author: claude, reviewers: [codex] }
          code:   { author: claude, reviewers: [codex] }
          review: { coder_ack: code_author, reviewer: non_coder }
      codex_only_dev:
        mode: degraded_single_agent
        phases:
          spec:   { author: codex, reviewers: [] }
          plan:   { author: codex, reviewers: [] }
          code:   { author: codex, reviewers: [] }
          review: { coder_ack: code_author, reviewer: human }
      claude_only_dev:
        mode: degraded_single_agent
        phases:
          spec:   { author: claude, reviewers: [] }
          plan:   { author: claude, reviewers: [] }
          code:   { author: claude, reviewers: [] }
          review: { coder_ack: code_author, reviewer: human }
  superpower:
    enabled: false
    root: docs/superpowers
    mode: mirror                      # mirror | enforce
    phases:
      spec: true
      plan: true
      code: false
      review: true
    require_plan_checkboxes: true
  branch:
    base_prefix: duet-base
    phase_prefix: duet-phase
    base_branch: null                  # null = detect from repository remote
  transport:
    default: hybrid                    # local_pair | cloud_pair | github_bot | hybrid
    phases:
      spec: local_pair
      plan: local_pair
      code: local_pair                 # or cloud_pair
      review: github_bot
  agents:
    claude:
      runtime: claude_code             # claude_code | github_bot | cloud
      command: ["claude", "--print", "--output-format", "stream-json"]
      role_alias: Claude
    codex:
      runtime: app_server              # app_server | codex_cloud | codex_exec | github_bot
      role_alias: Codex
      cloud:
        env_id: null
  github_bot:
    claude_handle: "claude"
    codex_handle: "codex"
    turn_timeout_ms: 600000
    poll_interval_ms: 15000
```

### 12.1 Environment variables

| Var | Purpose |
|-----|---------|
| `DUET_GITHUB_TOKEN` | Overrides `gh auth` token resolution |
| `DUET_LOG_LEVEL` | `debug` / `info` / `warn` / `error` |
| `DUET_CONFIG` | Optional local override file; does not replace `WORKFLOW.md` |
| `DUET_DRY_RUN` | If set, no PRs are opened, no commits pushed, no hooks executed |
| `CODEX_CLOUD_ENV_ID` | Optional default Codex Cloud environment for `duet.agents.codex.runtime = codex_cloud` |

---

## 13. Logging and Observability

### 13.1 Structured event log

`<log_dir>/tasks/<task_id>/events.jsonl` — append-only newline-delimited
JSON. Each event:

```json
{
  "ts": "2026-05-09T14:32:01Z",
  "task_id": "auth-refactor",
  "phase": "SPEC",
  "cycle": 2,
  "actor": "claude",
  "kind": "turn_response",
  "verdict": "REQUEST_CHANGES",
  "pr_number": 142,
  "tree_hash": "a1b2c3...",
  "extra": { ... }
}
```

Event `kind` values: `task_queued`, `task_started`, `workspace_created`,
`runtime_started`, `phase_started`, `turn_request`, `turn_response`,
`pr_opened`, `pr_review_posted`, `pr_merged`, `phase_frozen`, `task_completed`,
`task_failed`, `runtime_crashed`, `runtime_resumed`,
`bot_mention_posted`, `bot_review_received`, `bot_timeout`,
`phase_cap_escalation`, `trailer_rejected`, `low_confidence_approve`,
`code_pr_conflict`, `state_divergence`, `agent_routing_selected`,
`routing_override_applied`, `superpower_artifact_written`,
`superpower_artifact_rejected`.

### 13.2 Per-turn transcripts

Each turn's full prompt and response are written to
`<log_dir>/tasks/<task_id>/transcripts/<phase>-<cycle>-<actor>.md` for audit.

### 13.3 Optional HTTP API

Implementations MAY expose:
- `GET /api/v1/tasks` — list tasks with state
- `GET /api/v1/tasks/<id>` — task detail + current phase
- `GET /api/v1/tasks/<id>/events` — stream of events
- `GET /api/v1/config/agent-routing` — available profiles and defaults
- `GET /api/v1/healthz`

A web dashboard is permitted but optional.

### 13.4 Operator agent routing UI

An implementation with a dashboard or desktop UI MUST expose an initial
operator menu before dispatching a task when `duet.agent_menu.enabled` is
`true`. A headless implementation MUST provide an equivalent CLI/config
selection surface.

The menu MUST allow the operator to:

- Choose active agents: Claude, Codex, both, human-assisted, or a saved custom
  profile.
- Select a named agent routing profile and inspect the phase matrix before the
  task starts.
- Override, per phase, the Author, Reviewer(s), REVIEW coder acknowledgement,
  and any skipped actors.
- Toggle optional SuperPower artifact mode for the task when supported.
- See whether the selected profile is `full_duet` or degraded, and why.
- Confirm the effective routing before the first runtime turn is dispatched
  when `require_selection_before_dispatch` is `true`.

The UI MUST display the effective routing during task execution so operators
can see where Claude and Codex are used. At task start, the orchestrator MUST
emit `agent_routing_selected` with the profile name, phase matrix, conformance
classification, and SuperPower settings. Per-task operator changes after
selection MUST emit `routing_override_applied`.

---

## 14. Security Posture

- The orchestrator runs with the operator's filesystem and GitHub
  privileges. It MUST NOT escalate.
- Workspace paths are validated against the configured root before any agent
  is spawned (path-traversal defense).
- Hook scripts run with a sanitized environment; only documented variables
  are passed through.
- Agent prompts sourced from operator input (`description`) MUST be
  bounded in length (default 50 000 chars) and rendered via a strict
  template — no shell interpolation.
- GitHub tokens are read from environment or `gh auth`; never written to
  workspaces or transcripts. Transcripts MUST redact known credential
  patterns (AWS keys, PEM blocks, generic API key patterns).
- The orchestrator MUST NOT push to protected branches; the parent repo's
  branch protection rules are the operator's responsibility, but the
  orchestrator confines itself to `duet-base/<task_id>` and `duet-phase/<task_id>/*`.
- Agents have full filesystem access *within their workspace*. They have
  whatever GitHub permissions the configured token grants. Operators
  should provision a least-privilege bot account for production use.

---

## 15. CLI Surface (informative)

A reference CLI should remain close to Symphony's service entrypoint and add
Duet-specific inspection commands. Implementations MAY differ.

```
duet-symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]
duet status [--id <task_id>]
duet logs --id <task_id> [--phase SPEC|PLAN|CODE|REVIEW] [--follow]
duet config validate [path-to-WORKFLOW.md]
duet profiles list
duet profiles show <profile_name>
duet abandon --id <task_id>      # graceful: closes PRs if any, releases claim, removes workspace
duet prune                       # deletes merged duet-base/* and duet-phase/* branches

# Optional local/manual ingestion extension:
duet run --id <task_id> --title "<...>" --description-file <path> \
  [--profile duet_balanced|codex_led|codex_only_dev|...] [--superpower]
```

---

## 16. Conformance

A conformant implementation MUST:

1. Honor §6 workspace and branch invariants (containment, sanitization, cleanup).
2. Preserve Symphony-compatible tracker polling, dispatch, retry/backoff,
   workspace lifecycle, hooks, logs, and observability behavior unless this
   spec explicitly overrides it.
3. Implement at least one transport mode from §7.6; when a full Duet profile is
   used, Claude and Codex runtimes MUST both be active and runtime instances
   MUST never be shared across tasks (§7.1–§7.2).
4. Run phases strictly in order SPEC → PLAN → CODE → REVIEW (§8.2).
5. Use GitHub PRs as the convergence substrate; convergence MUST be
   derived from the **split signal model** of §9.3 (Reviewer's PR review
   state + Author's trailer-bearing PR comment), never from prose alone.
6. Parse the structured trailer (§10.1) and apply the convergence,
   tie-breaker, and pathological-disagreement rules (§10.2–§10.5).
7. Implement an operator-selectable agent routing profile mechanism (§7.7)
   and clearly label degraded profiles that cannot satisfy full Duet
   convergence without a second binding review.
8. Emit the structured event log (§13.1).
9. Document its choices for any §17 implementation-defined item.

A conformant implementation MAY:

- Choose any host language.
- Add additional tracker/queue/ingest sources beyond Linear and manual CLI.
- Add or extend an HTTP API or dashboard.
- Add additional hook points so long as the contract above is preserved.

---

## 17. Implementation-Defined

Each port MUST document its choice for the following:

- **Host language and runtime.**
- **Process supervisor strategy** (in-process threads, OS supervisor, etc.).
- **Upstream strategy** (fork, subtree, vendored copy, or independent port) and
  how upstream Symphony updates are merged.
- **Transport modes supported** (`local_pair`, `cloud_pair`, `github_bot`,
  `hybrid`) and the default.
- **Agent routing profiles** shipped by default, which profiles are full Duet
  vs degraded, how per-task overrides are persisted, and how the operator UI
  or CLI exposes the initial selection menu.
- **Runtime interaction mode** per agent (`codex_app_server`, `codex_cloud`,
  `codex_exec`, `claude_code_print`, `claude_code_stream`, `github_bot`, etc.).
- **Bot integration handles and webhook vs polling** — applies only when
  `github_bot` is supported.
- **GitHub identity assignment** for each agent (which service
  account, GitHub App, or human handle commits and reviews are made
  under). Per §9.3, the two agents MUST have distinct identities;
  document the chosen mapping.
- **PR review-comment parsing approach** (line-anchor heuristics).
- **Log sink targets** beyond the local jsonl.
- **Whether `after_run` and `before_remove` hooks may run agent-spawned
  scripts**, and the sandboxing posture for those.
- **GitHub access mechanism** (PAT, GitHub App, bot account).
- **Whether workspaces are removed on success only, or always.**
- **SuperPower integration policy**, if supported: source repository or
  template version, artifact root, `mirror` vs `enforce` mode, phase coverage,
  and any template validation rules.
- **Claude Code adapter limitations.** Claude Code's structured mode
  (`--print --output-format stream-json`, with `--resume` and `--session-id`
  for persistence) does not expose a bidirectional JSON-RPC protocol like
  Codex App Server, and has no native thread-sandbox equivalent. The adapter
  MUST document: how stream-json output is parsed into turn responses, how
  session IDs are managed across phase boundaries, and what the fallback
  behavior is when `--print` fails or the CLI version does not support
  `--output-format stream-json`.

---

## 18. Open Questions

These are design decisions deferred until first implementation; treat them
as RFC anchors.

1. **CODE phase implementer choice.** Hard-coded default vs. agents
   negotiate during PLAN. Currently: hard-coded default Codex, overridable
   in PLAN. Is the override mechanism worth the complexity?
2. **Upstream patch shape.** Should the first implementation directly fork the
   Elixir reference implementation, vendor it as a subtree, or recreate the
   Symphony contract in another language while tracking upstream behavior with
   conformance tests?
3. **Agent runtime boundary.** Can the `AgentRunner` replacement be shaped so
   the single-Codex Symphony worker remains available as compatibility mode?
4. **Codex Cloud integration.** Should Codex Cloud be used only for CODE, or
   may SPEC/PLAN/REVIEW also run through cloud when latency is acceptable?
5. **Claude runtime parity.** Claude Code does not currently expose the same
   App Server protocol as Codex; should the first adapter use
   `--print --output-format stream-json` with `--resume`/`--session-id`,
   GitHub bot mode, or a remote worker wrapper?
6. **Phase-freeze summary length.** 1500 words is a guess; should depend on
   artifact size or agent context window.
7. **Single CODE PR vs. multi-commit incremental review.** v1 specifies a
   single CODE PR; large changes might need progressive reviews.
8. **Reviewer-driven amendments.** Today the Author owns the artifact. Should
   the Reviewer be allowed to push direct edits during code phase
   (Reviewer-as-pair)? Probably yes, but needs role-permission rules.
9. **Cross-phase memory pruning.** When the agent CLI doesn't support
   compaction, what's the orchestrator's fallback for very long tasks?
10. **Routing override persistence.** Should per-task UI overrides remain only
   in the event log, or should operators be offered a promoted
   `WORKFLOW.md` patch when a custom routing profile proves useful?
11. **Failure replay.** If a task fails mid-phase, should the operator be
   able to resume from a specific cycle, or is restart-from-phase-boundary
   sufficient?
12. **SuperPower template source.** Should the first implementation vendor
   SuperPower templates, reference a checked-out SuperPower repo, or treat
   templates as operator-provided local configuration?

---

## 19. Versioning

This spec is versioned via `Version:` at the top. Backward-incompatible
changes increment the major version. A conformant implementation declares
the spec version it targets in its `--version` output.

---

## 20. License

This specification is released under the same license as the parent
repository.
