# Duet-Symphony Specification

**Version:** 0.1.0 (draft)
**Status:** Design — not yet implemented
**Audience:** implementers porting this spec to any language

---

## 1. Purpose

Duet-Symphony is a **two-agent adversarial collaboration harness** that drives a
pair of large language model agents — by default **Claude** and **Codex** —
through a structured pipeline of phases (specification, plan, code, review)
with **GitHub Pull Requests as the artifact and convergence substrate**, and
**git worktrees as the parallel-task isolation mechanism**.

The goal is not "more deliberation," but **structured disagreement that
produces verifiable artifacts**. Each phase ends with both agents explicitly
agreeing on a frozen artifact (markdown spec, markdown plan, code diff). SPEC
and PLAN artifacts are recorded as merged phase PRs; CODE is deliberately held
open through REVIEW and merged only after the final independent review. Multiple
tasks run in parallel, each in its own git worktree, with an isolated pair of
long-running CLI sessions per task.

This document is **language-agnostic**. A reference implementation may be
written in any language; the contract below is the source of truth.

### 1.1 Relation to Symphony

The harness model in this spec is **directly inspired by OpenAI's Symphony**
(<https://github.com/openai/symphony>, see its `SPEC.md`). The following
patterns are borrowed and adapted:

| Symphony concept                                       | Duet-Symphony equivalent |
|--------------------------------------------------------|---------------------|
| Per-issue isolated workspace                           | Per-task git worktree on `duet-base/<task_id>` (§6) |
| Single-authority orchestrator with in-memory state     | Same model — single orchestrator process, no cross-restart persistence in v1 (§4.1) |
| Lifecycle hooks (`after_create`, `before_run`, etc.)   | Adopted with the same names and the same fatal-vs-logged semantics (§6.2) |
| Workspace path containment + key sanitization          | Adopted (§6.1); `task_id` regex unified with §5.2 |
| Approval/sandbox policy as implementation-defined      | Adopted (§17) |
| Optional HTTP API + dashboard                          | Adopted as optional (§13.3) |
| Liquid prompt templating + `WORKFLOW.md` front matter  | **Not** adopted; Duet uses a plain `duet.config.yaml` (§12) |
| (Symphony has no equivalent) — *bot-mediated review on GitHub PRs* | Added as the `github_bot` transport mode (§7.6); the parent repo's existing `claude.yml` and `claude-code-review.yml` workflows are live examples of the Anthropic side, but they still need Duet-specific prompts and review-state behavior before they are conformant. |

The following Symphony characteristics are **deliberately not** adopted:

- **Single coding agent (Codex app-server) hardcoded.** Duet runs *two*
  agents per task with strict author/reviewer role rotation (§8).
- **Linear/issue-tracker ingestion.** Duet v1 ingests via CLI only; tracker
  integration is deferred (§2, §5.3).
- **Codex protocol as the source of truth.** Duet treats both agent CLIs as
  black boxes interacting via stdin/resume; the convergence substrate is
  GitHub PR review state, not a Codex-specific protocol (§9, §10).
- **Workflow-prompt-driven agent tool authorization.** Duet's structured
  trailer (§10.1) is the only machine-parsed channel; everything else is
  prose anchored in PR comments.

In short: **Duet borrows Symphony's harness primitives (workspaces, hooks,
isolation invariants) and rewrites the agent layer as a two-agent
PR-mediated pair-loop**. The parts of Symphony that assume a single Codex
session per workspace are explicitly replaced.

---

## 2. Non-Goals (v1)

The following are **explicitly out of scope** for v1 and MUST NOT be added
without a spec amendment:

- Issue-tracker ingestion (Linear, Jira, GitHub Issues). Tasks are submitted
  via CLI in v1.
- Container or VM sandboxing beyond the natural isolation provided by git
  worktrees and per-task session processes.
