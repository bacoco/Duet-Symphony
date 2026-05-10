defmodule SymphonyElixir.DuetConvergenceOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{Convergence, ConvergenceOrchestrator}

  describe "decide/1" do
    test "freezes as converged when both split-signals approve the same tree hash" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "tree-1",
        author_verdict: :approve,
        author_tree_hash: "tree-1"
      }

      assert ConvergenceOrchestrator.decide(phase: "SPEC", cycle: 1, signals: signals) ==
               {:freeze, :converged, "tree-1"}
    end

    test "continues with the non-convergence reason before cap" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "tree-1",
        author_verdict: :approve,
        author_tree_hash: "tree-1"
      }

      assert ConvergenceOrchestrator.decide(phase: "SPEC", cycle: 2, max_cycles: 5, signals: signals) ==
               {:continue, :reviewer_not_approved}
    end

    test "fails on pathological disagreement before applying cycle cap" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "tree-3",
        author_verdict: :approve,
        author_tree_hash: "tree-3"
      }

      assert ConvergenceOrchestrator.decide(
               phase: "SPEC",
               cycle: 3,
               max_cycles: 3,
               signals: signals,
               unresolved_history: [
                 ["Rename API"],
                 [" rename   api "],
                 ["RENAME API"]
               ],
               revision_history: %{reviewer_last_authored: "reviewer-tree", author_last: "author-tree"}
             ) == {:fail, :pathological_disagreement, ["rename api"]}
    end

    test "forces SPEC freeze at cap using reviewer revision first" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "tree-5",
        author_verdict: :approve,
        author_tree_hash: "tree-5"
      }

      assert ConvergenceOrchestrator.decide(
               phase: "SPEC",
               cycle: 5,
               max_cycles: 5,
               signals: signals,
               revision_history: %{reviewer_last_authored: "reviewer-tree", author_last: "author-tree"}
             ) == {:freeze, :forced, "reviewer-tree"}
    end

    test "CODE at cap escalates by default" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "tree-code",
        author_verdict: :approve,
        author_tree_hash: "tree-code"
      }

      assert ConvergenceOrchestrator.decide(phase: "CODE", cycle: 5, max_cycles: 5, signals: signals) ==
               {:awaiting_operator, :phase_cap_escalation}
    end

    test "CODE forced policy applies the forced tie breaker" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "tree-code",
        author_verdict: :approve,
        author_tree_hash: "tree-code"
      }

      assert ConvergenceOrchestrator.decide(
               phase: "CODE",
               cycle: 5,
               max_cycles: 5,
               code_phase_cap_policy: :forced,
               signals: signals,
               revision_history: %{reviewer_last_authored: nil, author_last: "author-tree"}
             ) == {:freeze, :forced, "author-tree"}
    end
  end
end
