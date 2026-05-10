defmodule SymphonyElixir.DuetPathologicalDisagreementTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PathologicalDisagreement

  describe "required_repeats/0" do
    test "returns 3 per spec §10.5" do
      assert PathologicalDisagreement.required_repeats() == 3
    end
  end

  describe "detect/1" do
    test "returns :ok for empty history" do
      assert PathologicalDisagreement.detect([]) == :ok
    end

    test "returns :ok for a single cycle" do
      assert PathologicalDisagreement.detect([["x"]]) == :ok
    end

    test "returns :ok for two cycles even when the lists match" do
      assert PathologicalDisagreement.detect([["x"], ["x"]]) == :ok
    end

    test "returns :pathological when 3 cycles share the same single item" do
      history = [["security_concern"], ["security_concern"], ["security_concern"]]

      assert PathologicalDisagreement.detect(history) ==
               {:pathological, ["security_concern"]}
    end

    test "returns :ok when all 3 cycles disagree on different lists" do
      history = [["a"], ["b"], ["c"]]

      assert PathologicalDisagreement.detect(history) == :ok
    end

    test "returns :pathological when the last 3 of 4 cycles match but the first differs" do
      history = [["foo"], ["bar"], ["bar"], ["bar"]]

      assert PathologicalDisagreement.detect(history) == {:pathological, ["bar"]}
    end

    test "returns :ok when the first 3 of 4 cycles match but the most recent differs" do
      history = [["bar"], ["bar"], ["bar"], ["baz"]]

      assert PathologicalDisagreement.detect(history) == :ok
    end

    test "treats casing differences as equivalent (Security vs security)" do
      history = [["Security"], ["security"], ["SECURITY"]]

      assert PathologicalDisagreement.detect(history) == {:pathological, ["security"]}
    end

    test "treats item order as irrelevant (sort during normalization)" do
      history = [["a", "b"], ["b", "a"], ["a", "b"]]

      assert PathologicalDisagreement.detect(history) == {:pathological, ["a", "b"]}
    end

    test "treats whitespace differences as equivalent (trim + collapse)" do
      history = [["  security concern  "], ["security  concern"], ["security concern"]]

      assert PathologicalDisagreement.detect(history) ==
               {:pathological, ["security concern"]}
    end

    test "deduplicates items inside one cycle (uniq)" do
      history = [["x", "x"], ["x"], ["x", "x", "x"]]

      assert PathologicalDisagreement.detect(history) == {:pathological, ["x"]}
    end

    test "drops empty / whitespace-only items before comparison" do
      history = [["x", "   ", ""], ["x"], ["x", ""]]

      assert PathologicalDisagreement.detect(history) == {:pathological, ["x"]}
    end

    test "treats three consecutive empty lists as pathological per literal spec" do
      assert PathologicalDisagreement.detect([[], [], []]) == {:pathological, []}
    end

    test "returns :ok when the differences cannot be normalized away" do
      history = [["security_concern"], ["security_concern"], ["scope_creep"]]

      assert PathologicalDisagreement.detect(history) == :ok
    end
  end

  describe "normalize/1" do
    test "returns an empty list for an empty list" do
      assert PathologicalDisagreement.normalize([]) == []
    end

    test "lowercases items" do
      assert PathologicalDisagreement.normalize(["Security_Concern"]) == ["security_concern"]
    end

    test "trims surrounding whitespace" do
      assert PathologicalDisagreement.normalize(["  x  "]) == ["x"]
    end

    test "collapses inner whitespace to a single space" do
      assert PathologicalDisagreement.normalize(["security    concern"]) == ["security concern"]
    end

    test "drops items that are empty or whitespace-only after trim" do
      assert PathologicalDisagreement.normalize(["", "   ", "x"]) == ["x"]
    end

    test "deduplicates items via uniq" do
      assert PathologicalDisagreement.normalize(["x", "x", "X"]) == ["x"]
    end

    test "sorts items so that order does not matter" do
      assert PathologicalDisagreement.normalize(["b", "a", "c"]) == ["a", "b", "c"]
    end

    test "applies all normalization steps together" do
      input = ["  Security Concern  ", "scope_creep", "SCOPE_CREEP", "security  concern"]

      assert PathologicalDisagreement.normalize(input) == ["scope_creep", "security concern"]
    end
  end
end
