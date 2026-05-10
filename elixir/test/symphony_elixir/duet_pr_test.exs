defmodule SymphonyElixir.DuetPRTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PR

  defp base_context do
    %PR{
      task_id: "auth-refactor",
      phase: "SPEC",
      issue_title: "Refactor auth",
      issue_description: "Move auth from cookies to JWT with rotation.",
      cycle: 1,
      event_log_path: "/var/duet/events/auth-refactor.log"
    }
  end

  defp build(overrides), do: struct(base_context(), overrides)

  describe "title/1" do
    test "renders the canonical [duet:<task>] <phase>: <title> format for SPEC" do
      assert PR.title(base_context()) == "[duet:auth-refactor] SPEC: Refactor auth"
    end

    test "works with PLAN" do
      ctx = build(phase: "PLAN", issue_title: "Plan refactor")
      assert PR.title(ctx) == "[duet:auth-refactor] PLAN: Plan refactor"
    end

    test "works with CODE" do
      ctx = build(phase: "CODE", issue_title: "Implement JWT auth")
      assert PR.title(ctx) == "[duet:auth-refactor] CODE: Implement JWT auth"
    end

    test "works with REVIEW" do
      ctx = build(phase: "REVIEW", issue_title: "Review JWT auth PR")
      assert PR.title(ctx) == "[duet:auth-refactor] REVIEW: Review JWT auth PR"
    end

    test "renders phase casing verbatim (caller's responsibility)" do
      ctx = build(phase: "spec")
      assert PR.title(ctx) == "[duet:auth-refactor] spec: Refactor auth"
    end

    test "produces a degraded but well-formed string when task_id is empty" do
      ctx = build(task_id: "")
      assert PR.title(ctx) == "[duet:] SPEC: Refactor auth"
    end
  end

  describe "body/1" do
    test "canonical case includes both H2 sections, title, description, phase, cycle, and event log" do
      body = PR.body(base_context())

      assert body =~ "## Task"
      assert body =~ "## Duet pair-loop"
      assert body =~ "Refactor auth"
      assert body =~ "Move auth from cookies to JWT with rotation."
      assert body =~ "- Phase: SPEC"
      assert body =~ "- Cycle: 1"
      assert body =~ "- Event log: /var/duet/events/auth-refactor.log"
    end

    test "renders nil issue_description with the placeholder marker" do
      body = PR.body(build(issue_description: nil))

      assert body =~ "_(no description provided)_"
      refute body =~ "Move auth from cookies to JWT"
    end

    test "renders empty issue_description with the placeholder marker" do
      body = PR.body(build(issue_description: ""))

      assert body =~ "_(no description provided)_"
    end

    test "renders whitespace-only issue_description with the placeholder marker" do
      body = PR.body(build(issue_description: "   \n  "))

      assert body =~ "_(no description provided)_"
    end

    test "renders nil event_log_path as the unset marker" do
      body = PR.body(build(event_log_path: nil))

      assert body =~ "- Event log: _(unset)_"
    end

    test "short descriptions are rendered verbatim with no truncation marker" do
      body = PR.body(build(issue_description: "A short, perfectly fine description."))

      assert body =~ "A short, perfectly fine description."
      refute body =~ "[truncated to"
    end

    test "truncates description longer than 50_000 chars with the spec §14 marker" do
      oversize = String.duplicate("a", 50_001)
      body = PR.body(build(issue_description: oversize))

      assert body =~ "[truncated to 50000 chars per spec §14]"
      # The truncated body should not contain a 50_001-char run of "a".
      refute body =~ String.duplicate("a", 50_001)
      # But it should contain a 50_000-char run.
      assert body =~ String.duplicate("a", 50_000)
    end

    test "description exactly at the 50_000 char bound is kept verbatim" do
      at_bound = String.duplicate("b", 50_000)
      body = PR.body(build(issue_description: at_bound))

      refute body =~ "[truncated to"
      assert body =~ at_bound
    end

    test "footer mentions spec §9.4" do
      body = PR.body(base_context())

      assert body =~ "spec §9.4"
    end

    test "is deterministic for the same context" do
      ctx = base_context()
      assert PR.body(ctx) == PR.body(ctx)
    end

    test "has no trailing whitespace" do
      body = PR.body(base_context())

      refute String.match?(body, ~r/\s\z/)
    end
  end
end
