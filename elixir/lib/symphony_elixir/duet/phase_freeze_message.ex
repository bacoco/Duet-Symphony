defmodule SymphonyElixir.Duet.PhaseFreezeMessage do
  @moduledoc """
  Builds the per spec §8.4 phase-freeze message sent to active agent
  runtimes at each phase boundary, plus the adaptive summary word-target
  helper.

  The message is rendered as plain text following the §8.4 schema. It is
  delivered to each agent runtime that is active for the next phase at
  the moment of freeze. Runtimes whose next role is `skipped` do not
  receive a turn request; callers MAY still write an audit-only
  transcript entry, but no agent response is expected.

  This module is pure and deterministic given its input. It does NOT
  generate the artifact summary itself — callers precompute that text
  (using `summary_word_target/2` as guidance) and feed it in via the
  `:summary` field. The orchestrator binds the message to the frozen
  artifact path or PR URL, the convergence mode, and the next-phase
  routing context.
  """

  defstruct [
    :task_id,
    :issue_title,
    :frozen_phase,
    :artifact,
    :cycles,
    :mode,
    :summary,
    :next_phase,
    :next_role,
    :profile_name
  ]

  @type next_role :: String.t() | nil

  @type t :: %__MODULE__{
          task_id: String.t(),
          issue_title: String.t(),
          frozen_phase: String.t(),
          artifact: String.t(),
          cycles: pos_integer(),
          mode: String.t(),
          summary: String.t(),
          next_phase: String.t() | nil,
          next_role: next_role(),
          profile_name: String.t()
        }

  @floor_words 300
  @spec_plan_cap 1500
  @code_cap 3000

  @spec build(t()) :: String.t()
  def build(%__MODULE__{} = ctx) do
    [
      head_block(ctx),
      summary_block(ctx),
      tail_block(ctx)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Computes the recommended summary word target per spec §8.4.

  - For `:spec` or `:plan`: `min(1500, artifact_word_count × 0.5)` clamped to a
    300-word floor.
  - For `:code`: `min(3000, diff_lines × 2)` clamped to the same 300-word floor.
  """
  @spec summary_word_target(:spec | :plan | :code, non_neg_integer()) :: pos_integer()
  def summary_word_target(:spec, artifact_word_count), do: spec_plan_target(artifact_word_count)
  def summary_word_target(:plan, artifact_word_count), do: spec_plan_target(artifact_word_count)

  def summary_word_target(:code, diff_lines)
      when is_integer(diff_lines) and diff_lines >= 0 do
    diff_lines
    |> Kernel.*(2)
    |> min(@code_cap)
    |> max(@floor_words)
  end

  defp spec_plan_target(artifact_word_count)
       when is_integer(artifact_word_count) and artifact_word_count >= 0 do
    artifact_word_count
    |> div(2)
    |> min(@spec_plan_cap)
    |> max(@floor_words)
  end

  defp head_block(ctx) do
    [
      "[DUET PHASE FREEZE]",
      "Task: #{ctx.task_id} — #{ctx.issue_title}",
      "Frozen phase: #{ctx.frozen_phase}",
      "Artifact: #{ctx.artifact}",
      "Convergence: cycles=#{ctx.cycles}, mode=#{ctx.mode}"
    ]
    |> Enum.join("\n")
  end

  defp summary_block(%__MODULE__{summary: summary}) do
    """
    Summary of frozen artifact:
    #{String.trim_trailing(summary)}
    """
    |> String.trim_trailing()
  end

  defp tail_block(%__MODULE__{next_phase: nil} = ctx) do
    "Active routing profile: #{ctx.profile_name}"
  end

  defp tail_block(%__MODULE__{next_phase: next_phase, next_role: next_role} = ctx) do
    [
      "Next phase: #{next_phase}",
      "Your role next phase: #{next_role}",
      "Active routing profile: #{ctx.profile_name}"
    ]
    |> Enum.join("\n")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false
end
