defmodule SymphonyElixir.DuetPhaseFreezeMessageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PhaseFreezeMessage

  defp spec_freeze do
    %PhaseFreezeMessage{
      task_id: "TASK-1",
      issue_title: "Add auth flow",
      frozen_phase: "SPEC",
      artifact: "SPEC.md",
      cycles: 2,
      mode: "consensus",
      summary: "Auth module exposes login/logout/refresh endpoints.\n",
      next_phase: "PLAN",
      next_role: "author",
      profile_name: "duet_balanced"
    }
  end

  defp code_freeze do
    %PhaseFreezeMessage{
      task_id: "TASK-7",
      issue_title: "Implement billing service",
      frozen_phase: "CODE",
      artifact: "https://github.com/example/repo/pull/42",
      cycles: 5,
      mode: "forced",
      summary: "Adds StripeBilling adapter and idempotent webhook handler.",
      next_phase: "REVIEW",
      next_role: "coder_ack",
      profile_name: "duet_balanced"
    }
  end

  defp review_freeze do
    %PhaseFreezeMessage{
      task_id: "TASK-7",
      issue_title: "Implement billing service",
      frozen_phase: "REVIEW",
      artifact: "https://github.com/example/repo/pull/42",
      cycles: 1,
      mode: "consensus",
      summary: "REVIEW reviewer approved the held-open CODE PR.",
      next_phase: nil,
      next_role: nil,
      profile_name: "duet_balanced"
    }
  end

  test "build/1 renders a SPEC freeze with consensus mode and a PLAN author next role" do
    expected =
      """
      [DUET PHASE FREEZE]
      Task: TASK-1 — Add auth flow
      Frozen phase: SPEC
      Artifact: SPEC.md
      Convergence: cycles=2, mode=consensus

      Summary of frozen artifact:
      Auth module exposes login/logout/refresh endpoints.

      Next phase: PLAN
      Your role next phase: author
      Active routing profile: duet_balanced
      """
      |> String.trim_trailing()

    assert PhaseFreezeMessage.build(spec_freeze()) == expected
  end

  test "build/1 renders a CODE freeze with forced mode and a coder_ack next role" do
    message = PhaseFreezeMessage.build(code_freeze())

    assert message =~ "[DUET PHASE FREEZE]"
    assert message =~ "Task: TASK-7 — Implement billing service"
    assert message =~ "Frozen phase: CODE"
    assert message =~ "Artifact: https://github.com/example/repo/pull/42"
    assert message =~ "Convergence: cycles=5, mode=forced"
    assert message =~ "Summary of frozen artifact:"
    assert message =~ "Adds StripeBilling adapter and idempotent webhook handler."
    assert message =~ "Next phase: REVIEW"
    assert message =~ "Your role next phase: coder_ack"
    assert message =~ "Active routing profile: duet_balanced"
  end

  test "build/1 omits Next phase / Your role lines for terminal REVIEW freezes" do
    message = PhaseFreezeMessage.build(review_freeze())

    assert message =~ "[DUET PHASE FREEZE]"
    assert message =~ "Task: TASK-7 — Implement billing service"
    assert message =~ "Frozen phase: REVIEW"
    assert message =~ "Artifact: https://github.com/example/repo/pull/42"
    assert message =~ "Convergence: cycles=1, mode=consensus"
    assert message =~ "Summary of frozen artifact:"
    assert message =~ "REVIEW reviewer approved the held-open CODE PR."
    assert message =~ "Active routing profile: duet_balanced"
    refute message =~ "Next phase:"
    refute message =~ "Your role next phase:"
  end

  test "build/1 is deterministic for the same context" do
    ctx = spec_freeze()
    assert PhaseFreezeMessage.build(ctx) == PhaseFreezeMessage.build(ctx)
  end

  test "summary_word_target/2 for :spec returns the 300-word floor when artifact is empty" do
    assert PhaseFreezeMessage.summary_word_target(:spec, 0) == 300
  end

  test "summary_word_target/2 for :spec returns the floor when 0.5× is below 300" do
    assert PhaseFreezeMessage.summary_word_target(:spec, 100) == 300
  end

  test "summary_word_target/2 for :spec scales as 0.5× artifact word count above the floor" do
    assert PhaseFreezeMessage.summary_word_target(:spec, 700) == 350
  end

  test "summary_word_target/2 for :spec is capped at 1500 words" do
    assert PhaseFreezeMessage.summary_word_target(:spec, 4000) == 1500
  end

  test "summary_word_target/2 for :plan applies the same heuristic as :spec" do
    assert PhaseFreezeMessage.summary_word_target(:plan, 0) == 300
    assert PhaseFreezeMessage.summary_word_target(:plan, 100) == 300
    assert PhaseFreezeMessage.summary_word_target(:plan, 700) == 350
    assert PhaseFreezeMessage.summary_word_target(:plan, 4000) == 1500
  end

  test "summary_word_target/2 for :code returns the 300-word floor when diff is empty" do
    assert PhaseFreezeMessage.summary_word_target(:code, 0) == 300
  end

  test "summary_word_target/2 for :code returns the floor when 2× diff_lines is below 300" do
    assert PhaseFreezeMessage.summary_word_target(:code, 50) == 300
  end

  test "summary_word_target/2 for :code scales as 2× diff_lines above the floor" do
    assert PhaseFreezeMessage.summary_word_target(:code, 200) == 400
  end

  test "summary_word_target/2 for :code is capped at 3000 words" do
    assert PhaseFreezeMessage.summary_word_target(:code, 2000) == 3000
  end
end
