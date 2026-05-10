defmodule SymphonyElixir.DuetConvergenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Convergence

  describe "from_github_review_state/1" do
    test "maps APPROVED to :approve" do
      assert Convergence.from_github_review_state("APPROVED") == :approve
    end

    test "maps CHANGES_REQUESTED to :request_changes" do
      assert Convergence.from_github_review_state("CHANGES_REQUESTED") == :request_changes
    end

    test "maps COMMENTED to :other" do
      assert Convergence.from_github_review_state("COMMENTED") == :other
    end

    test "maps DISMISSED to :other" do
      assert Convergence.from_github_review_state("DISMISSED") == :other
    end

    test "maps PENDING to :other" do
      assert Convergence.from_github_review_state("PENDING") == :other
    end

    test "is strict about casing and maps lowercase approved to :other" do
      assert Convergence.from_github_review_state("approved") == :other
    end

    test "maps the empty string to :other" do
      assert Convergence.from_github_review_state("") == :other
    end
  end

  describe "evaluate/1" do
    test "returns :converged when both approve on the same tree_hash" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "abc123",
        author_verdict: :approve,
        author_tree_hash: "abc123"
      }

      assert Convergence.evaluate(signals) == :converged
    end

    test "returns :tree_hash_mismatch when both approve on different tree_hashes" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "abc123",
        author_verdict: :approve,
        author_tree_hash: "def456"
      }

      assert Convergence.evaluate(signals) == {:not_converged, :tree_hash_mismatch}
    end

    test "returns :tree_hash_mismatch when both approve but reviewer tree_hash is nil" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: nil,
        author_verdict: :approve,
        author_tree_hash: "abc123"
      }

      assert Convergence.evaluate(signals) == {:not_converged, :tree_hash_mismatch}
    end

    test "returns :tree_hash_mismatch when both approve but author tree_hash is nil" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "abc123",
        author_verdict: :approve,
        author_tree_hash: nil
      }

      assert Convergence.evaluate(signals) == {:not_converged, :tree_hash_mismatch}
    end

    test "returns :tree_hash_mismatch when both approve on an empty tree_hash" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "",
        author_verdict: :approve,
        author_tree_hash: ""
      }

      assert Convergence.evaluate(signals) == {:not_converged, :tree_hash_mismatch}
    end

    test "returns :author_not_approved when reviewer approves but author requests changes" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "abc123",
        author_verdict: :request_changes,
        author_tree_hash: "abc123"
      }

      assert Convergence.evaluate(signals) == {:not_converged, :author_not_approved}
    end

    test "returns :reviewer_not_approved when reviewer requests changes but author approves" do
      signals = %Convergence{
        reviewer_verdict: :request_changes,
        reviewer_tree_hash: "abc123",
        author_verdict: :approve,
        author_tree_hash: "abc123"
      }

      assert Convergence.evaluate(signals) == {:not_converged, :reviewer_not_approved}
    end

    test "returns :missing_reviewer_signal when reviewer verdict is nil regardless of author state" do
      signals = %Convergence{
        reviewer_verdict: nil,
        reviewer_tree_hash: nil,
        author_verdict: :approve,
        author_tree_hash: "abc123"
      }

      assert Convergence.evaluate(signals) == {:not_converged, :missing_reviewer_signal}
    end

    test "returns :missing_reviewer_signal even when author has also not signalled" do
      signals = %Convergence{
        reviewer_verdict: nil,
        reviewer_tree_hash: nil,
        author_verdict: nil,
        author_tree_hash: nil
      }

      assert Convergence.evaluate(signals) == {:not_converged, :missing_reviewer_signal}
    end

    test "returns :missing_author_signal when reviewer approves but author has not signalled" do
      signals = %Convergence{
        reviewer_verdict: :approve,
        reviewer_tree_hash: "abc123",
        author_verdict: nil,
        author_tree_hash: nil
      }

      assert Convergence.evaluate(signals) == {:not_converged, :missing_author_signal}
    end
  end
end
