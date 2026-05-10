defmodule SymphonyElixir.Duet.PR do
  @moduledoc """
  Pure helpers for spec §9.4 PR titles and bodies.

  The title format `[duet:<task_id>] <phase>: <title>` is mandatory per
  §9.4 so the orchestrator (and human reviewers) can match a PR to its
  Duet task purely from the title. The body is auto-generated and
  includes the operator's task description, the current cycle, and a
  link/path to the task's append-only event log.

  This module is pure and deterministic given its input. It performs no
  validation of `task_id` or `phase` — empty / whitespace-only values
  yield a degraded but well-formed string (e.g. `[duet:] : Title`).
  Validation of those fields belongs to
  `SymphonyElixir.Duet.Branches.validate_task_id/1` and
  `SymphonyElixir.Duet.PhaseTransition.validate_transition/2`; callers
  must run those checks before invoking `title/1` if they want hard
  guarantees about the produced string.

  The phase is rendered as-is (caller decides casing). The canonical
  convention per §13.1 is uppercase (e.g. `SPEC`, `PLAN`, `CODE`,
  `REVIEW`).
  """

  defstruct [
    :task_id,
    :phase,
    :issue_title,
    :issue_description,
    :cycle,
    :event_log_path
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          phase: String.t(),
          issue_title: String.t(),
          issue_description: String.t() | nil,
          cycle: pos_integer(),
          event_log_path: String.t() | nil
        }

  @max_description_chars 50_000

  @spec title(t()) :: String.t()
  def title(%__MODULE__{task_id: task_id, phase: phase, issue_title: issue_title}) do
    "[duet:#{task_id}] #{phase}: #{issue_title}"
  end

  @spec body(t()) :: String.t()
  def body(%__MODULE__{} = ctx) do
    [
      task_section(ctx),
      duet_section(ctx),
      footer()
    ]
    |> Enum.join("\n\n")
    |> String.trim_trailing()
  end

  defp task_section(%__MODULE__{issue_title: issue_title, issue_description: issue_description}) do
    """
    ## Task

    #{issue_title}

    #{description_block(issue_description)}
    """
    |> String.trim_trailing()
  end

  defp description_block(nil), do: "_(no description provided)_"

  defp description_block(description) do
    case String.trim(description) do
      "" -> "_(no description provided)_"
      _trimmed -> bounded_description(description, @max_description_chars)
    end
  end

  defp bounded_description(description, max_chars) do
    trimmed = String.trim_trailing(description)

    if String.length(trimmed) <= max_chars do
      trimmed
    else
      String.slice(trimmed, 0, max_chars) <> "\n\n[truncated to #{max_chars} chars per spec §14]"
    end
  end

  defp duet_section(%__MODULE__{phase: phase, cycle: cycle, event_log_path: event_log_path}) do
    """
    ## Duet pair-loop

    - Phase: #{phase}
    - Cycle: #{cycle}
    - Event log: #{event_log_display(event_log_path)}
    """
    |> String.trim_trailing()
  end

  defp event_log_display(nil), do: "_(unset)_"
  defp event_log_display(path), do: path

  defp footer do
    """
    This PR was opened by Duet-Symphony per spec §9.4. Phase artifacts and
    agent verdicts (---DUET-TRAILER---) live in the PR comments and reviews.
    """
    |> String.trim_trailing()
  end
end