- Multi-repository tasks. A task targets exactly one repository.
- More than two agents per task. The harness is a *duet*, not an *ensemble*.
- Cost tracking, token counting, budget enforcement. Operators are assumed to
  be on flat-rate plans.
- IDE integration or editor extensions.
- Automatic deployment, release, or merge to a protected branch beyond what
  the agents themselves are allowed to do.

---

## 3. Glossary

| Term | Meaning |
|------|---------|
| **Task** | A single unit of work, identified by `task_id`. Has a title and a free-form description. |
| **Phase** | One of: `SPEC`, `PLAN`, `CODE`, `REVIEW`. Phases run sequentially per task. |
| **Artifact** | The frozen output of a phase. `SPEC` → `SPEC.md`; `PLAN` → `PLAN.md`; `CODE` → source-file changes; `REVIEW` → an approval record. |
| **Author** | The agent whose turn it is to draft or revise the artifact. |
| **Reviewer** | The agent whose turn it is to critique the artifact. |
| **Cycle** | One Author → Reviewer round-trip within a phase. |
| **Convergence** | Both agents emit `APPROVE` for the same revision of the artifact in the same cycle. |
| **Phase Freeze** | The point at which a phase's artifact is locked and the next phase can begin. SPEC/PLAN freeze by merging their phase PRs; CODE freezes without merge so REVIEW can run on the held-open CODE PR. |
| **Worktree** | A `git worktree` rooted at `<worktree_root>/<task_id>` on branch `duet-base/<task_id>`. |
| **Session** | A long-running CLI process for one agent, pinned to one worktree, persisting across all phases of one task. |
| **Orchestrator** | The single process that ingests tasks, manages the worktree pool, spawns and supervises sessions, and drives phase pipelines. |

---

## 4. System Architecture

```
                       ┌──────────────────┐
        CLI input ───▶ │   Orchestrator   │
                       │ (single process) │
                       └────────┬─────────┘
                                │ dispatch (concurrency cap = N)
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
          Task α            Task β             Task γ
        ┌────────┐        ┌────────┐         ┌────────┐
        │ Pair   │        │ Pair   │         │ Pair   │
        │ Loop   │        │ Loop   │         │ Loop   │
        └───┬────┘        └───┬────┘         └───┬────┘
            │                 │                  │
   ┌────────┼────────┐
   ▼        ▼        ▼
worktree  Claude   Codex          (each task: 1 worktree
 (git)   session  session          + 2 persistent sessions
          (proc)   (proc)          + GitHub PR artifacts)
            │        │
            └───┬────┘
                ▼
        GitHub PR (artifact + convergence)
```

### 4.1 Process model

- **One** orchestrator process per host. It is the single source of truth for
  task state, worktree allocation, and session lifecycle.
- **N** concurrent tasks (configurable; default `max_parallel_tasks = 3`).
- Per task: **one** worktree + **two** long-running CLI subprocesses.
- The orchestrator does **not** persist mutable in-memory state across restarts
  in v1; in-flight tasks reconstruct state from GitHub PRs, branch tips, and
  the structured event log. Completed SPEC/PLAN phases resume from their merged
  phase PRs; a CODE phase that already reached frozen state resumes from the
  held-open CODE PR and its recorded tree hash. Non-frozen mid-phase work is
  discarded and the current phase restarts with prior context summarized.

---

## 5. Task Lifecycle

### 5.1 States

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

### 5.3 Task ingestion (v1)

Tasks are submitted via CLI:
```
duet run --id auth-refactor --title "Refactor auth to JWT" \
         --description-file ./brief.md
```
A queue file (e.g. `duet.queue.yaml`) is permitted as an implementation
extension but is not required by this spec.

---

## 6. Worktree Harness

### 6.1 Invariants

1. The orchestrator MUST be invoked from inside a git working tree (the
   *parent repo*). It rejects invocation otherwise.
2. The parent repo MUST have a configured `origin` remote pointing at a
   GitHub repository (required for the PR substrate).
