defmodule SymphonyElixir.Duet.PhasePrompt do
  @moduledoc """
  Builds the Duet pair-loop prompt sent to an Author or Reviewer for a
  given phase + cycle.

  This is the implementation-defined prompt template (§17). The output is
  deterministic given the input context, includes the spec §10.1 trailer
  schema verbatim, exposes the active routing profile so audit/recovery can
  correlate prompts with `agent_routing_selected` events, and surfaces the
  `last 50 lines` position rule from §10.1.2 so agents know where to place
  the trailer.

  No I/O is performed. Callers (e.g. the future Codex pair-loop driver) feed
  the resulting string to an agent runtime, capture the response text, and
  hand it to `SymphonyElixir.Duet.Turn.record_response/6` for parsing and
  event-log persistence.
  """

  @max_description_chars 50_000

  defstruct [
    :task_id,
    :issue_title,
    :issue_description,
    :phase,
    :cycle,
    :max_cycles_per_phase,
    :role,
    :actor,
    :counterpart,
    :profile_name,
    :profile_mode,
    prior_phase_summaries: %{},
    current_artifact: nil,
    reviewer_feedback: nil,
    max_description_chars: @max_description_chars
  ]

  @type role :: :author | :reviewer | :coder_ack | :review_reviewer
  @type phase :: String.t()
  @type prior_summaries :: %{optional(String.t()) => String.t()}

  @type t :: %__MODULE__{
          task_id: String.t(),
          issue_title: String.t(),
          issue_description: String.t(),
          phase: phase(),
          cycle: pos_integer(),
          max_cycles_per_phase: pos_integer(),
          role: role(),
          actor: String.t(),
          counterpart: String.t(),
          profile_name: String.t(),
          profile_mode: String.t(),
          prior_phase_summaries: prior_summaries(),
          current_artifact: String.t() | nil,
          reviewer_feedback: String.t() | nil,
          max_description_chars: pos_integer()
        }

  @phases_in_order ~w(SPEC PLAN CODE REVIEW)

  @spec build(t()) :: String.t()
  def build(%__MODULE__{} = ctx) do
    [
      header(ctx),
      task_section(ctx),
      role_section(ctx),
      prior_summaries_section(ctx),
      current_artifact_section(ctx),
      reviewer_feedback_section(ctx),
      trailer_instruction()
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp header(ctx) do
    "[DUET #{ctx.phase} TURN] task=#{ctx.task_id} cycle=#{ctx.cycle}/#{ctx.max_cycles_per_phase} actor=#{ctx.actor} role=#{role_label(ctx.role)} profile=#{ctx.profile_name} mode=#{ctx.profile_mode}"
  end

  defp task_section(ctx) do
    """
    ## Task
    Title: #{ctx.issue_title}

    Description:
    #{bounded_description(ctx.issue_description, ctx.max_description_chars)}
    """
    |> String.trim_trailing()
  end

  defp bounded_description(nil, max_chars), do: bounded_description("", max_chars)

  defp bounded_description(description, max_chars) do
    trimmed = String.trim_trailing(description)

    if String.length(trimmed) <= max_chars do
      trimmed
    else
      String.slice(trimmed, 0, max_chars) <> "\n\n[truncated to #{max_chars} chars per spec §14]"
    end
  end

  defp role_section(%__MODULE__{role: role, phase: phase, counterpart: counterpart}) do
    """
    ## Your role (#{role_label(role)})
    Phase: #{phase}
    Counterpart: #{counterpart}

    #{role_instruction(role, phase)}
    """
    |> String.trim_trailing()
  end

  defp role_instruction(:author, "SPEC") do
    "Draft `SPEC.md` capturing what needs to be built, the constraints, and the acceptance criteria. " <>
      "Emit APPROVE in the trailer when you believe the draft is complete; your counterpart will respond " <>
      "with APPROVE or REQUEST_CHANGES."
  end

  defp role_instruction(:author, "PLAN") do
    "Draft `PLAN.md` decomposing the frozen SPEC into an implementation plan with concrete steps, files " <>
      "to create or modify, validation commands, and test coverage. Emit APPROVE when the plan is ready; " <>
      "your counterpart will respond with APPROVE or REQUEST_CHANGES."
  end

  defp role_instruction(:author, "CODE") do
    "Implement the source-file changes called for by the frozen PLAN. Push commits to the CODE phase " <>
      "branch. Emit APPROVE in the trailer when you believe the change is ready for the held-open CODE PR; " <>
      "your counterpart will respond with APPROVE or REQUEST_CHANGES."
  end

  defp role_instruction(:reviewer, phase) do
    "Review the latest #{phase} revision. Emit APPROVE if the revision satisfies the phase contract; " <>
      "otherwise REQUEST_CHANGES with a non-empty `unresolved` list naming each blocker."
  end

  defp role_instruction(:coder_ack, "REVIEW") do
    "You authored the CODE revision under review. Acknowledge convergence via the trailer; you cannot " <>
      "submit a GitHub `APPROVE` review on your own PR, so the trailer-comment is your binding signal " <>
      "per spec §9.3."
  end

  defp role_instruction(:review_reviewer, "REVIEW") do
    "Perform a fresh-context independent review of the held-open CODE PR. Do not relitigate decisions " <>
      "captured in the frozen SPEC and PLAN summaries. Emit APPROVE or REQUEST_CHANGES; this is the " <>
      "binding GitHub review per spec §9.3."
  end

  defp role_instruction(_role, _phase) do
    "Respond per the active routing profile and end with the structured trailer."
  end

  defp prior_summaries_section(%__MODULE__{prior_phase_summaries: summaries}) when summaries == %{},
    do: nil

  defp prior_summaries_section(%__MODULE__{prior_phase_summaries: summaries}) do
    body =
      @phases_in_order
      |> Enum.flat_map(fn phase ->
        case Map.get(summaries, phase) do
          nil -> []
          "" -> []
          summary -> ["### Frozen #{phase} summary", String.trim_trailing(summary)]
        end
      end)

    case body do
      [] -> nil
      lines -> Enum.join(["## Prior phase summaries" | lines], "\n\n")
    end
  end

  defp current_artifact_section(%__MODULE__{current_artifact: nil}), do: nil
  defp current_artifact_section(%__MODULE__{current_artifact: ""}), do: nil

  defp current_artifact_section(%__MODULE__{current_artifact: artifact, phase: phase}) do
    """
    ## Current #{phase} revision
    #{String.trim_trailing(artifact)}
    """
    |> String.trim_trailing()
  end

  defp reviewer_feedback_section(%__MODULE__{reviewer_feedback: nil}), do: nil
  defp reviewer_feedback_section(%__MODULE__{reviewer_feedback: ""}), do: nil

  defp reviewer_feedback_section(%__MODULE__{reviewer_feedback: feedback}) do
    """
    ## Reviewer feedback (previous cycle)
    #{String.trim_trailing(feedback)}
    """
    |> String.trim_trailing()
  end

  defp trailer_instruction do
    """
    ## Required trailer
    Your response MUST end with the fenced Duet trailer (spec §10.1). The trailer block MUST appear within
    the last 50 lines of your response; nothing should follow `---END-DUET-TRAILER---` (§10.1.2).

    ---DUET-TRAILER---
    verdict: APPROVE | REQUEST_CHANGES
    confidence: 0.0..1.0
    summary: <one-line summary of position>
    unresolved: [<list of unresolved concerns; empty if APPROVE>]
    ---END-DUET-TRAILER---
    """
    |> String.trim_trailing()
  end

  defp role_label(:author), do: "Author"
  defp role_label(:reviewer), do: "Reviewer"
  defp role_label(:coder_ack), do: "Coder acknowledgement"
  defp role_label(:review_reviewer), do: "REVIEW reviewer"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_other), do: false
end
