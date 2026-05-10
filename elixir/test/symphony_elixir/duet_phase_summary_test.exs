defmodule SymphonyElixir.DuetPhaseSummaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PhaseSummary

  describe "word_count/1" do
    test "returns 0 for empty string" do
      assert PhaseSummary.word_count("") == 0
    end

    test "returns 0 for whitespace-only input" do
      assert PhaseSummary.word_count("   \n  \t  ") == 0
    end

    test "returns 1 for a single word" do
      assert PhaseSummary.word_count("hello") == 1
    end

    test "counts whitespace-separated tokens including punctuation" do
      assert PhaseSummary.word_count("Hello, world! This is fine.") == 5
    end

    test "splits on newlines and tabs" do
      assert PhaseSummary.word_count("line one\nline\ttwo\n  three") == 5
    end
  end

  describe "diff_line_count/1" do
    test "returns 0 for empty diff" do
      assert PhaseSummary.diff_line_count("") == 0
    end

    test "returns 1 for a single line without trailing newline" do
      assert PhaseSummary.diff_line_count("+++ a") == 1
    end

    test "returns 1 for a single line with trailing newline" do
      assert PhaseSummary.diff_line_count("+++ a\n") == 1
    end

    test "returns 2 for multi-line diff with trailing newline" do
      assert PhaseSummary.diff_line_count("line1\nline2\n") == 2
    end

    test "returns 2 for multi-line diff without trailing newline" do
      assert PhaseSummary.diff_line_count("line1\nline2") == 2
    end

    test "preserves blank middle lines as counted lines" do
      assert PhaseSummary.diff_line_count("line1\n\nline3\n") == 3
    end
  end

  describe "summarize/2" do
    test "returns empty string for empty input" do
      assert PhaseSummary.summarize("", 100) == ""
    end

    test "returns empty string for whitespace-only input" do
      assert PhaseSummary.summarize("   \n  \t  ", 100) == ""
    end

    test "returns trimmed canonical form when word count is below target" do
      assert PhaseSummary.summarize("  hello   world  ", 10) == "hello world"
    end

    test "returns canonical form with no marker when word count equals target" do
      result = PhaseSummary.summarize("one two three four five", 5)
      assert result == "one two three four five"
      refute result =~ "truncated"
    end

    test "truncates and appends marker when word count exceeds target" do
      text = "one two three four five six seven eight nine ten"
      result = PhaseSummary.summarize(text, 3)

      assert String.starts_with?(result, "one two three")
      assert result =~ "[summary truncated to first 3 words per spec §8.4 v1 strategy]"
    end

    test "marker references spec §8.4 v1 strategy" do
      text = String.duplicate("word ", 50)
      result = PhaseSummary.summarize(text, 5)

      assert result =~ "spec §8.4 v1 strategy"
    end

    test "marker reflects the requested target word count" do
      text = String.duplicate("word ", 50)

      assert PhaseSummary.summarize(text, 7) =~ "first 7 words"
      assert PhaseSummary.summarize(text, 12) =~ "first 12 words"
    end
  end
end