3. Per-task worktrees live at `<worktree_root>/<task_id>` and MUST stay
   inside `<worktree_root>` (path containment).
4. `task_id` MUST already match the form defined in §5.2
   (`[a-z0-9][a-z0-9-]{2,63}`). The orchestrator rejects non-conforming
   task IDs at ingestion; no silent sanitization is performed. This
   regex is the single canonical rule and is reused unchanged for
   filesystem paths and git branch names.
5. The orchestrator MUST NOT operate inside the parent repo's main checkout.
   All agent activity occurs in worktrees.

### 6.2 Lifecycle

| Hook | When | On failure |
|------|------|------------|
| `before_create` | Before `git worktree add` | Fatal — task transitions to `failed` |
| `after_create` | Immediately after worktree exists | Fatal |
| `before_run` | Before sessions are spawned | Fatal |
| `after_run` | After all phases complete (success or fail) | Logged, ignored |
| `before_remove` | Before `git worktree remove` | Logged, ignored |

Hook scripts run with `cwd = <worktree>`, inherit a sanitized environment
plus `DUET_TASK_ID`, `DUET_PHASE`, and `DUET_BRANCH`. Default timeout per
hook: 60 s.

### 6.3 Worktree creation

```
git worktree add <worktree_root>/<task_id> -b duet-base/<task_id> origin/<base>
```
Where `<base>` is the parent repo's default branch (auto-detected, override
via `worktree.base_branch`).

### 6.4 Worktree teardown

On task completion (success or failed):
1. Orchestrator emits `before_remove` hook.
2. `git worktree remove <path>` (with `--force` only if the operator has set
   `worktree.force_cleanup = true`).
3. Branch `duet-base/<task_id>` is **not** deleted automatically; it is preserved
   for audit until the operator runs `duet prune`.

### 6.5 Concurrency

- `max_parallel_tasks` (default 3) gates worktree creation.
- Tasks queued beyond the cap remain in `queued` state.
- Worktrees are not shared across tasks under any circumstance.

---

## 7. Persistent Session Management

### 7.1 Per-task sessions

Each task owns **exactly two** long-running agent CLI processes:

- `session_a`: Claude (`claude` CLI in interactive/resume mode)
- `session_b`: Codex (`codex` CLI in interactive/resume mode)

Both are spawned with `cwd = <worktree_path>` immediately before the SPEC
phase begins, and persist across all phases of that task.

### 7.2 Strict per-task isolation

A session MUST NOT be shared across tasks. Cross-task history bleed is a
correctness bug, not a performance issue. The orchestrator MUST guarantee that
session ID, on-disk session log, and process PID are unique per task.

### 7.3 Session protocol

The orchestrator interacts with each session via a turn-based protocol:

```
ORCH ──prompt──▶ SESSION
ORCH ◀─response─ SESSION   (containing a structured trailer; see §10)
```

Implementations MAY use:
- stdin/stdout of the interactive CLI, OR
- session-resume mode (`claude --resume <id>`, `codex resume <id>`) with a
  fresh subprocess per turn that reuses the agent's stored history.

Both approaches are conformant; operators should pick whichever the agent CLI
supports more reliably. Stored conversation state is the agent's
responsibility, not the orchestrator's.

### 7.4 Session lifecycle

| Event | Action |
|-------|--------|
| Task moves to `running` | Spawn both sessions; record their session IDs. |
| Phase transition | Send a *phase-freeze* message (§8.4) to both. |
| Process crash | Detect via exit code or heartbeat timeout; resume from session ID with a *recovery* message replaying the frozen artifacts of completed phases. |
| Task terminal | Send a *shutdown* message; SIGTERM with 10 s grace; SIGKILL if needed. |

### 7.5 Context window pressure

By the end of a long task (SPEC + PLAN + CODE + REVIEW with multiple cycles),
session histories can be large. Mitigations:

- The orchestrator MUST send an explicit *phase-freeze* message at every
  phase boundary (see §8.4) summarizing the frozen artifact. Agents are
  instructed to anchor on this summary going forward.
