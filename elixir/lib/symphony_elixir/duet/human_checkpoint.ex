defmodule SymphonyElixir.Duet.HumanCheckpoint do
  @moduledoc """
  Pure resolution of spec §8.6 human-checkpoint settings.

  The settings live as a `:map` field on `Config.Schema.Duet.human_checkpoints`
  with keys `"enabled" | "default_mode" | "phases" | "timeout_ms"`. This
  module reads that map (string OR atom keys; both are accepted) and
  decides whether a given phase has a blocking gate, plus translates an
  operator decision atom into the spec-defined freeze flow action.
  """

  @phases ~w(SPEC PLAN CODE REVIEW)
  @valid_modes ~w(blocking advisory)

  @type phase :: String.t()
  @type mode :: :blocking | :advisory | :disabled
  @type decision :: :approve | :request_changes | :fail
  @type duet_settings :: map() | struct()

  @type freeze_action ::
          :continue_freeze
          | {:return_to_phase, phase()}
          | {:fail, :human_rejected}

  @doc """
  Returns `true` if Duet's human-checkpoint feature is globally enabled
  in the supplied settings (ignoring per-phase overrides).
  """
  @spec feature_enabled?(duet_settings()) :: boolean()
  def feature_enabled?(duet_settings) do
    duet_settings
    |> human_checkpoints()
    |> Map.get("enabled", false)
    |> case do
      true -> true
      _other -> false
    end
  end

  @doc """
  Returns the resolved gate `mode/0` for the given phase, taking into
  account the global `enabled` flag, the per-phase boolean (or string),
  and the `default_mode` field.

  - When the feature is globally disabled OR the per-phase value is
    `false`/missing → `:disabled`.
  - When the per-phase value is `true` and `default_mode` is `"blocking"`
    → `:blocking`.
  - When the per-phase value is `true` and `default_mode` is `"advisory"`
    → `:advisory`.
  - When the per-phase value is the string `"blocking"` or `"advisory"`,
    use that explicitly (allows operator override per phase).
  - Unknown / invalid values fall back to `:disabled` (fail-safe).
  """
  @spec mode_for_phase(duet_settings(), phase()) :: mode()
  def mode_for_phase(duet_settings, phase) when is_binary(phase) do
    settings = human_checkpoints(duet_settings)

    if feature_enabled_in_map?(settings) do
      phase_key = String.downcase(phase)

      settings
      |> Map.get("phases", %{})
      |> case do
        phases when is_map(phases) -> Map.get(phases, phase_key)
        _other -> nil
      end
      |> resolve_phase_value(default_mode(settings))
    else
      :disabled
    end
  end

  @doc """
  Returns `true` if the given phase has a blocking human checkpoint gate.
  Convenience wrapper over `mode_for_phase/2 == :blocking`.
  """
  @spec blocking?(duet_settings(), phase()) :: boolean()
  def blocking?(duet_settings, phase) when is_binary(phase) do
    mode_for_phase(duet_settings, phase) == :blocking
  end

  @doc """
  Returns the resolved timeout in milliseconds for human checkpoint waits,
  or `nil` if no timeout is configured (wait indefinitely per spec §8.6).
  """
  @spec timeout_ms(duet_settings()) :: pos_integer() | nil
  def timeout_ms(duet_settings) do
    case duet_settings |> human_checkpoints() |> Map.get("timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  @doc """
  Translates an operator decision into the spec §8.6 freeze-flow action.

  - `:approve` → `:continue_freeze` (apply the §8.3 freeze side effects).
  - `:request_changes` for REVIEW → `{:return_to_phase, "CODE"}` (per
    §8.6 "For REVIEW, this returns to CODE because the final artifact
    being rejected is the CODE PR").
  - `:request_changes` for any other phase → `{:return_to_phase, phase}`.
  - `:fail` → `{:fail, :human_rejected}`.

  An invalid decision atom returns `{:error, :invalid_decision}`.
  """
  @spec resolve_decision(decision(), phase()) ::
          :continue_freeze | {:return_to_phase, phase()} | {:fail, :human_rejected} | {:error, :invalid_decision}
  def resolve_decision(:approve, _phase), do: :continue_freeze
  def resolve_decision(:request_changes, "REVIEW"), do: {:return_to_phase, "CODE"}
  def resolve_decision(:request_changes, phase) when is_binary(phase), do: {:return_to_phase, phase}
  def resolve_decision(:fail, _phase), do: {:fail, :human_rejected}
  def resolve_decision(_other, _phase), do: {:error, :invalid_decision}

  @doc """
  Returns the list of phases for which `mode_for_phase/2` returns `:blocking`,
  filtered by the canonical phase order.
  """
  @spec blocking_phases(duet_settings()) :: [phase()]
  def blocking_phases(duet_settings) do
    Enum.filter(@phases, &blocking?(duet_settings, &1))
  end

  @doc """
  Validates the structure of a `human_checkpoints` config map. Returns
  `:ok` or `{:error, message}` listing the first offending field.
  """
  @spec validate_config(map()) :: :ok | {:error, String.t()}
  def validate_config(human_checkpoints) when is_map(human_checkpoints) do
    normalized = normalize_keys(human_checkpoints)

    with :ok <- validate_enabled(normalized),
         :ok <- validate_default_mode(normalized),
         :ok <- validate_phases(normalized) do
      validate_timeout_ms(normalized)
    end
  end

  def validate_config(_other), do: {:error, "human_checkpoints must be a map"}

  defp human_checkpoints(%{human_checkpoints: human_checkpoints}) when is_map(human_checkpoints) do
    normalize_keys(human_checkpoints)
  end

  defp human_checkpoints(value) when is_map(value) do
    case Map.fetch(value, :human_checkpoints) do
      {:ok, nested} when is_map(nested) -> normalize_keys(nested)
      _ -> normalize_keys(value)
    end
  end

  defp human_checkpoints(_other), do: %{}

  defp feature_enabled_in_map?(%{"enabled" => true}), do: true
  defp feature_enabled_in_map?(_other), do: false

  defp default_mode(settings) do
    case Map.get(settings, "default_mode", "blocking") do
      mode when mode in @valid_modes -> mode
      _other -> "blocking"
    end
  end

  defp resolve_phase_value(true, "blocking"), do: :blocking
  defp resolve_phase_value(true, "advisory"), do: :advisory
  defp resolve_phase_value("blocking", _default), do: :blocking
  defp resolve_phase_value("advisory", _default), do: :advisory
  defp resolve_phase_value(_other, _default), do: :disabled

  defp validate_enabled(map) do
    case Map.fetch(map, "enabled") do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, other} -> {:error, "human_checkpoints.enabled must be a boolean, got: #{inspect(other)}"}
    end
  end

  defp validate_default_mode(map) do
    case Map.fetch(map, "default_mode") do
      :error ->
        :ok

      {:ok, value} when value in @valid_modes ->
        :ok

      {:ok, other} ->
        {:error, "human_checkpoints.default_mode must be one of #{inspect(@valid_modes)}, got: #{inspect(other)}"}
    end
  end

  defp validate_phases(map) do
    case Map.fetch(map, "phases") do
      :error -> :ok
      {:ok, phases} when is_map(phases) -> validate_phases_map(phases)
      {:ok, other} -> {:error, "human_checkpoints.phases must be a map, got: #{inspect(other)}"}
    end
  end

  defp validate_phases_map(phases) do
    Enum.reduce_while(phases, :ok, fn {phase, value}, :ok ->
      case validate_phase_value(value) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, "human_checkpoints.phases.#{phase}: #{msg}"}}
      end
    end)
  end

  defp validate_phase_value(value) when is_boolean(value), do: :ok
  defp validate_phase_value(value) when value in @valid_modes, do: :ok

  defp validate_phase_value(other) do
    {:error, "must be a boolean or one of #{inspect(@valid_modes)}, got: #{inspect(other)}"}
  end

  defp validate_timeout_ms(map) do
    case Map.fetch(map, "timeout_ms") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} when is_integer(value) and value > 0 -> :ok
      {:ok, other} -> {:error, "human_checkpoints.timeout_ms must be a positive integer or nil, got: #{inspect(other)}"}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_nested(nested)} end)
  end

  defp normalize_keys(value), do: value

  defp normalize_nested(value) when is_map(value), do: normalize_keys(value)
  defp normalize_nested(value), do: value
end
