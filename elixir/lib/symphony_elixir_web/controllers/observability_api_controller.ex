defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.Duet.{OperatorResolution, RoutingSelection, TaskState}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec duet_routing(Conn.t(), map()) :: Conn.t()
  def duet_routing(conn, _params) do
    case RoutingSelection.payload(Config.settings!().duet) do
      {:ok, payload} -> json(conn, payload)
      {:error, reason} -> error_response(conn, 422, "invalid_duet_routing", inspect(reason))
    end
  end

  @spec select_duet_routing(Conn.t(), map()) :: Conn.t()
  def select_duet_routing(conn, params) do
    profile_name = Map.get(params, "profile_name") || Map.get(params, "profile")

    case RoutingSelection.select(Config.settings!().duet, profile_name) do
      {:ok, payload} ->
        SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 422, "invalid_routing_profile", inspect(reason))
    end
  end

  @spec duet_task_state(Conn.t(), map()) :: Conn.t()
  def duet_task_state(conn, %{"task_id" => task_id}) do
    case TaskState.recover(task_id, duet_settings()) do
      {:ok, state} ->
        json(conn, task_state_payload(state))

      {:error, reason} ->
        error_response(conn, 404, "task_not_found", inspect(reason))
    end
  end

  @spec duet_resolve_gate(Conn.t(), map()) :: Conn.t()
  def duet_resolve_gate(conn, %{"task_id" => task_id} = params) do
    decision = parse_decision(Map.get(params, "decision"))

    case decision do
      nil ->
        error_response(conn, 422, "invalid_decision", "Missing or invalid decision parameter")

      decision_atom ->
        case OperatorResolution.resolve(task_id, decision_atom) do
          {:ok, result} ->
            SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
            json(conn, %{ok: true, action: result.action, reason: result.reason})

          {:error, :not_awaiting_operator} ->
            error_response(conn, 409, "not_awaiting_operator", "Task is not in an awaiting_operator state")

          {:error, {:illegal_decision, decision, reason}} ->
            error_response(
              conn,
              422,
              "illegal_decision",
              "Decision #{decision} is not legal for reason #{reason}"
            )

          {:error, reason} ->
            error_response(conn, 422, "resolution_failed", inspect(reason))
        end
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp duet_settings do
    Config.settings!().duet
  rescue
    _ -> nil
  end

  @valid_decisions ~w(approve request_changes continue fail approve_author approve_reviewer disable_enforcement)

  defp parse_decision(decision) when decision in @valid_decisions do
    String.to_existing_atom(decision)
  end

  defp parse_decision(_), do: nil

  defp task_state_payload(%TaskState.State{} = state) do
    %{
      task_id: state.task_id,
      status: state.status,
      current_phase: state.current_phase,
      routing_status: state.routing_status,
      awaiting_operator_reason: state.awaiting_operator_reason,
      events_count: state.events_count,
      phases:
        Map.new(state.phases, fn {name, phase} ->
          {name,
           %{
             status: phase.status,
             cycle: phase.cycle,
             actor: phase.actor,
             verdict: phase.verdict,
             pr_number: phase.pr_number,
             tree_hash: phase.tree_hash
           }}
        end)
    }
  end
end
