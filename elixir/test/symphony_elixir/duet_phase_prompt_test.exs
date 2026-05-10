defmodule SymphonyElixir.DuetPhasePromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PhasePrompt

  defp base_context do
    %PhasePrompt{
      task_id: "TASK-1",
      issue_title: "Add auth flow",
      issue_description: "Implement JWT auth with refresh tokens.",
      phase: "SPEC",
      cycle: 1,
      max_cycles_per_phase: 5,
      role: :author,
      actor: "claude",
      counterpart: "codex",
      profile_name: "duet_balanced",
      profile_mode: "full_duet"
    }
  end

  defp build(overrides), do: PhasePrompt.build(struct(base_context(), overrides))

  test "SPEC author cycle 1 prompt contains header, task, role, and trailer template" do
    prompt = build([])

    assert prompt =~ "[DUET SPEC TURN] task=TASK-1 cycle=1/5"
    assert prompt =~ "actor=claude role=Author"
    assert prompt =~ "profile=duet_balanced mode=full_duet"
    assert prompt =~ "Add auth flow"
    assert prompt =~ "Implement JWT auth with refresh tokens"
    assert prompt =~ "## Your role (Author)"
    assert prompt =~ "Counterpart: codex"
    assert prompt =~ "Draft `SPEC.md`"
    assert prompt =~ "---DUET-TRAILER---"
    assert prompt =~ "---END-DUET-TRAILER---"
    refute prompt =~ "## Prior phase summaries"
    refute prompt =~ "## Current"
    refute prompt =~ "## Reviewer feedback"
  end

  test "PLAN author with frozen SPEC summary includes the summary section in canonical order" do
    prompt =
      build(
        phase: "PLAN",
        role: :author,
        actor: "codex",
        counterpart: "claude",
        prior_phase_summaries: %{"SPEC" => "Auth module exposes login/logout/refresh endpoints."}
      )

    assert prompt =~ "Draft `PLAN.md`"
    assert prompt =~ "## Prior phase summaries"
    assert prompt =~ "### Frozen SPEC summary"
    assert prompt =~ "Auth module exposes login/logout/refresh endpoints."
  end

  test "Reviewer prompt embeds the current artifact under the phase-titled section" do
    prompt =
      build(
        role: :reviewer,
        actor: "codex",
        counterpart: "claude",
        current_artifact: "# SPEC\nProposed auth flow draft."
      )

    assert prompt =~ "## Your role (Reviewer)"
    assert prompt =~ "Review the latest SPEC revision"
    assert prompt =~ "## Current SPEC revision"
    assert prompt =~ "Proposed auth flow draft"
  end

  test "Author cycle 2 includes reviewer feedback and bumps the cycle counter" do
    prompt =
      build(
        cycle: 2,
        reviewer_feedback: "REQUEST_CHANGES: missing refresh token rotation."
      )

    assert prompt =~ "cycle=2/5"
    assert prompt =~ "## Reviewer feedback (previous cycle)"
    assert prompt =~ "missing refresh token rotation"
  end

  test "REVIEW phase reviewer prompt mentions independence and §9.3" do
    prompt =
      build(
        phase: "REVIEW",
        role: :review_reviewer,
        prior_phase_summaries: %{
          "SPEC" => "Spec frozen.",
          "PLAN" => "Plan frozen.",
          "CODE" => "CODE PR held open at sha def456."
        }
      )

    assert prompt =~ "## Your role (REVIEW reviewer)"
    assert prompt =~ "fresh-context independent review"
    assert prompt =~ "§9.3"
    assert prompt =~ "### Frozen SPEC summary"
    assert prompt =~ "### Frozen PLAN summary"
    assert prompt =~ "### Frozen CODE summary"
  end

  test "REVIEW coder_ack prompt explains the GitHub split-signal constraint" do
    prompt =
      build(
        phase: "REVIEW",
        role: :coder_ack,
        actor: "codex",
        counterpart: "claude"
      )

    assert prompt =~ "## Your role (Coder acknowledgement)"
    assert prompt =~ "you cannot"
    assert prompt =~ "§9.3"
  end

  test "trailer instruction matches spec §10.1 schema and surfaces the §10.1.2 position rule" do
    prompt = build([])

    assert prompt =~ "verdict: APPROVE | REQUEST_CHANGES"
    assert prompt =~ "confidence: 0.0..1.0"
    assert prompt =~ "summary: <one-line summary of position>"
    assert prompt =~ "unresolved: [<list of unresolved concerns; empty if APPROVE>]"
    assert prompt =~ "last 50 lines"
  end

  test "build is deterministic for the same context" do
    ctx = base_context()
    assert PhasePrompt.build(ctx) == PhasePrompt.build(ctx)
  end

  test "empty prior summaries and empty artifact are omitted (not rendered as blank sections)" do
    prompt =
      build(
        prior_phase_summaries: %{"SPEC" => "", "PLAN" => nil},
        current_artifact: "",
        reviewer_feedback: nil
      )

    refute prompt =~ "## Prior phase summaries"
    refute prompt =~ "## Current"
    refute prompt =~ "## Reviewer feedback"
  end

  test "truncates issue_description above the configured bound, appending the spec §14 marker" do
    prompt =
      build(
        issue_description: String.duplicate("a", 200),
        max_description_chars: 50
      )

    assert prompt =~ String.duplicate("a", 50)
    refute prompt =~ String.duplicate("a", 200)
    assert prompt =~ "[truncated to 50 chars per spec §14]"
  end

  test "does not truncate when the description fits within the bound" do
    description = "Implement JWT auth with refresh tokens."

    prompt =
      build(
        issue_description: description,
        max_description_chars: 50_000
      )

    assert prompt =~ description
    refute prompt =~ "[truncated to"
    refute prompt =~ "per spec §14]"
  end
end
