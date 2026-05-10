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

  ## Caveat: YAML escaping is the caller's responsibility

  Check names and summaries are emitted between double quotes but this
  module does NOT escape internal double quotes, backslashes, or other
  YAML-special characters. Callers passing arbitrary CI output as
  `:summary` MUST sanitize it themselves before invoking `build_block/2`
  or `timeout_block/1`. v1 deliberately avoids depending on a YAML
  library; the Reviewer prompt is read by an LLM and the unescaped
  format is acceptable for that consumer.
  """

  @start_marker "---DUET-VERIFICATION---"
  @end_marker "---END-DUET-VERIFICATION---"
  @timeout_fallback_name "verification_timeout"
  @timeout_summary "Verification check timed out"

  @type status :: :pass | :fail | :partial | :timeout
  @type check :: %{
          required(:name) => String.t(),
          required(:status) => status(),
          optional(:summary) => String.t() | nil
        }

  @doc """
  Aggregates a list of per-check statuses into the gate's overall status.

  Rules:

  - `[]` → `:partial` (no checks yet — neither pass nor fail).
  - any `:timeout` in the list → `:timeout` (timeout dominates because
    spec §8.7 treats it as a distinct state).
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
      :timeout in check_statuses -> :timeout
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

  Caller is responsible for sanitizing names/summaries — see moduledoc.
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
      "  - name: \"#{name}\"",
      "    status: #{render_status(status)}"
    ]

    case summary do
      nil -> base
      "" -> base
      value when is_binary(value) -> base ++ ["    summary: \"#{value}\""]
    end
  end
end
