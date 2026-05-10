defmodule SymphonyElixir.Duet.SuperPower do
  @moduledoc """
  Pure resolver for spec §8.5 SuperPower artifact-mode configuration.

  Operates on the raw `superpower` config map (mirrors the §12 YAML).
  Schema wiring into `Config.Schema.Duet` is intentionally deferred to a
  future slice; this module accepts a map directly so it can be exercised
  today.

  Spec §8.5 is OPTIONAL: the default `enabled: false` means SuperPower
  artifacts are never written. When enabled, this module decides whether
  a given phase has a SuperPower artifact, where to write it, and which
  mode (`:mirror` vs `:enforce`) governs it. The actual file write and
  template validation are the orchestrator's job — `template_check/2`
  here is a stub that always returns `:ok` so the surrounding wiring
  can be exercised before real template rules land.
  """

  @phases ~w(spec plan code review)
  @modes ~w(mirror enforce)
  @default_root "docs/superpowers"

  @phase_subdirs %{
    "spec" => "specs",
    "plan" => "plans",
    "code" => "code",
    "review" => "reviews"
  }

  @type phase :: String.t()
  @type mode :: :mirror | :enforce
  @type config :: map()

  @doc """
  Returns `true` iff `enabled: true` is set in the supplied config.
  Missing or non-boolean values resolve to `false`.
  """
  @spec enabled?(config()) :: boolean()
  def enabled?(superpower_config) when is_map(superpower_config) do
    superpower_config
    |> normalize_keys()
    |> Map.get("enabled", false)
    |> case do
      true -> true
      _other -> false
    end
  end

  def enabled?(_other), do: false

  @doc """
  Returns the resolved mode atom: `:mirror` (default) or `:enforce`.
  Unknown / missing values default to `:mirror`. Value comparison is
  case-insensitive (`"MIRROR"`, `"Enforce"` are accepted).
  """
  @spec mode(config()) :: mode()
  def mode(superpower_config) when is_map(superpower_config) do
    superpower_config
    |> normalize_keys()
    |> Map.get("mode")
    |> normalize_mode_value()
  end

  def mode(_other), do: :mirror

  @doc """
  Returns the resolved root directory; defaults to `"docs/superpowers"`.
  Whitespace is trimmed; empty strings fall back to the default.
  """
  @spec root(config()) :: String.t()
  def root(superpower_config) when is_map(superpower_config) do
    superpower_config
    |> normalize_keys()
    |> Map.get("root")
    |> normalize_root_value()
  end

  def root(_other), do: @default_root

  @doc """
  Returns `true` iff:
  - `enabled?/1` is true,
  - the per-phase setting is present and truthy for that phase, and
  - the phase is one of `["SPEC", "PLAN", "CODE", "REVIEW"]`.

  Phase comparison is case-insensitive (input is uppercased event-style;
  config keys are lowercase per §12).
  """
  @spec phase_enabled?(config(), phase()) :: boolean()
  def phase_enabled?(superpower_config, phase) when is_map(superpower_config) and is_binary(phase) do
    phase_key = String.downcase(phase)

    if enabled?(superpower_config) and phase_key in @phases do
      superpower_config
      |> normalize_keys()
      |> Map.get("phases", %{})
      |> case do
        phases when is_map(phases) -> Map.get(phases, phase_key)
        _other -> nil
      end
      |> case do
        true -> true
        _other -> false
      end
    else
      false
    end
  end

  def phase_enabled?(_config, _phase), do: false

  @doc """
  Computes the artifact path for a (phase, task_id) under the configured
  root. The path follows the §8.5 convention:

  - SPEC → `<root>/specs/<task_id>.md`
  - PLAN → `<root>/plans/<task_id>.md`
  - REVIEW → `<root>/reviews/<task_id>.md`
  - CODE → `<root>/code/<task_id>.md` (per §8.5 phases map; defaults are
    SPEC/PLAN/REVIEW = true and CODE = false but the path is still
    well-defined if an operator opts in).

  Task IDs are sanitized with the same regex as `Duet.EventLog.safe_task_id/1`.
  Returns `{:ok, path}` or `{:error, :invalid_phase}` for unknown phases.
  """
  @spec artifact_path(config(), phase(), String.t()) :: {:ok, Path.t()} | {:error, :invalid_phase}
  def artifact_path(superpower_config, phase, task_id)
      when is_map(superpower_config) and is_binary(phase) and is_binary(task_id) do
    phase_key = String.downcase(phase)

    case Map.fetch(@phase_subdirs, phase_key) do
      {:ok, subdir} ->
        root_dir = root(superpower_config)
        safe_id = safe_task_id(task_id)
        {:ok, Path.join([root_dir, subdir, "#{safe_id}.md"])}

      :error ->
        {:error, :invalid_phase}
    end
  end

  def artifact_path(_config, _phase, _task_id), do: {:error, :invalid_phase}

  @doc """
  V1 stub for template validation. Always returns `:ok`. The real check
  hooks into a configured template registry in a follow-up slice.
  """
  @spec template_check(String.t(), phase()) :: :ok | {:error, term()}
  def template_check(_artifact_text, _phase), do: :ok

  @doc """
  Validates the structure of a `superpower` config map. Returns `:ok` or
  `{:error, message}` describing the first offending field.
  """
  @spec validate_config(map()) :: :ok | {:error, String.t()}
  def validate_config(superpower_config) when is_map(superpower_config) do
    normalized = normalize_keys(superpower_config)

    with :ok <- validate_enabled(normalized),
         :ok <- validate_mode(normalized),
         :ok <- validate_root(normalized),
         :ok <- validate_phases(normalized) do
      validate_require_plan_checkboxes(normalized)
    end
  end

  def validate_config(_other), do: {:error, "superpower must be a map"}

  defp normalize_mode_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "mirror" -> :mirror
      "enforce" -> :enforce
      _other -> :mirror
    end
  end

  defp normalize_mode_value(value) when is_atom(value) and not is_nil(value) do
    value
    |> Atom.to_string()
    |> normalize_mode_value()
  end

  defp normalize_mode_value(_other), do: :mirror

  defp normalize_root_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_root
      trimmed -> trimmed
    end
  end

  defp normalize_root_value(_other), do: @default_root

  defp safe_task_id(task_id) do
    String.replace(task_id, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp validate_enabled(map) do
    case Map.fetch(map, "enabled") do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, other} -> {:error, "superpower.enabled must be a boolean, got: #{inspect(other)}"}
    end
  end

  defp validate_mode(map) do
    case Map.fetch(map, "mode") do
      :error ->
        :ok

      {:ok, value} when value in @modes ->
        :ok

      {:ok, other} ->
        {:error, "superpower.mode must be one of #{inspect(@modes)}, got: #{inspect(other)}"}
    end
  end

  defp validate_root(map) do
    case Map.fetch(map, "root") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, "superpower.root must be a non-empty string, got: #{inspect(value)}"}
        else
          :ok
        end

      {:ok, other} ->
        {:error, "superpower.root must be a non-empty string, got: #{inspect(other)}"}
    end
  end

  defp validate_phases(map) do
    case Map.fetch(map, "phases") do
      :error -> :ok
      {:ok, phases} when is_map(phases) -> validate_phases_map(phases)
      {:ok, other} -> {:error, "superpower.phases must be a map, got: #{inspect(other)}"}
    end
  end

  defp validate_phases_map(phases) do
    Enum.reduce_while(phases, :ok, fn {phase, value}, :ok ->
      cond do
        phase not in @phases ->
          {:halt, {:error, "superpower.phases declares unknown phase #{inspect(phase)} (expected one of #{inspect(@phases)})"}}

        not is_boolean(value) ->
          {:halt, {:error, "superpower.phases.#{phase} must be a boolean, got: #{inspect(value)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_require_plan_checkboxes(map) do
    case Map.fetch(map, "require_plan_checkboxes") do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, other} -> {:error, "superpower.require_plan_checkboxes must be a boolean, got: #{inspect(other)}"}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_nested(nested)} end)
  end

  defp normalize_keys(value), do: value

  defp normalize_nested(value) when is_map(value), do: normalize_keys(value)
  defp normalize_nested(value), do: value
end
