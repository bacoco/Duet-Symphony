defmodule SymphonyElixir.Duet.AwaitingOperator do
  @moduledoc """
  Pure state machine for the `awaiting_operator` task state.

  Enumerates the spec-defined reasons that can pause a task and the legal
  operator decisions per reason. Translates a `(reason, decision)` pair
  into the canonical orchestrator action so the future orchestrator wiring
  has a single source of truth for these gates.

  This module is pure: no I/O, no event emission. Callers (the future
  orchestrator slice) are responsible for emitting events and applying
  the action's side effects.

  ## Reasons

  Each reason corresponds to a distinct pause condition in the spec:

  * `:pause_on_freeze` (§8.3) — when `duet.pause_on_freeze: true` and a
    phase has just frozen.
  * `:code_pr_conflict` (§8.3.1) — CODE PR not mergeable into
    `duet-base/<task_id>` at REVIEW freeze.
  * `:human_checkpoint` (§8.6) — blocking human gate at end of phase.
  * `:verification_timeout` (§8.7) — verification gate timed out with
    `on_timeout: block`.
  * `:superpower_artifact_invalid` (§8.5) — SuperPower template checks
    still failing in `enforce` mode at the cycle cap.
  * `:phase_cap_escalation` (§10.4.2) — CODE phase cap reached with the
    default `escalate` policy.
  * `:state_divergence` (§11.1) — event log conflicts with GitHub or
    branch state.

  ## Decision-to-action mapping

  See `apply_decision/3` for the per-row mapping. `:fail` always fails
  the task with a reason that depends on the original awaiting_operator
  reason. `:continue` resumes the prior flow (freeze for boundary
  reasons, the in-flight phase for `:state_divergence`).
  """

  @type reason ::
          :pause_on_freeze
          | :code_pr_conflict
          | :human_checkpoint
          | :verification_timeout
          | :superpower_artifact_invalid
          | :phase_cap_escalation
          | :state_divergence

  @type decision ::
          :continue
          | :approve
          | :request_changes
          | :approve_author
          | :approve_reviewer
          | :disable_enforcement
          | :fail

  @type freeze_mode ::
          :consensus
          | :forced
          | :degraded
          | :operator_override_author
          | :operator_override_reviewer

  @type action ::
          :resume_phase
          | :continue_freeze
          | {:return_to_phase, String.t()}
          | {:freeze_with_mode, freeze_mode()}
          | {:fail, String.t()}
          | {:disable_enforcement_and_continue}

  @type apply_opts :: [phase: String.t()]

  @reasons [
    :pause_on_freeze,
    :code_pr_conflict,
    :human_checkpoint,
    :verification_timeout,
    :superpower_artifact_invalid,
    :phase_cap_escalation,
    :state_divergence
  ]

  @decisions_by_reason %{
    pause_on_freeze: [:continue, :fail],
    code_pr_conflict: [:continue, :fail],
    human_checkpoint: [:approve, :request_changes, :fail],
    verification_timeout: [:continue, :fail],
    superpower_artifact_invalid: [:continue, :disable_enforcement, :fail],
    phase_cap_escalation: [:approve_author, :approve_reviewer, :fail],
    state_divergence: [:continue, :fail]
  }

  @doc """
  Returns the canonical list of awaiting_operator reasons in spec order.
  """
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  Returns the list of legal decisions for the given reason. Returns
  `{:error, :unknown_reason}` if the reason is not recognized.
  """
  @spec valid_decisions(reason()) :: [decision()] | {:error, :unknown_reason}
  def valid_decisions(reason) do
    case Map.fetch(@decisions_by_reason, reason) do
      {:ok, decisions} -> decisions
      :error -> {:error, :unknown_reason}
    end
  end

  @doc """
  Returns `true` iff `decision` is a legal operator response for `reason`.
  Unknown reasons return `false`.
  """
  @spec valid?(reason(), decision()) :: boolean()
  def valid?(reason, decision) do
    case Map.fetch(@decisions_by_reason, reason) do
      {:ok, decisions} -> decision in decisions
      :error -> false
    end
  end

  @doc """
  Translates a (reason, decision) pair into the canonical orchestrator action.

  Some reasons (notably `:human_checkpoint`) require the current phase string
  to determine where `:request_changes` returns. Pass `phase: "<phase>"` in
  `opts` for those cases. Per spec §8.6, `:request_changes` on REVIEW returns
  to CODE; for any other phase it returns to that phase.

  Returns `{:error, :invalid_decision}` when the decision is not legal for
  the reason (including unknown reasons); `{:error, :missing_phase}` when a
  decision needs the phase context but it is not supplied.
  """
  @spec apply_decision(reason(), decision(), apply_opts()) :: action() | {:error, atom()}
  def apply_decision(reason, decision, opts \\ []) do
    if valid?(reason, decision) do
      do_apply(reason, decision, opts)
    else
      {:error, :invalid_decision}
    end
  end

  defp do_apply(:pause_on_freeze, :continue, _opts), do: :continue_freeze
  defp do_apply(:pause_on_freeze, :fail, _opts), do: {:fail, "operator_paused"}

  defp do_apply(:code_pr_conflict, :continue, _opts), do: :continue_freeze
  defp do_apply(:code_pr_conflict, :fail, _opts), do: {:fail, "code_pr_conflict"}

  defp do_apply(:human_checkpoint, :approve, _opts), do: :continue_freeze

  defp do_apply(:human_checkpoint, :request_changes, opts) do
    case Keyword.fetch(opts, :phase) do
      {:ok, "REVIEW"} -> {:return_to_phase, "CODE"}
      {:ok, phase} when is_binary(phase) -> {:return_to_phase, phase}
      _ -> {:error, :missing_phase}
    end
  end

  defp do_apply(:human_checkpoint, :fail, _opts), do: {:fail, "human_rejected"}

  defp do_apply(:verification_timeout, :continue, _opts), do: :continue_freeze
  defp do_apply(:verification_timeout, :fail, _opts), do: {:fail, "verification_timeout"}

  defp do_apply(:superpower_artifact_invalid, :continue, _opts), do: :continue_freeze
  defp do_apply(:superpower_artifact_invalid, :disable_enforcement, _opts), do: {:disable_enforcement_and_continue}
  defp do_apply(:superpower_artifact_invalid, :fail, _opts), do: {:fail, "superpower_artifact_invalid"}

  defp do_apply(:phase_cap_escalation, :approve_author, _opts), do: {:freeze_with_mode, :operator_override_author}
  defp do_apply(:phase_cap_escalation, :approve_reviewer, _opts), do: {:freeze_with_mode, :operator_override_reviewer}
  defp do_apply(:phase_cap_escalation, :fail, _opts), do: {:fail, "code_phase_unresolved"}

  defp do_apply(:state_divergence, :continue, _opts), do: :resume_phase
  defp do_apply(:state_divergence, :fail, _opts), do: {:fail, "state_divergence"}
end
