defmodule SymphonyElixir.DuetTrailerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Trailer

  test "parses a clean APPROVE trailer with no semantic issues" do
    text = """
    Some prose explaining the position.

    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.85
    summary: Looks good to merge
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.verdict == :approve
    assert trailer.confidence == 0.85
    assert trailer.summary == "Looks good to merge"
    assert trailer.unresolved == []
  end

  test "parses a clean REQUEST_CHANGES trailer with explicit unresolved items" do
    text = """
    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    confidence: 0.72
    summary: Needs more tests
    unresolved: [missing_test_for_foo, missing_test_for_bar]
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.verdict == :request_changes
    assert trailer.unresolved == ["missing_test_for_foo", "missing_test_for_bar"]
  end

  test "tolerates quoted unresolved items and surrounding whitespace" do
    text = """
    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    summary: Concerns
    unresolved: [ "first concern" , 'second' ]
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.unresolved == ["first concern", "second"]
  end

  test "flags APPROVE with unresolved as a contradiction without mutating the list" do
    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.9
    summary: Looks fine
    unresolved: [security_concern, perf_question]
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, [{:approve_with_unresolved, original}]} = Trailer.parse(text)
    assert trailer.verdict == :approve
    assert trailer.unresolved == ["security_concern", "perf_question"]
    assert original == ["security_concern", "perf_question"]
  end

  test "synthesizes unresolved when REQUEST_CHANGES has empty list" do
    text = """
    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    confidence: 0.6
    summary: Issues to address
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, [:synthesized_no_details]} = Trailer.parse(text)
    assert trailer.verdict == :request_changes
    assert trailer.unresolved == ["no_details_provided"]
  end

  test "flags low-confidence APPROVE while accepting the verdict" do
    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.2
    summary: Not fully sure
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, [:low_confidence_approve]} = Trailer.parse(text)
    assert trailer.verdict == :approve
    assert trailer.confidence == 0.2
  end

  test "accepts a trailer without a confidence field" do
    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    summary: No confidence given
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.confidence == nil
  end

  test "picks the last syntactically valid block when multiple are present" do
    text = """
    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    summary: Earlier turn
    unresolved: [old_concern]
    ---END-DUET-TRAILER---

    Some prose between blocks.

    ---DUET-TRAILER---
    verdict: APPROVE
    summary: Final position
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.verdict == :approve
    assert trailer.summary == "Final position"
  end

  test "falls back to an earlier valid block when the last block is malformed" do
    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    summary: Real verdict
    unresolved: []
    ---END-DUET-TRAILER---

    ---DUET-TRAILER---
    verdict: BANANA
    ---END-DUET-TRAILER---
    """

    assert {:ok, trailer, []} = Trailer.parse(text)
    assert trailer.verdict == :approve
    assert trailer.summary == "Real verdict"
  end

  test "returns :missing when no trailer block is present" do
    assert {:error, :missing} = Trailer.parse("just prose, no trailer at all")
  end

  test "returns :malformed when present blocks all fail to parse" do
    text = """
    ---DUET-TRAILER---
    verdict: BANANA
    summary: garbage
    ---END-DUET-TRAILER---
    """

    assert {:error, :malformed} = Trailer.parse(text)
  end

  test "rejects a trailer with confidence outside [0, 1]" do
    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 1.5
    summary: Out of range
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:error, :malformed} = Trailer.parse(text)
  end

  test "rejects a trailer placed earlier than 50 lines from the end" do
    filler = String.duplicate("filler line\n", 60)

    text = """
    ---DUET-TRAILER---
    verdict: APPROVE
    summary: Top of response
    unresolved: []
    ---END-DUET-TRAILER---
    #{filler}
    """

    assert {:error, :position_invalid} = Trailer.parse(text)
  end
end
