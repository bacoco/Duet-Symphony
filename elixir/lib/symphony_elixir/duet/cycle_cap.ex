defmodule SymphonyElixir.Duet.CycleCap do
  @moduledoc """
  Cycle counter and tie-breaker policy per spec §10.3 and §10.4.

  ## §10.3 — Cycle cap

  `max_cycles_per_phase` (default **5**). Counted as Author→Reviewer
  round-trips. `at_cap?/2` is a pure predicate over the current cycle
  count and the configured cap; it returns `true` once the cycle count
  reaches or exceeds the cap.

  ## §10.4 — Tie-breaker policy

  When the cap is reached without convergence the orchestrator must
  decide which revision (if any) to freeze. Spec §10.4 splits this
  decision by phase.

  ### §10.4.1 SPEC and PLAN phases

  1. Select the **last revision authored by the Reviewer** — i.e. the
     most recent revision the Reviewer touched, even if to
     `REQUEST_CHANGES`. Rationale: the reviewer's terminal position is
     the more critical one.
  2. If the Reviewer never authored a revision, fall back to the most
     recent Author revision.
  3. Freeze the phase with `mode = forced`.

  Encoded as `{:freeze_with_mode, :forced, revision_sha}`. The
  degenerate case where neither agent authored a revision returns
  `{:fail, :no_reviewer_revision}` so the caller can surface the
  invariant break instead of silently freezing nothing.

  ### §10.4.2 CODE phase

  The CODE phase MUST NOT auto-merge a Reviewer-rejected revision.
  Behaviour is configurable via `duet.code_phase_cap_policy`:

  * `:escalate` (default) — return `:escalate`. The orchestrator
    transitions the task to `awaiting_operator` and emits a
    `phase_cap_escalation` event. The operator then resolves via
    `resolve_operator_override/2`.
  * `:forced` — apply the SPEC/PLAN rule even though it may ship a
    rejected revision. Same encoding as SPEC/PLAN.
  * `:fail` — auto-fail the task with
    `{:fail, :code_phase_unresolved}`; never ships.

  ### Operator override resolution

  `resolve_operator_override/2` encodes the three CLI verbs:

  * `:approve_author` →
    `{:freeze_with_mode, :operator_override_author, author_last}` or
    `{:fail, :no_revision}` if the Author never produced a revision.
  * `:approve_reviewer` →
    `{:freeze_with_mode, :operator_override_reviewer, reviewer_last_authored}`
    or `{:fail, :no_reviewer_revision}` if the Reviewer never authored
    a revision.
  * `:fail` → `{:fail, :code_phase_unresolved}`.
  """

  @default_max_cycles 5
  @phases ~w(SPEC PLAN CODE)

  @type phase :: String.t()
  @type code_policy :: :escalate | :forced | :fail
  @type revision_sha :: String.t()

  @type history :: %{
          reviewer_last_authored: revision_sha() | nil,
          author_last: revision_sha() | nil
        }

  @type tie_breaker_action ::
          {:freeze_with_mode, :forced, revision_sha()}
          | :escalate
          | {:fail, :code_phase_unresolved}
          | {:freeze_with_mode, :operator_override_author, revision_sha()}
          | {:freeze_with_mode, :operator_override_reviewer, revision_sha()}
          | {:fail, :no_reviewer_revision}
          | {:fail, :no_revision}
          | {:fail, :unsupported_phase}

  @doc """
  Returns the spec §10.3 default of **5** Author→Reviewer round-trips
  per phase.
  """
  @spec default_max_cycles() :: pos_integer()
  def default_max_cycles, do: @default_max_cycles

  @doc """
  Returns `true` when the current `cycles` count has reached or exceeded
  `max_cycles`. The comparison is `>=` so that callers who advance the
  counter past the cap (e.g. due to a race) still observe the cap as
  reached.
  """
  @spec at_cap?(non_neg_integer(), pos_integer()) :: boolean()
  def at_cap?(cycles, max_cycles)
      when is_integer(cycles) and cycles >= 0 and is_integer(max_cycles) and max_cycles > 0 do
    cycles >= max_cycles
  end

  @doc """
  Decides the tie-breaker action when the cap is reached without
  convergence.

  * For SPEC and PLAN: returns `{:freeze_with_mode, :forced, revision_sha}`
    where `revision_sha` is the Reviewer's last-authored revision if any,
    otherwise the Author's last revision. Returns
    `{:fail, :no_reviewer_revision}` only if BOTH are nil (degenerate
    case).
  * For CODE with `policy = :escalate`: returns `:escalate`.
  * For CODE with `policy = :forced`: same as SPEC/PLAN.
  * For CODE with `policy = :fail`: returns `{:fail, :code_phase_unresolved}`.
  * For any other phase string: returns `{:fail, :unsupported_phase}`.

  The `code_policy` argument is ignored for non-CODE phases.
  """
  @spec tie_breaker(phase(), code_policy(), history()) :: tie_breaker_action()
  def tie_breaker(phase, _code_policy, history) when phase in ["SPEC", "PLAN"] do
    forced_freeze(history)
  end

  def tie_breaker("CODE", :escalate, _history), do: :escalate

  def tie_breaker("CODE", :forced, history), do: forced_freeze(history)

  def tie_breaker("CODE", :fail, _history), do: {:fail, :code_phase_unresolved}

  def tie_breaker(phase, _code_policy, _history) when phase not in @phases do
    {:fail, :unsupported_phase}
  end

  @doc """
  Resolves an operator override at the CODE phase cap.

  * `:approve_author` →
    `{:freeze_with_mode, :operator_override_author, author_last}` or
    `{:fail, :no_revision}` if `author_last` is `nil`.
  * `:approve_reviewer` →
    `{:freeze_with_mode, :operator_override_reviewer, reviewer_last_authored}`
    or `{:fail, :no_reviewer_revision}` if the Reviewer never authored.
  * `:fail` → `{:fail, :code_phase_unresolved}`.
  """
  @spec resolve_operator_override(:approve_author | :approve_reviewer | :fail, history()) ::
          tie_breaker_action()
  def resolve_operator_override(:approve_author, %{author_last: sha}) when is_binary(sha) do
    {:freeze_with_mode, :operator_override_author, sha}
  end

  def resolve_operator_override(:approve_author, _history), do: {:fail, :no_revision}

  def resolve_operator_override(:approve_reviewer, %{reviewer_last_authored: sha}) when is_binary(sha) do
    {:freeze_with_mode, :operator_override_reviewer, sha}
  end

  def resolve_operator_override(:approve_reviewer, _history), do: {:fail, :no_reviewer_revision}

  def resolve_operator_override(:fail, _history), do: {:fail, :code_phase_unresolved}

  defp forced_freeze(%{reviewer_last_authored: sha}) when is_binary(sha) do
    {:freeze_with_mode, :forced, sha}
  end

  defp forced_freeze(%{author_last: sha}) when is_binary(sha) do
    {:freeze_with_mode, :forced, sha}
  end

  defp forced_freeze(_history), do: {:fail, :no_reviewer_revision}
end
