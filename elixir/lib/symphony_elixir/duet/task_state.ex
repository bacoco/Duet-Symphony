defmodule SymphonyElixir.Duet.TaskState do
  @moduledoc """
  Reconstructs Duet task state from the append-only event log.
  """

  alias SymphonyElixir.Duet.{EventLog, Routing}

  defmodule Phase do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            status: String.t(),
            cycle: integer() | nil,
            actor: String.t() | nil,
            verdict: String.t() | nil,
            pr_number: integer() | nil,
            tree_hash: String.t() | nil
          }

    defstruct [:name, :cycle, :actor, :verdict, :pr_number, :tree_hash, status: "unknown"]
  end

  defmodule State do
    @moduledoc false

    @type routing_status :: String.t()

    @type t :: %__MODULE__{
            task_id: String.t(),
            status: String.t(),
            current_phase: String.t() | nil,
            routing: map() | nil,
            routing_status: routing_status(),
            phases: %{String.t() => Phase.t()},
            events_count: non_neg_integer(),
            last_event: map() | nil
          }

    defstruct [
      :task_id,
      :current_phase,
      :routing,
      :last_event,
      status: "unknown",
      routing_status: "missing",
      phases: %{},
      events_count: 0
    ]
  end

  @type state :: State.t()

  @spec recover(String.t(), map() | struct() | nil) :: {:ok, state()} | {:error, term()}
  def recover(task_id, duet_settings \\ nil) when is_binary(task_id) do
    with {:ok, events} <- EventLog.read(task_id) do
      task_id
      |> build(events)
      |> verify_routing(duet_settings)
    end
  end

  defp build(task_id, events) do
    Enum.reduce(events, %State{task_id: task_id}, &apply_event/2)
  end

  defp apply_event(%{"kind" => "task_queued"} = event, state) do
    state
    |> mark_seen(event)
    |> Map.put(:status, "queued")
  end

  defp apply_event(%{"kind" => "task_started"} = event, state) do
    state
    |> mark_seen(event)
    |> Map.put(:status, "running")
  end

  defp apply_event(%{"kind" => "agent_routing_selected"} = event, state) do
    state
    |> mark_seen(event)
    |> Map.put(:routing, routing_from_event(event))
  end

  defp apply_event(%{"kind" => "phase_started"} = event, state) do
    state
    |> mark_seen(event)
    |> put_phase(event, "running")
  end

  defp apply_event(%{"kind" => kind} = event, state) when kind in ["turn_request", "turn_response"] do
    state
    |> mark_seen(event)
    |> put_phase(event, "running")
  end

  defp apply_event(%{"kind" => "phase_frozen"} = event, state) do
    state
    |> mark_seen(event)
    |> put_phase(event, "frozen")
  end

  defp apply_event(%{"kind" => "task_completed"} = event, state) do
    state
    |> mark_seen(event)
    |> Map.put(:status, "completed")
  end

  defp apply_event(%{"kind" => "task_failed"} = event, state) do
    state
    |> mark_seen(event)
    |> Map.put(:status, "failed")
  end

  defp apply_event(event, state) when is_map(event), do: mark_seen(state, event)

  defp mark_seen(%State{} = state, event) do
    %State{state | events_count: state.events_count + 1, last_event: event}
  end

  defp put_phase(%State{} = state, event, status) do
    case Map.get(event, "phase") do
      phase when is_binary(phase) and phase != "" ->
        existing = Map.get(state.phases, phase, %Phase{name: phase})

        phase_state =
          existing
          |> merge_if_present(:cycle, Map.get(event, "cycle"))
          |> merge_if_present(:actor, Map.get(event, "actor"))
          |> merge_if_present(:verdict, Map.get(event, "verdict"))
          |> merge_if_present(:pr_number, Map.get(event, "pr_number"))
          |> merge_if_present(:tree_hash, Map.get(event, "tree_hash"))
          |> Map.put(:status, status)

        %State{
          state
          | current_phase: phase,
            phases: Map.put(state.phases, phase, phase_state)
        }

      _missing_phase ->
        state
    end
  end

  defp merge_if_present(struct, _key, nil), do: struct
  defp merge_if_present(struct, key, value), do: Map.put(struct, key, value)

  defp verify_routing(%State{routing: nil} = state, _duet_settings), do: {:ok, state}
  defp verify_routing(%State{} = state, nil), do: {:ok, %State{state | routing_status: "recorded"}}

  defp verify_routing(%State{routing: recorded} = state, duet_settings) do
    case Routing.resolve(duet_settings) do
      {:ok, current_profile} ->
        current = Routing.to_event_attrs(current_profile) |> stringify_keys()

        if recorded == current do
          {:ok, %State{state | routing_status: "matched"}}
        else
          {:error, {:routing_divergence, recorded, current}}
        end

      {:error, reason} ->
        {:error, {:routing_resolution_failed, reason}}
    end
  end

  defp routing_from_event(event) do
    %{
      "profile_name" => Map.get(event, "profile_name"),
      "mode" => Map.get(event, "mode"),
      "degraded" => Map.get(event, "degraded"),
      "phases" => Map.get(event, "phases", %{})
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
