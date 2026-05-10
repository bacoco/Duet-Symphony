defmodule SymphonyElixir.Duet.VerificationGate do
  @moduledoc """
  Pure data layer for the spec §8.7 verification gate: builds the
  `---DUET-VERIFICATION---` block injected into Reviewer prompts and
  aggregates per-check statuses into the gate's overall status.

  Actual CI execution / GitHub status polling / shell command invocation
  is the orchestrator's job and lives in a future slice.

  ## Block format

  Per spec §8.7 the rendered block looks like:

      ---DUET-VERIFICATION---
      status: pass | fail | partial | timeout
      checks:
        - name: "ci/tests"
          status: pass
          summary: "247 tests passed, 0 failed"
        - name: "ci/lint"
          status: fail
          summary: "3 ESLint errors in src/auth.ts"
      ---END-DUET-VERIFICATION---

  Check names and summaries are JSON-escaped before being embedded in
  the YAML-like block so arbitrary CI output cannot break the structured
  evidence section.
  """

  @start_marker "---DUET-VERIFICATION---"
  @end_marker "---END-DUET-VERIFICATION---"
  @timeout_fallback_name "verification_timeout"
  @timeout_summary "Verification check timed out"

  @phases ~w(spec plan code review)
  @modes ~w(github_checks local_command both)
  @inject_into_values ~w(reviewer both)
  @on_timeout_values ~w(warn block)

  @type status :: :pass | :fail | :partial | :timeout
  @type check :: %{
          required(:name) => String.t(),
          required(:status) => status(),
          optional(:summary) => String.t() | nil
        }
  @type config :: map()

  @doc """
  Aggregates a list of per-check statuses into the gate's overall status.

  Rules:

  - `[]` → `:partial` (no checks yet — neither pass nor fail).
  - all `:timeout` → `:timeout`.
  - any `:timeout` mixed with a completed check → `:partial`.
  - all `:pass` → `:pass`.
  - all `:fail` → `:fail`.
  - mixed `:pass` / `:fail` (no timeout) → `:partial`.
  - any value outside `:pass | :fail | :partial | :timeout` → `:partial`
    (fail-safe; the function is total).
  """
  @spec aggregate_status([status()]) :: status()
  def aggregate_status([]), do: :partial

  def aggregate_status(check_statuses) when is_list(check_statuses) do
    cond do
      not Enum.all?(check_statuses, &valid_status?/1) -> :partial
      Enum.all?(check_statuses, &(&1 == :timeout)) -> :timeout
      :timeout in check_statuses -> :partial
      Enum.all?(check_statuses, &(&1 == :pass)) -> :pass
      Enum.all?(check_statuses, &(&1 == :fail)) -> :fail
      Enum.all?(check_statuses, &(&1 == :partial)) -> :partial
      true -> :partial
    end
  end

  @doc """
  Builds the `---DUET-VERIFICATION---` block per spec §8.7.

  - The first body line is `status: <aggregated>`.
  - Then `checks:` followed by a YAML-style list of per-check entries:
    `  - name: "<name>"`, `    status: <status>`, `    summary: "<summary>"`.
  - Names and summaries are double-quoted; missing or `nil` summaries are
    omitted (no `summary:` line emitted for that check).
  - Statuses are rendered as bare lowercase strings (`pass`, `fail`,
    `partial`, `timeout`).
  - When `checks` is empty, `checks: []` is emitted on a single line.
  - The block ends with `---END-DUET-VERIFICATION---` on its own line.

  Names and summaries are escaped before rendering.
  """
  @spec build_block([check()], status()) :: String.t()
  def build_block(checks, overall_status) when is_list(checks) and is_atom(overall_status) do
    lines =
      [
        @start_marker,
        "status: #{render_status(overall_status)}",
        checks_section(checks),
        @end_marker
      ]
      |> List.flatten()

    Enum.join(lines, "\n")
  end

  @doc """
  Builds a synthetic single-check `:timeout` block for spec §8.7 step 2.

  Use this when the orchestrator times out waiting for the configured
  status check or local command. The returned string is suitable for
  injection into the Reviewer prompt verbatim.

  When `check_name` is the empty string the fallback name
  `"verification_timeout"` is used. The aggregate status is always
  `:timeout`.
  """
  @spec timeout_block(String.t()) :: String.t()
  def timeout_block(check_name) when is_binary(check_name) do
    name =
      case String.trim(check_name) do
        "" -> @timeout_fallback_name
        trimmed -> trimmed
      end

    check = %{name: name, status: :timeout, summary: @timeout_summary}
    build_block([check], :timeout)
  end

  @doc """
  Returns the literal start marker constant.
  """
  @spec start_marker() :: String.t()
  def start_marker, do: @start_marker

  @doc """
  Returns the literal end marker constant.
  """
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @doc """
  Validates the structure of a `verification_gate` config map per spec §8.7
  and §12. Returns `:ok` or `{:error, message}` describing the first
  offending field.
  """
  @spec validate_config(config()) :: :ok | {:error, String.t()}
  def validate_config(config) when is_map(config) do
    normalized = normalize_keys(config)

    [
      &validate_enabled/1,
      &validate_phases/1,
      &validate_mode/1,
      &validate_github_checks/1,
      &validate_local_command/1,
      &validate_inject_into/1,
      &validate_on_timeout/1
    ]
    |> Enum.reduce_while(:ok, fn validator, :ok ->
      case validator.(normalized) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def validate_config(_other), do: {:error, "verification_gate must be a map"}

  defp validate_enabled(map) do
    case Map.fetch(map, "enabled") do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, other} -> {:error, "verification_gate.enabled must be a boolean, got: #{inspect(other)}"}
    end
  end

  defp validate_phases(map) do
    case Map.fetch(map, "phases") do
      :error ->
        :ok

      {:ok, phases} when is_list(phases) ->
        validate_phase_entries(phases)

      {:ok, other} ->
        {:error, "verification_gate.phases must be a list, got: #{inspect(other)}"}
    end
  end

  defp validate_phase_entries(phases) do
    Enum.reduce_while(phases, :ok, fn phase, :ok ->
      case stringify(phase) do
        phase_str when phase_str in @phases ->
          {:cont, :ok}

        _other ->
          {:halt,
           {:error,
            "verification_gate.phases contains unknown phase #{inspect(phase)} " <>
              "(expected one of #{inspect(@phases)})"}}
      end
    end)
  end

  defp validate_mode(map) do
    case Map.fetch(map, "mode") do
      :error ->
        :ok

      {:ok, value} ->
        value_str = stringify(value)

        if value_str in @modes do
          :ok
        else
          {:error, "verification_gate.mode must be one of #{inspect(@modes)}, got: #{inspect(value)}"}
        end
    end
  end

  defp validate_github_checks(map) do
    case Map.fetch(map, "github_checks") do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        normalized = normalize_keys(value)

        with :ok <- validate_required_contexts(normalized) do
          validate_timeout_ms(normalized, "verification_gate.github_checks.timeout_ms")
        end

      {:ok, other} ->
        {:error, "verification_gate.github_checks must be a map, got: #{inspect(other)}"}
    end
  end

  defp validate_required_contexts(map) do
    case Map.fetch(map, "required_contexts") do
      :error ->
        :ok

      {:ok, contexts} when is_list(contexts) ->
        validate_required_context_entries(contexts)

      {:ok, other} ->
        {:error, "verification_gate.github_checks.required_contexts must be a list, got: #{inspect(other)}"}
    end
  end

  defp validate_required_context_entries(contexts) do
    Enum.reduce_while(contexts, :ok, fn ctx, :ok ->
      if is_binary(ctx) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          "verification_gate.github_checks.required_contexts entries must be strings, " <>
            "got: #{inspect(ctx)}"}}
      end
    end)
  end

  defp validate_local_command(map) do
    case Map.fetch(map, "local_command") do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        normalized = normalize_keys(value)

        with :ok <- validate_local_command_run(normalized) do
          validate_timeout_ms(normalized, "verification_gate.local_command.timeout_ms")
        end

      {:ok, other} ->
        {:error, "verification_gate.local_command must be a map, got: #{inspect(other)}"}
    end
  end

  defp validate_local_command_run(map) do
    case Map.fetch(map, "run") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, other} -> {:error, "verification_gate.local_command.run must be a string or null, got: #{inspect(other)}"}
    end
  end

  defp validate_timeout_ms(map, field_label) do
    case Map.fetch(map, "timeout_ms") do
      :error ->
        :ok

      {:ok, value} when is_integer(value) and value > 0 ->
        :ok

      {:ok, other} ->
        {:error, "#{field_label} must be a positive integer, got: #{inspect(other)}"}
    end
  end

  defp validate_inject_into(map) do
    case Map.fetch(map, "inject_into") do
      :error ->
        :ok

      {:ok, value} ->
        value_str = stringify(value)

        if value_str in @inject_into_values do
          :ok
        else
          {:error,
           "verification_gate.inject_into must be one of #{inspect(@inject_into_values)}, " <>
             "got: #{inspect(value)}"}
        end
    end
  end

  defp validate_on_timeout(map) do
    case Map.fetch(map, "on_timeout") do
      :error ->
        :ok

      {:ok, value} ->
        value_str = stringify(value)

        if value_str in @on_timeout_values do
          :ok
        else
          {:error,
           "verification_gate.on_timeout must be one of #{inspect(@on_timeout_values)}, " <>
             "got: #{inspect(value)}"}
        end
    end
  end

  defp stringify(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: value

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_nested(nested)} end)
  end

  defp normalize_keys(value), do: value

  defp normalize_nested(value) when is_map(value), do: normalize_keys(value)
  defp normalize_nested(value), do: value

  defp valid_status?(:pass), do: true
  defp valid_status?(:fail), do: true
  defp valid_status?(:partial), do: true
  defp valid_status?(:timeout), do: true
  defp valid_status?(_other), do: false

  defp render_status(:pass), do: "pass"
  defp render_status(:fail), do: "fail"
  defp render_status(:partial), do: "partial"
  defp render_status(:timeout), do: "timeout"

  defp checks_section([]), do: ["checks: []"]

  defp checks_section(checks) do
    ["checks:" | Enum.flat_map(checks, &render_check/1)]
  end

  defp render_check(check) do
    name = Map.fetch!(check, :name)
    status = Map.fetch!(check, :status)
    summary = Map.get(check, :summary)

    base = [
      "  - name: #{quoted_value(name)}",
      "    status: #{render_status(status)}"
    ]

    case summary do
      nil -> base
      "" -> base
      value when is_binary(value) -> base ++ ["    summary: #{quoted_value(value)}"]
    end
  end

  defp quoted_value(value) when is_binary(value) do
    value
    |> neutralize_markers()
    |> Jason.encode!()
  end

  defp neutralize_markers(value) do
    value
    |> String.replace(@start_marker, "[DUET_VERIFICATION_MARKER_REDACTED]")
    |> String.replace(@end_marker, "[DUET_VERIFICATION_MARKER_REDACTED]")
  end
end
