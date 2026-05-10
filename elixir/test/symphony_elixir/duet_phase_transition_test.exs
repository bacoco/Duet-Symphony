defmodule SymphonyElixir.DuetPhaseTransitionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PhaseTransition

  describe "phase_order/0" do
    test "returns the canonical SPEC → PLAN → CODE → REVIEW order from §8.2" do
      assert PhaseTransition.phase_order() == ["SPEC", "PLAN", "CODE", "REVIEW"]
    end
  end

  describe "next_phase/1" do
    test "returns PLAN after SPEC" do
      assert PhaseTransition.next_phase("SPEC") == "PLAN"
    end

    test "returns CODE after PLAN" do
      assert PhaseTransition.next_phase("PLAN") == "CODE"
    end

    test "returns REVIEW after CODE" do
      assert PhaseTransition.next_phase("CODE") == "REVIEW"
    end

    test "returns nil after the terminal phase REVIEW" do
      assert PhaseTransition.next_phase("REVIEW") == nil
    end

    test "returns nil for an unknown phase" do
      assert PhaseTransition.next_phase("FOO") == nil
      assert PhaseTransition.next_phase("spec") == nil
    end
  end

  describe "terminal?/1" do
    test "is true only for REVIEW" do
      assert PhaseTransition.terminal?("REVIEW")
    end

    test "is false for non-terminal phases" do
      refute PhaseTransition.terminal?("SPEC")
      refute PhaseTransition.terminal?("PLAN")
      refute PhaseTransition.terminal?("CODE")
    end

    test "is false for unknown phases" do
      refute PhaseTransition.terminal?("FOO")
      refute PhaseTransition.terminal?("review")
    end
  end

  describe "freeze_merges_phase_pr?/1" do
    test "is true for SPEC (freeze = merge per §8.3)" do
      assert PhaseTransition.freeze_merges_phase_pr?("SPEC")
    end

    test "is true for PLAN (freeze = merge per §8.3)" do
      assert PhaseTransition.freeze_merges_phase_pr?("PLAN")
    end

    test "is false for CODE — the CODE PR is held open for REVIEW" do
      refute PhaseTransition.freeze_merges_phase_pr?("CODE")
    end

    test "is false for REVIEW — REVIEW freeze merges the CODE PR, not a phase PR named REVIEW" do
      refute PhaseTransition.freeze_merges_phase_pr?("REVIEW")
    end

    test "is false for unknown phases" do
      refute PhaseTransition.freeze_merges_phase_pr?("FOO")
    end
  end

  describe "freeze_actions/1" do
    test "SPEC freeze merges the phase PR, deletes the sub-branch, and emits phase-freeze" do
      assert PhaseTransition.freeze_actions("SPEC") == [
               :merge_phase_pr_into_base,
               :delete_phase_sub_branch,
               :emit_phase_freeze_message
             ]
    end

    test "PLAN freeze merges the phase PR, deletes the sub-branch, and emits phase-freeze" do
      assert PhaseTransition.freeze_actions("PLAN") == [
               :merge_phase_pr_into_base,
               :delete_phase_sub_branch,
               :emit_phase_freeze_message
             ]
    end

    test "CODE freeze holds the PR open, records the tree-hash, and emits phase-freeze" do
      assert PhaseTransition.freeze_actions("CODE") == [
               :hold_open_for_review,
               :record_code_tree_hash,
               :emit_phase_freeze_message
             ]
    end

    test "REVIEW freeze marks ready, merges CODE PR, merges base, deletes sub-branch, and emits both messages" do
      assert PhaseTransition.freeze_actions("REVIEW") == [
               :mark_code_pr_ready,
               :merge_code_pr_into_base,
               :merge_base_branch,
               :delete_code_sub_branch,
               :emit_phase_freeze_message,
               :emit_task_completed
             ]
    end

    test "returns [] for an unknown phase" do
      assert PhaseTransition.freeze_actions("FOO") == []
      assert PhaseTransition.freeze_actions("spec") == []
    end
  end

  describe "has_phase_branch?/1" do
    test "is true for SPEC, PLAN, and CODE (per §9.1)" do
      assert PhaseTransition.has_phase_branch?("SPEC")
      assert PhaseTransition.has_phase_branch?("PLAN")
      assert PhaseTransition.has_phase_branch?("CODE")
    end

    test "is false for REVIEW — REVIEW reuses the CODE PR (§9.2)" do
      refute PhaseTransition.has_phase_branch?("REVIEW")
    end

    test "is false for unknown phases" do
      refute PhaseTransition.has_phase_branch?("FOO")
      refute PhaseTransition.has_phase_branch?("spec")
    end
  end

  describe "validate_transition/2" do
    test "allows re-entry into SPEC" do
      assert PhaseTransition.validate_transition("SPEC", "SPEC") == :ok
    end

    test "allows the canonical SPEC → PLAN step" do
      assert PhaseTransition.validate_transition("SPEC", "PLAN") == :ok
    end

    test "allows the canonical PLAN → CODE step" do
      assert PhaseTransition.validate_transition("PLAN", "CODE") == :ok
    end

    test "allows the canonical CODE → REVIEW step" do
      assert PhaseTransition.validate_transition("CODE", "REVIEW") == :ok
    end

    test "allows re-entry into REVIEW (terminal but retryable)" do
      assert PhaseTransition.validate_transition("REVIEW", "REVIEW") == :ok
    end

    test "rejects skipping a phase (SPEC → CODE)" do
      assert PhaseTransition.validate_transition("SPEC", "CODE") == {:error, :invalid_transition}
    end

    test "rejects backward transitions (PLAN → SPEC)" do
      assert PhaseTransition.validate_transition("PLAN", "SPEC") == {:error, :invalid_transition}
    end

    test "rejects any forward transition out of REVIEW (terminal)" do
      assert PhaseTransition.validate_transition("REVIEW", "PLAN") == {:error, :invalid_transition}
      assert PhaseTransition.validate_transition("REVIEW", "SPEC") == {:error, :invalid_transition}
      assert PhaseTransition.validate_transition("REVIEW", "CODE") == {:error, :invalid_transition}
    end

    test "rejects an unknown source phase" do
      assert PhaseTransition.validate_transition("FOO", "SPEC") == {:error, :unknown_phase}
    end

    test "rejects an unknown target phase" do
      assert PhaseTransition.validate_transition("SPEC", "BAR") == {:error, :unknown_phase}
    end

    test "treats lowercase phase strings as unknown" do
      assert PhaseTransition.validate_transition("spec", "plan") == {:error, :unknown_phase}
    end
  end
end
