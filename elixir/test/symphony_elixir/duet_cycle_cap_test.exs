defmodule SymphonyElixir.DuetCycleCapTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.CycleCap

  describe "default_max_cycles/0" do
    test "returns spec §10.3 default of 5" do
      assert CycleCap.default_max_cycles() == 5
    end
  end

  describe "at_cap?/2" do
    test "returns false when no cycles have been consumed" do
      refute CycleCap.at_cap?(0, 5)
    end

    test "returns false when one cycle short of the cap" do
      refute CycleCap.at_cap?(4, 5)
    end

    test "returns true at exactly the cap" do
      assert CycleCap.at_cap?(5, 5)
    end

    test "returns true when the counter has advanced past the cap" do
      assert CycleCap.at_cap?(6, 5)
    end
  end

  describe "tie_breaker/3 — SPEC and PLAN phases (§10.4.1)" do
    test "SPEC: prefers the Reviewer's last-authored revision when both are present" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.tie_breaker("SPEC", :escalate, history) ==
               {:freeze_with_mode, :forced, "rev-reviewer"}
    end

    test "PLAN: falls back to the Author's last revision when Reviewer never authored" do
      history = %{reviewer_last_authored: nil, author_last: "rev-author"}

      assert CycleCap.tie_breaker("PLAN", :forced, history) ==
               {:freeze_with_mode, :forced, "rev-author"}
    end

    test "SPEC: returns :no_reviewer_revision when neither agent authored a revision" do
      history = %{reviewer_last_authored: nil, author_last: nil}

      assert CycleCap.tie_breaker("SPEC", :escalate, history) ==
               {:fail, :no_reviewer_revision}
    end

    test "code_policy is ignored for SPEC and PLAN" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      for policy <- [:escalate, :forced, :fail] do
        assert CycleCap.tie_breaker("SPEC", policy, history) ==
                 {:freeze_with_mode, :forced, "rev-reviewer"}

        assert CycleCap.tie_breaker("PLAN", policy, history) ==
                 {:freeze_with_mode, :forced, "rev-reviewer"}
      end
    end
  end

  describe "tie_breaker/3 — CODE phase (§10.4.2)" do
    test "policy :escalate returns :escalate regardless of revision history" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.tie_breaker("CODE", :escalate, history) == :escalate
    end

    test "policy :forced applies the SPEC/PLAN rule with the Reviewer's revision when present" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.tie_breaker("CODE", :forced, history) ==
               {:freeze_with_mode, :forced, "rev-reviewer"}
    end

    test "policy :forced falls back to the Author's revision when Reviewer never authored" do
      history = %{reviewer_last_authored: nil, author_last: "rev-author"}

      assert CycleCap.tie_breaker("CODE", :forced, history) ==
               {:freeze_with_mode, :forced, "rev-author"}
    end

    test "policy :forced surfaces :no_reviewer_revision when both are nil" do
      history = %{reviewer_last_authored: nil, author_last: nil}

      assert CycleCap.tie_breaker("CODE", :forced, history) ==
               {:fail, :no_reviewer_revision}
    end

    test "policy :fail returns :code_phase_unresolved" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.tie_breaker("CODE", :fail, history) ==
               {:fail, :code_phase_unresolved}
    end
  end

  describe "tie_breaker/3 — unsupported phases" do
    test "returns :unsupported_phase for an unknown phase string like \"REVIEW\"" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.tie_breaker("REVIEW", :escalate, history) ==
               {:fail, :unsupported_phase}
    end

    test "returns :unsupported_phase for the empty string" do
      history = %{reviewer_last_authored: nil, author_last: nil}

      assert CycleCap.tie_breaker("", :escalate, history) ==
               {:fail, :unsupported_phase}
    end
  end

  describe "resolve_operator_override/2" do
    test ":approve_author with author_last set returns operator_override_author" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.resolve_operator_override(:approve_author, history) ==
               {:freeze_with_mode, :operator_override_author, "rev-author"}
    end

    test ":approve_author with author_last nil returns :no_revision" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: nil}

      assert CycleCap.resolve_operator_override(:approve_author, history) ==
               {:fail, :no_revision}
    end

    test ":approve_reviewer with reviewer_last_authored set returns operator_override_reviewer" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.resolve_operator_override(:approve_reviewer, history) ==
               {:freeze_with_mode, :operator_override_reviewer, "rev-reviewer"}
    end

    test ":approve_reviewer with reviewer_last_authored nil returns :no_reviewer_revision" do
      history = %{reviewer_last_authored: nil, author_last: "rev-author"}

      assert CycleCap.resolve_operator_override(:approve_reviewer, history) ==
               {:fail, :no_reviewer_revision}
    end

    test ":fail returns :code_phase_unresolved" do
      history = %{reviewer_last_authored: "rev-reviewer", author_last: "rev-author"}

      assert CycleCap.resolve_operator_override(:fail, history) ==
               {:fail, :code_phase_unresolved}
    end
  end
end
