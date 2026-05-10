defmodule SymphonyElixir.Duet.OperatorResolution do
  @moduledoc """
  Resolves operator commands that resume tasks paused in `awaiting_operator` state.

  This module bridges the pure decision logic in `AwaitingOperator` with the
  event-sourced task state in `TaskState` and `EventLog`. It validates that a
  task is actually gated, applies the operator's decision, records the
  appropriate resolution events, and returns the resulting action so the
  caller can re-dispatch the task.
  """

  alias SymphonyElixir.Duet.{AwaitingOperator, EventLog, TaskState}

  @reason_atoms %{
    "pause_on_freeze" => :pause_on_freeze,
    "code_pr_conflict" => :code_pr_conflict,
    "human_checkpoint" => :human_checkpoint,
    "verification_timeout" => :verification_timeout,
    "superpower_artifact_invalid" => :superpower_artifact_invalid,
    "phase_cap_escalation" => :phase_cap_escalation,
    "state_divergence" => :state_divergence
  }

  @doc """
  Resolves an operator decision for a task in `awaiting_operator` state.

  1. Recovers the task state from the event log.
  2. Verifies the task is in `awaiting_operator` status.
  3. Converts the string reason to an atom and delegates to
     `AwaitingOperator.apply_decision/3`.
  4. Records the appropriate resolution event(s).
  5. Returns `{:ok, action_map}` on success or `{:error, term}` on failure.
  """
  @spec resolve(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(task_id, decision, opts \\ []) do
    with {:ok, state} <- TaskState.recover(task_id),
         :ok <- verify_awaiting_operator(state),
         {:ok, reason_atom} <- reason_to_atom(state.awaiting_operator_reason),
         phase_opts <- build_phase_opts(state, opts) do
      case AwaitingOperator.apply_decision(reason_atom, decision, phase_opts) do
        {:error, :invalid_decision} ->
          {:error, {:illegal_decision, decision, reason_atom}}

        {:error, reason} ->
          {:error, reason}

        {:fail, fail_reason} ->
          record_failure(task_id, reason_atom, decision, fail_reason)

        action ->
          record_resolution(task_id, reason_atom, decision, action)
      end
    end
  end

  @doc """
  Returns the current awaiting_operator gate info for a task.

  Returns `{:ok, gate_info}` with reason, phase, and cycle when the task is
  paused, or `{:error, :not_awaiting_operator}` otherwise.
  """
  @spec pending_gates(String.t()) :: {:ok, map()} | {:error, term()}
  def pending_gates(task_id) do
    with {:ok, state} <- TaskState.recover(task_id) do
      if state.status == "awaiting_operator" and is_binary(state.awaiting_operator_reason) do
        phase_info = current_phase_info(state)

        {:ok,
         %{
           reason: state.awaiting_operator_reason,
           phase: phase_info.phase,
           cycle: phase_info.cycle
         }}
      else
        {:error, :not_awaiting_operator}
      end
    end
  end

  @doc """
  Convenience wrapper for resolving human checkpoint gates.

  Records a `"human_checkpoint_resolved"` event that PairRunner's
  `pending_awaiting_operator_reason/1` already recognizes as a
  gate-clearing event.
  """
  @spec resolve_human_checkpoint(String.t(), :approve | :request_changes | :fail) ::
          {:ok, map()} | {:error, term()}
  def resolve_human_checkpoint(task_id, decision)
      when decision in [:approve, :request_changes, :fail] do
    with {:ok, state} <- TaskState.recover(task_id),
         :ok <- verify_awaiting_operator(state),
         :ok <- verify_human_checkpoint(state),
         phase_opts <- build_phase_opts(state, []) do
      case AwaitingOperator.apply_decision(:human_checkpoint, decision, phase_opts) do
        {:error, :invalid_decision} ->
          {:error, {:illegal_decision, decision, :human_checkpoint}}

        {:error, reason} ->
          {:error, reason}

        {:fail, fail_reason} ->
          record_failure(task_id, :human_checkpoint, decision, fail_reason)

        action ->
          record_human_checkpoint_resolution(task_id, decision, action)
      end
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp verify_awaiting_operator(%{status: "awaiting_operator"}), do: :ok
  defp verify_awaiting_operator(_state), do: {:error, :not_awaiting_operator}

  defp verify_human_checkpoint(%{awaiting_operator_reason: "human_checkpoint"}), do: :ok
  defp verify_human_checkpoint(_state), do: {:error, :not_human_checkpoint}

  defp reason_to_atom(reason) when is_binary(reason) do
    case Map.fetch(@reason_atoms, reason) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_reason, reason}}
    end
  end

  defp build_phase_opts(state, opts) do
    phase = Keyword.get(opts, :phase) || state.current_phase
    if is_binary(phase), do: [phase: phase], else: []
  end

  defp current_phase_info(state) do
    phase = state.current_phase

    cycle =
      case Map.get(state.phases, phase) do
        nil -> nil
        phase_state -> phase_state.cycle
      end

    %{phase: phase, cycle: cycle}
  end

  defp record_resolution(task_id, reason_atom, decision, action) do
    action_type = action_type(action)

    case EventLog.append(task_id, "operator_resolution", %{
           reason: Atom.to_string(reason_atom),
           decision: Atom.to_string(decision),
           action: action_type
         }) do
      {:ok, _event} ->
        {:ok, %{action: action_type, reason: Atom.to_string(reason_atom)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_human_checkpoint_resolution(task_id, decision, action) do
    action_type = action_type(action)

    with {:ok, _event} <-
           EventLog.append(task_id, "human_checkpoint_resolved", %{
             decision: Atom.to_string(decision),
             action: action_type
           }),
         {:ok, _event} <-
           EventLog.append(task_id, "operator_resolution", %{
             reason: "human_checkpoint",
             decision: Atom.to_string(decision),
             action: action_type
           }) do
      {:ok, %{action: action_type, reason: "human_checkpoint"}}
    end
  end

  defp record_failure(task_id, reason_atom, decision, fail_reason) do
    with {:ok, _event} <-
           EventLog.append(task_id, "operator_resolution", %{
             reason: Atom.to_string(reason_atom),
             decision: Atom.to_string(decision),
             action: "fail"
           }),
         {:ok, _event} <-
           EventLog.append(task_id, "task_failed", %{
             reason: fail_reason
           }) do
      {:ok, %{action: :fail, reason: fail_reason}}
    end
  end

  defp action_type(:continue_freeze), do: "continue_freeze"
  defp action_type(:resume_phase), do: "resume_phase"
  defp action_type({:return_to_phase, phase}), do: "return_to_phase:#{phase}"
  defp action_type({:freeze_with_mode, mode}), do: "freeze_with_mode:#{mode}"
  defp action_type({:disable_enforcement_and_continue}), do: "disable_enforcement_and_continue"
  defp action_type({:fail, _reason}), do: "fail"
  defp action_type(other), do: inspect(other)
end
