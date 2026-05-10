defmodule SymphonyElixir.Duet.Metrics do
  @moduledoc """
  Pure derivation of spec §13.5 convergence metrics from a Duet event log.

  This module never reads from disk. Callers feed in a list of events
  (typically the result of `SymphonyElixir.Duet.EventLog.read/1`); the
  module returns shaped per-phase and per-task metric maps.

  ## Per-phase metrics (computed at phase freeze)

  | Metric | Definition |
  |--------|-----------|
  | `cycles_to_converge` | Number of Author→Reviewer round-trips before freeze (highest `cycle` observed in `turn_response` events) |
  | `convergence_mode` | `:natural` (consensus / operator override) / `:forced` (tie-breaker at cap) / `:degraded` / `:unknown` |
  | `confidence_delta` | `abs(author_final_confidence - reviewer_final_confidence)` |
  | `mean_cycle_duration_ms` | Mean wall-clock time per cycle within the phase (timestamp delta / cycles) |
  | `verification_pass_rate` | Ratio of `verification_completed` events with `pass` status; `nil` when none observed |

  ## Per-task aggregate (computed at task completion)

  | Metric | Definition |
  |--------|-----------|
  | `total_cycles` | Sum of `cycles_to_converge` across all observed phases |
  | `convergence_velocity` | `total_phases / total_cycles` (1.0 = single-cycle convergence everywhere) |
  | `escalation_count` | Number of phases with `convergence_mode == :forced` plus phases with any `phase_cap_escalation` event |
  | `degraded_phases` | Count of phases with `convergence_mode == :degraded` |

  ## Mode mapping (spec §8.4 phase-freeze message → §13.5 convergence mode)

  | `phase_frozen` mode field | Mapped `convergence_mode` |
  |---------------------------|---------------------------|
  | `consensus` (or absent)   | `:natural` |
  | `operator_override_*`     | `:natural` |
  | `forced`, `tie_breaker`   | `:forced` |
  | `degraded`                | `:degraded` |
  | (anything else)           | `:unknown` |
  """

  @phases ~w(SPEC PLAN CODE REVIEW)

  @type phase :: String.t()
  @type event :: map()
  @type convergence_mode :: :natural | :forced | :degraded | :unknown

  @type phase_metrics :: %{
          required(:cycles_to_converge) => non_neg_integer(),
          required(:convergence_mode) => convergence_mode(),
          required(:confidence_delta) => float() | nil,
          required(:mean_cycle_duration_ms) => float() | nil,
          optional(:verification_pass_rate) => float() | nil
        }

  @type task_metrics :: %{
          required(:total_cycles) => non_neg_integer(),
          required(:convergence_velocity) => float() | nil,
          required(:escalation_count) => non_neg_integer(),
          required(:degraded_phases) => non_neg_integer(),
          required(:phases) => %{phase() => phase_metrics()}
        }

  @doc """
  Computes per-phase metrics for one phase from the event log.

  Inputs:
  - `events` — full event log for the task (chronological order).
  - `phase` — uppercase phase name (`"SPEC"` / `"PLAN"` / `"CODE"` / `"REVIEW"`).

  Returns a map shaped like `phase_metrics/0`. If the phase has not been
  observed (no `phase_started` event for it), returns `:not_observed`.
  """
  @spec for_phase([event()], phase()) :: phase_metrics() | :not_observed
  def for_phase(events, phase) when is_list(events) and is_binary(phase) do
    if observed?(events, phase) do
      phase_events = Enum.filter(events, &phase_match?(&1, phase))

      %{
        cycles_to_converge: cycles_to_converge(phase_events),
        convergence_mode: convergence_mode(phase_events),
        confidence_delta: confidence_delta(phase_events),
        mean_cycle_duration_ms: mean_cycle_duration_ms(phase_events),
        verification_pass_rate: verification_pass_rate(phase_events)
      }
    else
      :not_observed
    end
  end

  @doc """
  Aggregates per-task metrics across observed phases.

  Returns a `task_metrics/0` map. If no phases have been observed, the
  per-task fields default to zero/`nil` and `phases` is empty.
  """
  @spec for_task([event()]) :: task_metrics()
  def for_task(events) when is_list(events) do
    phases =
      @phases
      |> Enum.map(fn phase -> {phase, for_phase(events, phase)} end)
      |> Enum.reject(fn {_phase, result} -> result == :not_observed end)
      |> Map.new()

    observed_phase_names = Map.keys(phases)
    total_cycles = phases |> Map.values() |> Enum.map(& &1.cycles_to_converge) |> Enum.sum()

    convergence_velocity =
      case total_cycles do
        0 -> nil
        n -> length(observed_phase_names) / n
      end

    escalation_count = count_escalations(events, phases)

    degraded_phases =
      phases
      |> Map.values()
      |> Enum.count(&(&1.convergence_mode == :degraded))

    %{
      total_cycles: total_cycles,
      convergence_velocity: convergence_velocity,
      escalation_count: escalation_count,
      degraded_phases: degraded_phases,
      phases: phases
    }
  end

  @doc """
  Computes the rolling forced_rate over the last N task results.

  `task_results` is a list of `:natural | :forced | :degraded` modes,
  ordered oldest → newest. The function uses the last `window` entries
  (default 20). Returns the ratio of `:forced` entries to the window
  size, or 0.0 if the window is empty.
  """
  @spec forced_rate([convergence_mode()], pos_integer()) :: float()
  def forced_rate(task_results, window \\ 20)
      when is_list(task_results) and is_integer(window) and window > 0 do
    trimmed = Enum.take(task_results, -window)

    case length(trimmed) do
      0 ->
        0.0

      size ->
        forced = Enum.count(trimmed, &(&1 == :forced))
        forced / size
    end
  end

  # --- Phase observation -----------------------------------------------------

  defp observed?(events, phase) do
    Enum.any?(events, fn event ->
      Map.get(event, "kind") == "phase_started" and phase_match?(event, phase)
    end)
  end

  defp phase_match?(event, phase) when is_map(event) do
    Map.get(event, "phase") == phase
  end

  # --- cycles_to_converge ----------------------------------------------------

  defp cycles_to_converge(phase_events) do
    phase_events
    |> Enum.filter(&(Map.get(&1, "kind") == "turn_response"))
    |> Enum.map(&Map.get(&1, "cycle"))
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> 0 end)
  end

  # --- convergence_mode ------------------------------------------------------

  defp convergence_mode(phase_events) do
    case Enum.find(phase_events, &(Map.get(&1, "kind") == "phase_frozen")) do
      nil -> :unknown
      event -> map_mode(extract_mode(event))
    end
  end

  defp extract_mode(event) do
    case Map.get(event, "mode") do
      mode when is_binary(mode) ->
        mode

      _ ->
        case Map.get(event, "extra") do
          %{"mode" => mode} when is_binary(mode) -> mode
          _ -> nil
        end
    end
  end

  defp map_mode(nil), do: :natural
  defp map_mode("consensus"), do: :natural
  defp map_mode("forced"), do: :forced
  defp map_mode("tie_breaker"), do: :forced
  defp map_mode("degraded"), do: :degraded

  defp map_mode(mode) when is_binary(mode) do
    if String.starts_with?(mode, "operator_override"), do: :natural, else: :unknown
  end

  defp map_mode(_other), do: :unknown

  # --- confidence_delta ------------------------------------------------------

  defp confidence_delta(phase_events) do
    last_by_actor =
      phase_events
      |> Enum.filter(&(Map.get(&1, "kind") == "turn_response"))
      |> Enum.reduce(%{}, fn event, acc ->
        actor = Map.get(event, "actor")
        confidence = Map.get(event, "confidence")

        if is_binary(actor) and actor != "" do
          Map.put(acc, actor, confidence)
        else
          acc
        end
      end)

    case Map.values(last_by_actor) do
      [a, b] when is_number(a) and is_number(b) -> abs(a - b) * 1.0
      _ -> nil
    end
  end

  # --- mean_cycle_duration_ms ------------------------------------------------

  defp mean_cycle_duration_ms(phase_events) do
    cycles = cycles_to_converge(phase_events)

    with cycles when cycles > 0 <- cycles,
         {:ok, first_ts} <- parse_ts(phase_events |> List.first() |> ts_of()),
         {:ok, last_ts} <- parse_ts(phase_events |> List.last() |> ts_of()) do
      diff_ms = DateTime.diff(last_ts, first_ts, :millisecond)
      diff_ms / cycles
    else
      _ -> nil
    end
  end

  defp ts_of(nil), do: nil
  defp ts_of(event) when is_map(event), do: Map.get(event, "ts")

  defp parse_ts(nil), do: :error

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> :error
    end
  end

  defp parse_ts(_other), do: :error

  # --- verification_pass_rate ------------------------------------------------

  defp verification_pass_rate(phase_events) do
    verifications = Enum.filter(phase_events, &(Map.get(&1, "kind") == "verification_completed"))

    case verifications do
      [] ->
        nil

      _ ->
        passes = Enum.count(verifications, &(verification_status(&1) == "pass"))
        passes / length(verifications)
    end
  end

  defp verification_status(event) do
    case Map.get(event, "status") do
      status when is_binary(status) ->
        status

      _ ->
        case Map.get(event, "extra") do
          %{"status" => status} when is_binary(status) -> status
          _ -> nil
        end
    end
  end

  # --- escalation_count ------------------------------------------------------

  defp count_escalations(events, phases) do
    forced_phases =
      phases
      |> Enum.filter(fn {_name, m} -> m.convergence_mode == :forced end)
      |> Enum.map(fn {name, _m} -> name end)
      |> MapSet.new()

    cap_escalation_phases =
      events
      |> Enum.filter(&(Map.get(&1, "kind") == "phase_cap_escalation"))
      |> Enum.map(&Map.get(&1, "phase"))
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    forced_phases
    |> MapSet.union(cap_escalation_phases)
    |> MapSet.size()
  end
end
