defmodule SymphonyElixir.DuetBranchesTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Branches

  describe "base_prefix/0 and phase_prefix/0" do
    test "expose the spec §6.1 namespace constants" do
      assert Branches.base_prefix() == "duet-base"
      assert Branches.phase_prefix() == "duet-phase"
    end
  end

  describe "valid_task_id?/1" do
    test "accepts task IDs matching the spec §5.2 regex" do
      assert Branches.valid_task_id?("auth-refactor")
      assert Branches.valid_task_id?("abc")
      assert Branches.valid_task_id?("a01")
      assert Branches.valid_task_id?("a-1")
      assert Branches.valid_task_id?("0ab")
    end

    test "accepts the maximum 64-char total length" do
      task_id = "a" <> String.duplicate("b", 63)
      assert String.length(task_id) == 64
      assert Branches.valid_task_id?(task_id)
    end

    test "rejects task IDs shorter than 3 characters" do
      refute Branches.valid_task_id?("")
      refute Branches.valid_task_id?("a")
      refute Branches.valid_task_id?("ab")
    end

    test "rejects task IDs longer than 64 characters" do
      task_id = "a" <> String.duplicate("b", 64)
      assert String.length(task_id) == 65
      refute Branches.valid_task_id?(task_id)
    end

    test "rejects uppercase letters" do
      refute Branches.valid_task_id?("AUTH-Refactor")
      refute Branches.valid_task_id?("Abc")
    end

    test "rejects underscores and other special characters" do
      refute Branches.valid_task_id?("auth_refactor")
      refute Branches.valid_task_id?("auth.refactor")
      refute Branches.valid_task_id?("auth/refactor")
      refute Branches.valid_task_id?("auth refactor")
    end

    test "rejects a leading dash" do
      refute Branches.valid_task_id?("-auth")
      refute Branches.valid_task_id?("-ab")
    end

    test "rejects non-binary inputs without crashing" do
      refute Branches.valid_task_id?(:auth_refactor)
      refute Branches.valid_task_id?(nil)
      refute Branches.valid_task_id?(123)
      refute Branches.valid_task_id?(["abc"])
      refute Branches.valid_task_id?(%{task: "abc"})
    end
  end

  describe "validate_task_id/1" do
    test "returns :ok for a valid task_id" do
      assert Branches.validate_task_id("auth-refactor") == :ok
    end

    test "returns {:error, :invalid_task_id} for invalid binaries" do
      assert Branches.validate_task_id("ab") == {:error, :invalid_task_id}
      assert Branches.validate_task_id("AUTH") == {:error, :invalid_task_id}
      assert Branches.validate_task_id("-auth") == {:error, :invalid_task_id}
    end

    test "returns {:error, :invalid_task_id} for non-binary inputs" do
      assert Branches.validate_task_id(:auth) == {:error, :invalid_task_id}
      assert Branches.validate_task_id(nil) == {:error, :invalid_task_id}
    end
  end

  describe "base_branch/1" do
    test "computes the spec §9.1 long-lived base branch name" do
      assert Branches.base_branch("auth-refactor") == {:ok, "duet-base/auth-refactor"}
      assert Branches.base_branch("abc") == {:ok, "duet-base/abc"}
    end

    test "rejects an invalid task_id" do
      assert Branches.base_branch("ab") == {:error, :invalid_task_id}
      assert Branches.base_branch("AUTH") == {:error, :invalid_task_id}
      assert Branches.base_branch(:not_a_string) == {:error, :invalid_task_id}
    end
  end

  describe "phase_branch/2" do
    test "computes phase branches for atom phases :spec, :plan, :code" do
      assert Branches.phase_branch("auth-refactor", :spec) ==
               {:ok, "duet-phase/auth-refactor/spec"}

      assert Branches.phase_branch("auth-refactor", :plan) ==
               {:ok, "duet-phase/auth-refactor/plan"}

      assert Branches.phase_branch("auth-refactor", :code) ==
               {:ok, "duet-phase/auth-refactor/code"}
    end

    test "computes phase branches for uppercase string phases SPEC, PLAN, CODE" do
      assert Branches.phase_branch("auth-refactor", "SPEC") ==
               {:ok, "duet-phase/auth-refactor/spec"}

      assert Branches.phase_branch("auth-refactor", "PLAN") ==
               {:ok, "duet-phase/auth-refactor/plan"}

      assert Branches.phase_branch("auth-refactor", "CODE") ==
               {:ok, "duet-phase/auth-refactor/code"}
    end

    test "rejects :review and \"REVIEW\" because REVIEW shares the CODE PR (§8.1 / §9.2)" do
      assert Branches.phase_branch("auth-refactor", :review) == {:error, :invalid_phase}
      assert Branches.phase_branch("auth-refactor", "REVIEW") == {:error, :invalid_phase}
    end

    test "rejects unknown phase atoms and strings" do
      assert Branches.phase_branch("auth-refactor", :foo) == {:error, :invalid_phase}
      assert Branches.phase_branch("auth-refactor", "BANANA") == {:error, :invalid_phase}
      assert Branches.phase_branch("auth-refactor", "spec") == {:error, :invalid_phase}
      assert Branches.phase_branch("auth-refactor", nil) == {:error, :invalid_phase}
    end

    test "rejects an invalid task_id even when the phase is valid" do
      assert Branches.phase_branch("ab", :spec) == {:error, :invalid_task_id}
      assert Branches.phase_branch("AUTH", "PLAN") == {:error, :invalid_task_id}
      assert Branches.phase_branch(:not_a_string, :code) == {:error, :invalid_task_id}
    end
  end
end