- Implementations MAY trigger agent-side compaction at phase boundaries when
  supported by the CLI.
- If the agent CLI signals context exhaustion (or a sentinel error), the
  orchestrator MUST restart the session with a recovery message and a
  summary of all frozen artifacts. This is **not** a task failure.

### 7.6 Transport modes

The orchestrator drives turns through one of three transports. The choice
is per-task (configurable; default applies repo-wide).

| Mode | Turn driver | Memory across turns | Latency / turn | Best for |
|------|-------------|---------------------|----------------|----------|
| `cli_session` | Long-running CLI subprocess (§7.1–§7.5) | Native — agent retains its own context | ~1–5 s | The active SPEC/PLAN/CODE deliberation loop |
| `github_bot` | `@claude` / `@codex` mentions on the PR; bot's GitHub Action handles the turn | None — each turn is a fresh runner reconstructing context from the PR thread | ~30 s – 2 min (workflow cold start) | REVIEW phase, ad-hoc human-triggered turns, fallback when local CLIs unavailable |
| `hybrid` | `cli_session` for SPEC/PLAN/CODE; `github_bot` for REVIEW + any human-triggered side comments | Mixed | Mixed | Recommended for production: keep the inner loop fast and memory-rich, get a fresh-context bot review for the final pass |

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
  rate-limit `github_bot`-mode tasks separately from `cli_session`-mode
  tasks via `max_parallel_tasks` overrides per transport.

#### 7.6.2 Memory considerations

`cli_session` was specified first because persistent memory is the
simpler and richer model. `github_bot` does **not** retain memory; the
bot reconstructs context from the PR thread on every invocation.
Operators should anticipate that bot turns may relitigate decisions
captured in earlier prose. The *phase-freeze message* (§8.4) is
correspondingly more important in `github_bot` mode and SHOULD be
posted as a **pinned PR comment** so each fresh bot invocation has a
canonical anchor.

#### 7.6.3 Hybrid mode mapping

In `hybrid` mode the default phase-to-transport mapping is:

| Phase   | Transport     | Rationale |
|---------|---------------|-----------|
| SPEC    | `cli_session` | Iterative drafting benefits from continuity |
| PLAN    | `cli_session` | Same |
| CODE    | `cli_session` | Tight feedback loop; lots of small commits |
| REVIEW  | `github_bot`  | Fresh-context independent review is the entire point of REVIEW |

Operators MAY override the per-phase mapping via `transport.phases.<phase>`
in `duet.config.yaml`.

---

## 8. Phase Pipeline

### 8.1 Phase definitions

