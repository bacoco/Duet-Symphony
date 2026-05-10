defmodule SymphonyElixir.Duet.ConvergenceOrchestrator do
  @moduledoc """
  Pure phase-cycle decision helper combining convergence, cap, and
  pathological-disagreement rules.

  This is deliberately I/O-free. It does not write events, freeze branches,
  notify operators, or mutate task state. The future PairRunner phase driver
  feeds it the current split-signals plus phase history and then performs the
  returned action.

  Decision order matches spec §10:

  1. If `Duet.Convergence.evaluate/1` converges, freeze the phase normally.
  2. If §10.5 pathological disagreement is detected, fail the task.
  3. If §10.3 cycle cap is reached, apply §10.4 tie-breaker policy.
  4. Otherwise continue to the next cycle with the non-convergence reason.
  """

  alias SymphonyElixir.Duet.{Convergence, CycleCap, PathologicalDisagreement}

  @type decision ::
          {:freeze, :converged | :forced | :operator_override_author | :operator_override_reviewer, String.t()}
          | {:continue, Convergence.not_converged_reason()}
          | {:awaiting_operator, :phase_cap_escalation}
          | {:fail, :pathological_disagreement, [String.t()]}
          | {:fail, :code_phase_unresolved | :no_reviewer_revision | :no_revision | :unsupported_phase}

  @type opts :: [
          phase: String.t(),
          cycle: non_neg_integer(),
          max_cycles: pos_integer(),
          code_phase_cap_policy: CycleCap.code_policy(),
          signals: Convergence.t(),
          unresolved_history: [[String.t()]],
          revision_history: CycleCap.history()
        ]

  @doc """
  Decides the next phase-loop action for the current cycle.

  Required options:

  * `:phase` — `"SPEC"`, `"PLAN"`, or `"CODE"`.
  * `:cycle` — current completed Author→Reviewer round-trip count.
  * `:signals` — `%Duet.Convergence{}` for the latest split-signals.

  Optional options default to the spec defaults or empty history:

  * `:max_cycles` — defaults to `CycleCap.default_max_cycles/0`.
  * `:code_phase_cap_policy` — defaults to `:escalate`.
  * `:unresolved_history` — defaults to `[]`.
  * `:revision_history` — defaults to `%{reviewer_last_authored: nil, author_last: nil}`.
  """
  @spec decide(opts()) :: decision()
  def decide(opts) when is_list(opts) do
    signals = Keyword.fetch!(opts, :signals)

    case Convergence.evaluate(signals) do
      :converged ->
        {:freeze, :converged, signals.author_tree_hash}

      {:not_converged, reason} ->
        decide_not_converged(reason, opts)
    end
  end

  defp decide_not_converged(reason, opts) do
    unresolved_history = Keyword.get(opts, :unresolved_history, [])

    case PathologicalDisagreement.detect(unresolved_history) do
      {:pathological, unresolved} ->
        {:fail, :pathological_disagreement, unresolved}

      :ok ->
        maybe_apply_cycle_cap(reason, opts)
    end
  end

  defp maybe_apply_cycle_cap(reason, opts) do
    cycle = Keyword.get(opts, :cycle, 0)
    max_cycles = Keyword.get(opts, :max_cycles, CycleCap.default_max_cycles())

    if CycleCap.at_cap?(cycle, max_cycles) do
      apply_tie_breaker(opts)
    else
      {:continue, reason}
    end
  end

  defp apply_tie_breaker(opts) do
    phase = Keyword.fetch!(opts, :phase)
    policy = Keyword.get(opts, :code_phase_cap_policy, :escalate)
    history = Keyword.get(opts, :revision_history, %{reviewer_last_authored: nil, author_last: nil})

    case CycleCap.tie_breaker(phase, policy, history) do
      {:freeze_with_mode, mode, revision_sha} -> {:freeze, mode, revision_sha}
      :escalate -> {:awaiting_operator, :phase_cap_escalation}
      {:fail, reason} -> {:fail, reason}
    end
  end
end
