defmodule SymphonyElixir.DuetAwaitingOperatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.AwaitingOperator

  describe "reasons/0" do
    test "returns the canonical 7 reasons in spec order" do
      assert AwaitingOperator.reasons() == [
               :pause_on_freeze,
               :code_pr_conflict,
               :human_checkpoint,
               :verification_timeout,
               :superpower_artifact_invalid,
               :phase_cap_escalation,
               :state_divergence
             ]
    end
  end

  describe "valid_decisions/1" do
    test ":pause_on_freeze accepts :continue and :fail" do
      assert AwaitingOperator.valid_decisions(:pause_on_freeze) == [:continue, :fail]
    end

    test ":code_pr_conflict accepts :continue and :fail" do
      assert AwaitingOperator.valid_decisions(:code_pr_conflict) == [:continue, :fail]
    end

    test ":human_checkpoint accepts :approve, :request_changes, :fail" do
      assert AwaitingOperator.valid_decisions(:human_checkpoint) ==
               [:approve, :request_changes, :fail]
    end

    test ":verification_timeout accepts :continue and :fail" do
      assert AwaitingOperator.valid_decisions(:verification_timeout) == [:continue, :fail]
    end

    test ":superpower_artifact_invalid accepts :continue, :disable_enforcement, :fail" do
      assert AwaitingOperator.valid_decisions(:superpower_artifact_invalid) ==
               [:continue, :disable_enforcement, :fail]
    end

    test ":phase_cap_escalation accepts :approve_author, :approve_reviewer, :fail" do
      assert AwaitingOperator.valid_decisions(:phase_cap_escalation) ==
               [:approve_author, :approve_reviewer, :fail]
    end

    test ":state_divergence accepts :continue and :fail" do
      assert AwaitingOperator.valid_decisions(:state_divergence) == [:continue, :fail]
    end

    test "unknown reason returns {:error, :unknown_reason}" do
      assert AwaitingOperator.valid_decisions(:bogus) == {:error, :unknown_reason}
      assert AwaitingOperator.valid_decisions("pause_on_freeze") == {:error, :unknown_reason}
    end
  end

  describe "valid?/2" do
    test "true for every legal pair from the decision table" do
      legal_pairs = [
        {:pause_on_freeze, :continue},
        {:pause_on_freeze, :fail},
        {:code_pr_conflict, :continue},
        {:code_pr_conflict, :fail},
        {:human_checkpoint, :approve},
        {:human_checkpoint, :request_changes},
        {:human_checkpoint, :fail},
        {:verification_timeout, :continue},
        {:verification_timeout, :fail},
        {:superpower_artifact_invalid, :continue},
        {:superpower_artifact_invalid, :disable_enforcement},
        {:superpower_artifact_invalid, :fail},
        {:phase_cap_escalation, :approve_author},
        {:phase_cap_escalation, :approve_reviewer},
        {:phase_cap_escalation, :fail},
        {:state_divergence, :continue},
        {:state_divergence, :fail}
      ]

      for {reason, decision} <- legal_pairs do
        assert AwaitingOperator.valid?(reason, decision),
               "expected #{inspect({reason, decision})} to be legal"
      end
    end

    test "false for illegal cross pairings" do
      refute AwaitingOperator.valid?(:pause_on_freeze, :approve)
      refute AwaitingOperator.valid?(:pause_on_freeze, :request_changes)
      refute AwaitingOperator.valid?(:pause_on_freeze, :approve_author)
      refute AwaitingOperator.valid?(:code_pr_conflict, :disable_enforcement)
      refute AwaitingOperator.valid?(:human_checkpoint, :continue)
      refute AwaitingOperator.valid?(:human_checkpoint, :approve_author)
      refute AwaitingOperator.valid?(:verification_timeout, :approve)
      refute AwaitingOperator.valid?(:superpower_artifact_invalid, :approve)
      refute AwaitingOperator.valid?(:phase_cap_escalation, :continue)
      refute AwaitingOperator.valid?(:phase_cap_escalation, :approve)
      refute AwaitingOperator.valid?(:state_divergence, :approve_author)
    end

    test "false for unknown reasons" do
      refute AwaitingOperator.valid?(:bogus, :continue)
      refute AwaitingOperator.valid?(:bogus, :fail)
      refute AwaitingOperator.valid?("pause_on_freeze", :continue)
    end
  end

  describe "apply_decision/3 — :pause_on_freeze" do
    test ":continue → :continue_freeze" do
      assert AwaitingOperator.apply_decision(:pause_on_freeze, :continue) == :continue_freeze
    end

    test ":fail → {:fail, \"operator_paused\"}" do
      assert AwaitingOperator.apply_decision(:pause_on_freeze, :fail) == {:fail, "operator_paused"}
    end
  end

  describe "apply_decision/3 — :code_pr_conflict" do
    test ":continue → :continue_freeze" do
      assert AwaitingOperator.apply_decision(:code_pr_conflict, :continue) == :continue_freeze
    end

    test ":fail → {:fail, \"code_pr_conflict\"}" do
      assert AwaitingOperator.apply_decision(:code_pr_conflict, :fail) == {:fail, "code_pr_conflict"}
    end
  end

  describe "apply_decision/3 — :human_checkpoint" do
    test ":approve → :continue_freeze (no phase needed)" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :approve) == :continue_freeze
    end

    test ":request_changes with phase: \"REVIEW\" returns to CODE per §8.6" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :request_changes, phase: "REVIEW") ==
               {:return_to_phase, "CODE"}
    end

    test ":request_changes with phase: \"SPEC\" returns to SPEC" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :request_changes, phase: "SPEC") ==
               {:return_to_phase, "SPEC"}
    end

    test ":request_changes with phase: \"PLAN\" returns to PLAN" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :request_changes, phase: "PLAN") ==
               {:return_to_phase, "PLAN"}
    end

    test ":request_changes with phase: \"CODE\" returns to CODE" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :request_changes, phase: "CODE") ==
               {:return_to_phase, "CODE"}
    end

    test ":request_changes without phase → {:error, :missing_phase}" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :request_changes, []) ==
               {:error, :missing_phase}
    end

    test ":fail → {:fail, \"human_rejected\"}" do
      assert AwaitingOperator.apply_decision(:human_checkpoint, :fail) == {:fail, "human_rejected"}
    end
  end

  describe "apply_decision/3 — :verification_timeout" do
    test ":continue → :continue_freeze" do
      assert AwaitingOperator.apply_decision(:verification_timeout, :continue) == :continue_freeze
    end

    test ":fail → {:fail, \"verification_timeout\"}" do
      assert AwaitingOperator.apply_decision(:verification_timeout, :fail) ==
               {:fail, "verification_timeout"}
    end
  end

  describe "apply_decision/3 — :superpower_artifact_invalid" do
    test ":continue → :continue_freeze (operator accepts invalid artifact)" do
      assert AwaitingOperator.apply_decision(:superpower_artifact_invalid, :continue) ==
               :continue_freeze
    end

    test ":disable_enforcement → {:disable_enforcement_and_continue}" do
      assert AwaitingOperator.apply_decision(:superpower_artifact_invalid, :disable_enforcement) ==
               {:disable_enforcement_and_continue}
    end

    test ":fail → {:fail, \"superpower_artifact_invalid\"}" do
      assert AwaitingOperator.apply_decision(:superpower_artifact_invalid, :fail) ==
               {:fail, "superpower_artifact_invalid"}
    end
  end

  describe "apply_decision/3 — :phase_cap_escalation" do
    test ":approve_author → {:freeze_with_mode, :operator_override_author}" do
      assert AwaitingOperator.apply_decision(:phase_cap_escalation, :approve_author) ==
               {:freeze_with_mode, :operator_override_author}
    end

    test ":approve_reviewer → {:freeze_with_mode, :operator_override_reviewer}" do
      assert AwaitingOperator.apply_decision(:phase_cap_escalation, :approve_reviewer) ==
               {:freeze_with_mode, :operator_override_reviewer}
    end

    test ":fail → {:fail, \"code_phase_unresolved\"}" do
      assert AwaitingOperator.apply_decision(:phase_cap_escalation, :fail) ==
               {:fail, "code_phase_unresolved"}
    end

    test ":continue is not legal here → {:error, :invalid_decision}" do
      assert AwaitingOperator.apply_decision(:phase_cap_escalation, :continue) ==
               {:error, :invalid_decision}
    end
  end

  describe "apply_decision/3 — :state_divergence" do
    test ":continue → :resume_phase (mid-phase, NOT a freeze boundary)" do
      assert AwaitingOperator.apply_decision(:state_divergence, :continue) == :resume_phase
    end

    test ":fail → {:fail, \"state_divergence\"}" do
      assert AwaitingOperator.apply_decision(:state_divergence, :fail) ==
               {:fail, "state_divergence"}
    end
  end

  describe "apply_decision/3 — error cases" do
    test "unknown reason → {:error, :invalid_decision}" do
      assert AwaitingOperator.apply_decision(:bogus_reason, :continue) ==
               {:error, :invalid_decision}
    end

    test "illegal decision for a known reason → {:error, :invalid_decision}" do
      assert AwaitingOperator.apply_decision(:pause_on_freeze, :approve) ==
               {:error, :invalid_decision}

      assert AwaitingOperator.apply_decision(:state_divergence, :approve_author) ==
               {:error, :invalid_decision}
    end

    test "phase option is ignored for reasons that do not need it" do
      assert AwaitingOperator.apply_decision(:pause_on_freeze, :continue, phase: "SPEC") ==
               :continue_freeze

      assert AwaitingOperator.apply_decision(:phase_cap_escalation, :approve_author, phase: "CODE") ==
               {:freeze_with_mode, :operator_override_author}
    end
  end
end