| Phase | Artifact | Author rule (cycle 1) | Reviewer rule (cycle 1) |
|-------|----------|-----------------------|-------------------------|
| `SPEC` | `SPEC.md` (in worktree, path: `.duet/spec.md`) | Claude | Codex |
| `PLAN` | `PLAN.md` (path: `.duet/plan.md`) | Codex | Claude |
| `CODE` | Source-file changes in the worktree | Whichever agent the PLAN designates as implementer; default Codex | The other agent |
| `REVIEW` | An approval record on the held-open CODE PR | The agent that DID code (acknowledges via trailer-comment; they are the CODE PR author and cannot self-approve) | The agent that did NOT code (submits the independent fresh-context PR review via GitHub's review API) |

**Role rotation rationale:** alternating who drafts first across phases
avoids systematic anchoring on either agent's framing. The CODE phase
implementer is decided by the agents themselves during PLAN; default falls to
Codex as the more code-specialized model.

**REVIEW role assignment is constrained by GitHub** (not by symmetry):
the CODE PR's GitHub author is the coder, and GitHub blocks PR authors
from submitting `APPROVE` reviews on their own PRs. Therefore the
non-coder MUST be the Reviewer in REVIEW phase — they hold the only
identity that can produce the binding GitHub `APPROVE` review state on
the CODE PR. The coder's "acknowledgement" comes through the
trailer-comment channel (§9.3). This also matches the design intent of
REVIEW as a *fresh-context independent pass by the non-coder*.

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
4. Orchestrator emits a *phase-freeze* message (§8.4) to both sessions.
5. Next phase begins.

**CODE** (freeze ≠ merge — REVIEW runs on the same PR before merge):
1. Orchestrator finalizes the CODE PR (it stays open).
2. Orchestrator records the CODE-frozen tree-hash for the REVIEW phase.
3. Orchestrator emits a *phase-freeze* message to both sessions.
4. REVIEW phase begins, operating on the still-open CODE PR.

**REVIEW** (terminal — merges the CODE PR on freeze):
1. Orchestrator merges the CODE PR into `duet-base/<task_id>`.
2. Orchestrator deletes the CODE sub-branch.
3. Orchestrator emits a *phase-freeze* message and a `task_completed` event.

### 8.4 Phase-freeze message

Sent to both sessions at the moment of freeze. Schema (rendered as text):

```
[DUET PHASE FREEZE]
Task: <task_id> — <title>
Frozen phase: <phase>
Artifact: <path or PR url>
Convergence: cycles=<n>, mode=<consensus|forced|tie_breaker>

Summary of frozen artifact:
<≤ 1500 word summary, generated by the orchestrator from the merged artifact>

Next phase: <next_phase>
Your role next phase: <author|reviewer>
```

The summary is the agents' anchor for the rest of the task. They are
instructed not to relitigate decisions captured in the summary.

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
conformant** (§16.4).

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
in `duet.config.yaml`:

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
| Agent CLI crash (`cli_session`) | Process exit before turn complete | Resume session by ID; replay phase summary; retry turn (max 3 retries) |
| Agent CLI hang (`cli_session`) | Per-turn timeout (default 600 s) | Kill process; resume; retry turn |
| Bot turn timeout (`github_bot`) | No PR review within `github_bot.turn_timeout_ms` | Re-post `@<reviewer>` comment; max 3 retries; then `REQUEST_CHANGES` with `unresolved: [bot_timeout]` |
| Bot integration missing (`github_bot`) | `@mention` produces no review and no app-installed signal | Mark task `failed` with `reason = bot_integration_missing` |
| Malformed trailer | Trailer regex fails | Re-prompt once; second failure → `REQUEST_CHANGES` synthesized |
| GitHub API error | Non-2xx, non-rate-limit | Exponential backoff (2s/4s/8s/16s); after 4 attempts, surface to operator |
| Rate limit | 403/429 | Honor `Retry-After`; pause all GitHub-bound work for that duration |
| Worktree corruption | Git command fails | Mark task `failed`; do NOT auto-recreate (preserve evidence) |
| Cycle cap reached (SPEC/PLAN) | Counter ≥ `max_cycles_per_phase` | Apply §10.4.1 tie-breaker; freeze with `mode = forced` |
| Cycle cap reached (CODE, default) | Counter ≥ `max_cycles_per_phase` | Transition to `awaiting_operator`; emit `phase_cap_escalation`; await `duet resolve` (§10.4.2) |
| Cycle cap reached (CODE, override) | Operator set `code_phase_cap_policy: forced` or `fail` | Apply chosen override (§10.4.2) |
| Pathological disagreement | §10.5 detector | Mark task `failed` |
| Context exhaustion | Agent CLI signal or sentinel | Restart session with recovery message; not a task failure |
| Orchestrator restart | Process exit | Reconstruct state from event log, PRs, and branch tips; resume from last frozen phase when possible; discard only non-frozen mid-phase work |

---

## 12. Configuration

The orchestrator loads `duet.config.yaml` from the parent repo root (override
via `--config`). All keys are optional unless marked Required.

```yaml
# Required
github:
  owner: "myorg"
  repo:  "myrepo"
  # Token resolution: $DUET_GITHUB_TOKEN env var, or operator's gh auth.

# Concurrency
max_parallel_tasks: 3

# Phase loop
max_cycles_per_phase: 5
phase_turn_timeout_ms: 600000        # 10 minutes per agent turn
phase_total_timeout_ms: 7200000      # 2 hours per phase, hard cap

# CODE-phase cap behavior (see §10.4.2)
code_phase_cap_policy: escalate      # escalate | forced | fail
# escalate: pause to awaiting_operator; operator picks via `duet resolve`
# forced:   apply SPEC/PLAN tie-breaker; CAN ship Reviewer-rejected code
# fail:     auto-mark task `failed`; never ships

# Worktree
worktree:
  root: ".duet/worktrees"            # relative to parent repo
  base_branch: null                  # null = auto-detect default
  force_cleanup: false

# Hooks (all optional, all run with cwd = worktree)
hooks:
  before_create: null
  after_create:  null
  before_run:    null
  after_run:     null
  before_remove: null
  timeout_ms:    60000

# Transport (see §7.6)
transport:
  default: cli_session               # cli_session | github_bot | hybrid
  phases:                            # only consulted when default = hybrid
    spec:   cli_session
    plan:   cli_session
    code:   cli_session
    review: github_bot

# github_bot transport tuning (only used when transport touches it)
github_bot:
  claude_handle: "claude"            # produces "@claude" mentions
  codex_handle:  "codex"             # produces "@codex"  mentions
  turn_timeout_ms: 600000            # per-turn cap waiting for bot review
  poll_interval_ms: 15000            # used when webhook not configured
  max_parallel_tasks: 2              # separate cap for Actions-minute budget

# Agents (cli_session transport)
agents:
  claude:
    command: ["claude"]              # CLI invocation
    session_mode: "resume"           # "resume" | "stdin"
    role_alias: "Claude"
  codex:
    command: ["codex"]
    session_mode: "resume"
    role_alias: "Codex"

# Logging
logging:
  dir: ".duet/logs"
  retain_days: 30

# Observability (all optional)
http:
  enabled: false
  port: 8090
```

### 12.1 Environment variables

| Var | Purpose |
|-----|---------|
| `DUET_GITHUB_TOKEN` | Overrides `gh auth` token resolution |
| `DUET_LOG_LEVEL` | `debug` / `info` / `warn` / `error` |
| `DUET_CONFIG` | Alternate config file path |
| `DUET_DRY_RUN` | If set, no PRs are opened, no commits pushed, no hooks executed |

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

Event `kind` values: `task_queued`, `task_started`, `worktree_created`,
`session_spawned`, `phase_started`, `turn_request`, `turn_response`,
`pr_opened`, `pr_review_posted`, `pr_merged`, `phase_frozen`, `task_completed`,
`task_failed`, `session_crashed`, `session_resumed`,
`bot_mention_posted`, `bot_review_received`, `bot_timeout`,
`phase_cap_escalation`.

### 13.2 Per-turn transcripts

Each turn's full prompt and response are written to
`<log_dir>/tasks/<task_id>/transcripts/<phase>-<cycle>-<actor>.md` for audit.

### 13.3 Optional HTTP API

Implementations MAY expose:
- `GET /api/v1/tasks` — list tasks with state
- `GET /api/v1/tasks/<id>` — task detail + current phase
- `GET /api/v1/tasks/<id>/events` — stream of events
- `GET /api/v1/healthz`

A web dashboard is permitted but optional.

---

## 14. Security Posture

- The orchestrator runs with the operator's filesystem and GitHub
  privileges. It MUST NOT escalate.
- Worktree paths are validated against the configured root before any agent
  is spawned (path-traversal defense).
- Hook scripts run with a sanitized environment; only documented variables
  are passed through.
- Agent prompts sourced from operator input (`description`) MUST be
  bounded in length (default 50 000 chars) and rendered via a strict
  template — no shell interpolation.
- GitHub tokens are read from environment or `gh auth`; never written to
  worktrees or transcripts. Transcripts MUST redact known credential
  patterns (AWS keys, PEM blocks, generic API key patterns).
- The orchestrator MUST NOT push to protected branches; the parent repo's
  branch protection rules are the operator's responsibility, but the
  orchestrator confines itself to `duet-base/<task_id>` and `duet-phase/<task_id>/*`.
- Agents have full filesystem access *within their worktree*. They have
  whatever GitHub permissions the configured token grants. Operators
  should provision a least-privilege bot account for production use.

---

## 15. CLI Surface (informative)

A reference CLI; implementations MAY differ.

```
duet run --id <task_id> --title "<...>" --description-file <path>
duet status [--id <task_id>]
duet logs --id <task_id> [--phase SPEC|PLAN|CODE|REVIEW] [--follow]
duet abandon --id <task_id>      # graceful: closes PRs, removes worktree
duet prune                        # deletes merged duet-base/* and duet-phase/* branches
duet config validate
```

---

## 16. Conformance

A conformant implementation MUST:

1. Honor §6 worktree invariants (containment, sanitization, cleanup).
2. Implement at least one transport mode from §7.6 (`cli_session`,
   `github_bot`, or both as `hybrid`); when `cli_session` is implemented,
   sessions MUST be exactly two per task and never shared across tasks
   (§7.1–§7.2).
3. Run phases strictly in order SPEC → PLAN → CODE → REVIEW (§8.2).
4. Use GitHub PRs as the convergence substrate; convergence MUST be
   derived from the **split signal model** of §9.3 (Reviewer's PR review
   state + Author's trailer-bearing PR comment), never from prose alone.
5. Parse the structured trailer (§10.1) and apply the convergence,
   tie-breaker, and pathological-disagreement rules (§10.2–§10.5).
6. Emit the structured event log (§13.1).
7. Document its choices for any §17 implementation-defined item.

A conformant implementation MAY:

- Choose any host language.
- Add a queue/ingest source beyond CLI.
- Add an HTTP API or dashboard.
- Add additional hook points so long as the contract above is preserved.

---

## 17. Implementation-Defined

Each port MUST document its choice for the following:

- **Host language and runtime.**
- **Process supervisor strategy** (in-process threads, OS supervisor, etc.).
- **Transport modes supported** (`cli_session`, `github_bot`, `hybrid`) and
  the default.
- **Session interaction mode** (`stdin` vs `resume`) per agent — applies
  only when `cli_session` is supported.
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
- **Whether worktrees are removed on success only, or always.**

---

## 18. Open Questions

These are design decisions deferred until first implementation; treat them
as RFC anchors.

1. **CODE phase implementer choice.** Hard-coded default vs. agents
   negotiate during PLAN. Currently: hard-coded default Codex, overridable
   in PLAN. Is the override mechanism worth the complexity?
2. **Phase-freeze summary length.** 1500 words is a guess; should depend on
   artifact size or agent context window.
3. **Single CODE PR vs. multi-commit incremental review.** v1 specifies a
   single CODE PR; large changes might need progressive reviews.
4. **Reviewer-driven amendments.** Today the Author owns the artifact. Should
   the Reviewer be allowed to push direct edits during code phase
   (Reviewer-as-pair)? Probably yes, but needs role-permission rules.
5. **Cross-phase memory pruning.** When the agent CLI doesn't support
   compaction, what's the orchestrator's fallback for very long tasks?
6. **Operator-in-the-loop.** Should there be a CLI flag for "pause on every
   phase freeze" so the human can sanity-check before next phase begins?
7. **Failure replay.** If a task fails mid-phase, should the operator be
   able to resume from a specific cycle, or is restart-from-phase-boundary
   sufficient?

---

## 19. Versioning

This spec is versioned via `Version:` at the top. Backward-incompatible
changes increment the major version. A conformant implementation declares
the spec version it targets in its `--version` output.

---

## 20. License

This specification is released under the same license as the parent
repository.
