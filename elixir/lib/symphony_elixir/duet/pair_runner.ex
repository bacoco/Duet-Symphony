defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Placeholder for the future Claude + Codex pair runner.

  Until the pair loop is implemented, `run/3` returns
  `{:error, :not_implemented}` after running the shared workspace lifecycle.
  This means the workspace can be created and hooks can run before the stub
  fails. The orchestrator dispatch wrapper (`SymphonyElixir.Orchestrator`)
  raises a `RuntimeError` when a runner returns an error tuple, which causes
  the issue task to crash and trigger the standard retry policy. Initial state
  events are idempotent across retries, and the stub records a `task_failed`
  marker before returning `{:error, :not_implemented}`. Do not enable `duet:
  enabled: true` in a production `WORKFLOW.md` until this stub is replaced;
  every claimed task will crash and exhaust the retry policy without producing
  useful work.
  """

  alias SymphonyElixir.Duet.{EventLog, Routing, RoutingSelection}
  alias SymphonyElixir.RunnerRuntime

  @spec run(map(), pid() | nil, keyword()) :: {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_stub/5)
  end

  defp run_pair_stub(_workspace, issue, _update_recipient, _opts, _worker_host) do
    with :ok <- ensure_initial_state_events(issue),
         :ok <- ensure_stub_failure_event(issue) do
      {:error, :not_implemented}
    else
      {:error, reason} -> {:error, {:state_event_failed, reason}}
    end
  end

  defp ensure_initial_state_events(issue) do
    case RoutingSelection.resolve(SymphonyElixir.Config.settings!().duet) do
      {:ok, profile} -> ensure_initial_state_events(issue, profile)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_initial_state_events(issue, profile) do
    with :ok <- append_once(issue, "task_started", task_attrs(issue)),
         :ok <- ensure_routing_selected(issue, Routing.to_event_attrs(profile)) do
      append_once(issue, "phase_started", %{phase: "SPEC", cycle: 1}, %{"phase" => "SPEC", "cycle" => 1})
    end
  end

  defp ensure_stub_failure_event(issue) do
    append_once(issue, "task_failed", %{reason: "not_implemented"}, %{"reason" => "not_implemented"})
  end

  defp append_once(issue, kind, attrs, match_attrs \\ %{}) do
    with {:ok, events} <- EventLog.read(issue) do
      if Enum.any?(events, &event_matches?(&1, kind, match_attrs)) do
        :ok
      else
        append_event(issue, kind, attrs)
      end
    end
  end

  defp ensure_routing_selected(issue, attrs) do
    current = stringify_keys(attrs)

    case EventLog.read(issue) do
      {:ok, events} ->
        events
        |> Enum.find(&(Map.get(&1, "kind") == "agent_routing_selected"))
        |> ensure_routing_event(issue, attrs, current)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_routing_event(nil, issue, attrs, _current) do
    append_event(issue, "agent_routing_selected", attrs)
  end

  defp ensure_routing_event(recorded, _issue, _attrs, current) do
    recorded_routing = Map.take(recorded, ["profile_name", "mode", "degraded", "phases"])

    if recorded_routing == current do
      :ok
    else
      {:error, {:routing_divergence, recorded_routing, current}}
    end
  end

  defp append_event(issue, kind, attrs) do
    case EventLog.append(issue, kind, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_matches?(event, kind, match_attrs) do
    Map.get(event, "kind") == kind and Enum.all?(match_attrs, fn {key, value} -> Map.get(event, key) == value end)
  end

  defp task_attrs(issue) do
    %{
      identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title)
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
