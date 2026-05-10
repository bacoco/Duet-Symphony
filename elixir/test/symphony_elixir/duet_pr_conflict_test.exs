defmodule SymphonyElixir.DuetPRConflictTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PRConflict

  describe "evaluate/1 — mergeable" do
    test "returns :mergeable when mergeable: true and mergeable_state: :clean" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :clean}) == :mergeable
    end

    test "returns :mergeable for :behind state when mergeable is true (out of §8.3.1 scope)" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :behind}) == :mergeable
    end

    test "returns :mergeable for :blocked state when mergeable is true" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :blocked}) == :mergeable
    end

    test "returns :mergeable for :unstable state when mergeable is true" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :unstable}) == :mergeable
    end

    test "returns :mergeable for :draft state when mergeable is true (per §9.2.1 separation)" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :draft}) == :mergeable
    end

    test "returns :mergeable for :has_hooks state when mergeable is true" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :has_hooks}) == :mergeable
    end
  end

  describe "evaluate/1 — conflict" do
    test "returns :conflict with paths and base_head when both present" do
      input = %{
        mergeable: false,
        mergeable_state: :dirty,
        conflicting_paths: ["lib/auth.ex"],
        base_head: "abc123"
      }

      assert PRConflict.evaluate(input) ==
               {:conflict, %{paths: ["lib/auth.ex"], base_head: "abc123"}}
    end

    test "returns :conflict with empty paths and nil base_head when neither is provided" do
      assert PRConflict.evaluate(%{mergeable: false, mergeable_state: :dirty}) ==
               {:conflict, %{paths: [], base_head: nil}}
    end

    test "returns :conflict regardless of mergeable_state when mergeable is false" do
      input = %{
        mergeable: false,
        mergeable_state: :blocked,
        conflicting_paths: ["a.ex", "b.ex"],
        base_head: "deadbeef"
      }

      assert PRConflict.evaluate(input) ==
               {:conflict, %{paths: ["a.ex", "b.ex"], base_head: "deadbeef"}}
    end

    test "coerces a non-list conflicting_paths value (nil) to []" do
      input = %{
        mergeable: false,
        mergeable_state: :dirty,
        conflicting_paths: nil,
        base_head: "abc123"
      }

      assert PRConflict.evaluate(input) ==
               {:conflict, %{paths: [], base_head: "abc123"}}
    end
  end

  describe "evaluate/1 — retry_later" do
    test "returns {:retry_later, :unknown} when mergeable is nil and state is :unknown" do
      assert PRConflict.evaluate(%{mergeable: nil, mergeable_state: :unknown}) ==
               {:retry_later, :unknown}
    end

    test "returns {:retry_later, :clean} when mergeable is nil even if state is :clean (mergeable nil dominates)" do
      assert PRConflict.evaluate(%{mergeable: nil, mergeable_state: :clean}) ==
               {:retry_later, :clean}
    end

    test "returns {:retry_later, :unknown} when mergeable is true but state is :unknown" do
      assert PRConflict.evaluate(%{mergeable: true, mergeable_state: :unknown}) ==
               {:retry_later, :unknown}
    end

    test "returns {:retry_later, :unknown} when mergeable is nil and mergeable_state is missing" do
      assert PRConflict.evaluate(%{mergeable: nil}) == {:retry_later, :unknown}
    end

    test "returns {:retry_later, :unknown} when mergeable is true and mergeable_state is missing" do
      assert PRConflict.evaluate(%{mergeable: true}) == {:retry_later, :unknown}
    end

    test "returns {:retry_later, :unknown} when mergeable is false and mergeable_state is missing (default :unknown dominates)" do
      assert PRConflict.evaluate(%{mergeable: false}) == {:retry_later, :unknown}
    end
  end

  describe "event_attrs/3" do
    test "builds the canonical §8.3.1 event payload" do
      assert PRConflict.event_attrs(
               "https://github.com/org/repo/pull/42",
               ["lib/auth.ex", "lib/router.ex"],
               "abc123"
             ) == %{
               pr_permalink: "https://github.com/org/repo/pull/42",
               conflicting_paths: ["lib/auth.ex", "lib/router.ex"],
               base_head: "abc123"
             }
    end

    test "includes nil pr_permalink and nil base_head as keys with nil values" do
      assert PRConflict.event_attrs(nil, ["lib/auth.ex"], nil) == %{
               pr_permalink: nil,
               conflicting_paths: ["lib/auth.ex"],
               base_head: nil
             }
    end

    test "coerces a non-list conflicting_paths (nil) to []" do
      assert PRConflict.event_attrs("https://github.com/org/repo/pull/42", nil, "abc123") == %{
               pr_permalink: "https://github.com/org/repo/pull/42",
               conflicting_paths: [],
               base_head: "abc123"
             }
    end

    test "preserves an empty list of conflicting_paths" do
      assert PRConflict.event_attrs("https://github.com/org/repo/pull/42", [], "abc123") == %{
               pr_permalink: "https://github.com/org/repo/pull/42",
               conflicting_paths: [],
               base_head: "abc123"
             }
    end
  end

  describe "known_states/0" do
    test "returns the documented list of mergeable_state atoms" do
      assert PRConflict.known_states() ==
               [:clean, :dirty, :unstable, :behind, :blocked, :unknown, :draft, :has_hooks]
    end
  end
end
