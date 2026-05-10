defmodule SymphonyElixir.Duet.Turn do
  @moduledoc """
  Records a single agent turn into the Duet event log.

  This module is the bridge between the structured trailer parser
  (`SymphonyElixir.Duet.Trailer`) and the append-only event log
  (`SymphonyElixir.Duet.EventLog`). It does not drive any agent
  runtime; callers (e.g. a future Codex/Claude pair-loop driver)
  are responsible for sending prompts and feeding the resulting
  response text back into `record_response/6`.

  The event kinds emitted match spec §13.1:

  * `turn_request` — emitted by `record_request/5` when a prompt is
    dispatched to an agent.
  * `turn_response` — emitted by `record_response/6` whenever the
    response carries a parseable trailer (verdict, summary,
    unresolved). The `tree_hash` is bound by the caller, never
    trusted from agent input (§10.1.2).
  * `trailer_rejected` — emitted when the trailer is missing,
    malformed, or placed earlier than the last 50 lines of the
    response (§10.1, §10.1.2).
  * `low_confidence_approve` — additional warning event when an
    APPROVE verdict carries `confidence < 0.3` (§10.1.1).

  Semantic issues from §10.1.1 are also returned in the response
  tuple so the caller can re-prompt or escalate without re-reading
  the event log.
  """

  alias SymphonyElixir.Duet.{EventLog, Trailer}
  alias SymphonyElixir.Linear.Issue

  defstruct [:phase, :cycle, :actor, :verdict, :confidence, :summary, :unresolved, :tree_hash]

  @type verdict :: Trailer.verdict()

  @type t :: %__MODULE__{
          phase: String.t(),
          cycle: pos_integer(),
          actor: String.t(),
          verdict: verdict(),
          confidence: float() | nil,
          summary: String.t(),
          unresolved: [String.t()],
          tree_hash: String.t() | nil
        }

  @type record_opts :: [tree_hash: String.t() | nil, pr_number: integer() | nil]

  @type record_response_result ::
          {:ok, t(), [Trailer.issue()]}
          | {:error, :missing | :malformed | :position_invalid | {:event_log_failed, term()}}

  @type record_request_result :: :ok | {:error, term()}

  @spec record_request(String.t() | Issue.t() | map(), String.t(), pos_integer(), String.t(), record_opts()) ::
          record_request_result()
  def record_request(task_or_issue, phase, cycle, actor, opts \\ [])
      when is_binary(phase) and is_integer(cycle) and cycle > 0 and is_binary(actor) do
    case EventLog.append(task_or_issue, "turn_request", request_attrs(phase, cycle, actor, opts)) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec record_response(
          String.t() | Issue.t() | map(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          record_opts()
        ) :: record_response_result()
  def record_response(task_or_issue, phase, cycle, actor, response_text, opts \\ [])
      when is_binary(phase) and is_integer(cycle) and cycle > 0 and is_binary(actor) and is_binary(response_text) do
    case Trailer.parse(response_text) do
      {:ok, trailer, issues} ->
        record_parsed_response(task_or_issue, phase, cycle, actor, trailer, issues, opts)

      {:error, reason} ->
        _ = append_trailer_rejection(task_or_issue, phase, cycle, actor, reason, opts)
        {:error, reason}
    end
  end

  defp record_parsed_response(task_or_issue, phase, cycle, actor, trailer, issues, opts) do
    turn = build_turn(phase, cycle, actor, trailer, opts)

    with {:ok, _event} <- EventLog.append(task_or_issue, "turn_response", response_attrs(turn, opts)),
         :ok <- emit_issue_events(task_or_issue, phase, cycle, actor, issues) do
      {:ok, turn, issues}
    else
      {:error, reason} -> {:error, {:event_log_failed, reason}}
    end
  end

  defp build_turn(phase, cycle, actor, %Trailer{} = trailer, opts) do
    %__MODULE__{
      phase: phase,
      cycle: cycle,
      actor: actor,
      verdict: trailer.verdict,
      confidence: trailer.confidence,
      summary: trailer.summary,
      unresolved: trailer.unresolved,
      tree_hash: Keyword.get(opts, :tree_hash)
    }
  end

  defp request_attrs(phase, cycle, actor, opts) do
    %{
      phase: phase,
      cycle: cycle,
      actor: actor,
      tree_hash: Keyword.get(opts, :tree_hash),
      pr_number: Keyword.get(opts, :pr_number)
    }
  end

  defp response_attrs(%__MODULE__{} = turn, opts) do
    %{
      phase: turn.phase,
      cycle: turn.cycle,
      actor: turn.actor,
      verdict: verdict_to_string(turn.verdict),
      confidence: turn.confidence,
      summary: turn.summary,
      unresolved: turn.unresolved,
      tree_hash: turn.tree_hash,
      pr_number: Keyword.get(opts, :pr_number)
    }
  end

  defp append_trailer_rejection(task_or_issue, phase, cycle, actor, reason, opts) do
    EventLog.append(task_or_issue, "trailer_rejected", %{
      phase: phase,
      cycle: cycle,
      actor: actor,
      reason: Atom.to_string(reason),
      tree_hash: Keyword.get(opts, :tree_hash),
      pr_number: Keyword.get(opts, :pr_number)
    })
  end

  defp emit_issue_events(_task_or_issue, _phase, _cycle, _actor, []), do: :ok

  defp emit_issue_events(task_or_issue, phase, cycle, actor, [issue | rest]) do
    with :ok <- emit_issue_event(task_or_issue, phase, cycle, actor, issue) do
      emit_issue_events(task_or_issue, phase, cycle, actor, rest)
    end
  end

  defp emit_issue_event(task_or_issue, phase, cycle, actor, :low_confidence_approve) do
    case EventLog.append(task_or_issue, "low_confidence_approve", %{
           phase: phase,
           cycle: cycle,
           actor: actor
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_issue_event(_task_or_issue, _phase, _cycle, _actor, :synthesized_no_details), do: :ok

  defp emit_issue_event(_task_or_issue, _phase, _cycle, _actor, {:approve_with_unresolved, _}), do: :ok

  defp verdict_to_string(:approve), do: "APPROVE"
  defp verdict_to_string(:request_changes), do: "REQUEST_CHANGES"
end
