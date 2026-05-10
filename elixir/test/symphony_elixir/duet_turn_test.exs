defmodule SymphonyElixir.DuetTurnTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, Turn}

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-turn-#{System.unique_integer([:positive])}"
      )

    EventLog.set_root(Path.join(test_root, ".duet/logs"))

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    :ok
  end

  test "record_request appends a turn_request event" do
    task_id = "TURN-REQ"

    assert :ok =
             Turn.record_request(task_id, "SPEC", 1, "claude",
               tree_hash: "abc123",
               pr_number: 42
             )

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["kind"] == "turn_request"
    assert event["phase"] == "SPEC"
    assert event["cycle"] == 1
    assert event["actor"] == "claude"
    assert event["tree_hash"] == "abc123"
    assert event["pr_number"] == 42
  end

  test "record_response writes turn_response on a clean APPROVE trailer" do
    task_id = "TURN-OK"

    response = """
    Some prose.

    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.9
    summary: Looks good
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, turn, []} =
             Turn.record_response(task_id, "SPEC", 1, "codex", response, tree_hash: "deadbeef")

    assert turn.verdict == :approve
    assert turn.confidence == 0.9
    assert turn.summary == "Looks good"
    assert turn.unresolved == []
    assert turn.tree_hash == "deadbeef"

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["kind"] == "turn_response"
    assert event["verdict"] == "APPROVE"
    assert event["tree_hash"] == "deadbeef"
    assert event["unresolved"] == []
  end

  test "record_response emits low_confidence_approve alongside turn_response" do
    task_id = "TURN-LOW"

    response = """
    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.2
    summary: Hesitant
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, turn, [:low_confidence_approve]} =
             Turn.record_response(task_id, "PLAN", 2, "codex", response)

    assert turn.confidence == 0.2

    assert {:ok, events} = EventLog.read(task_id)
    assert Enum.map(events, & &1["kind"]) == ["turn_response", "low_confidence_approve"]
    assert Enum.find(events, &(&1["kind"] == "low_confidence_approve"))["actor"] == "codex"
  end

  test "record_response synthesizes unresolved without an extra event" do
    task_id = "TURN-SYNTH"

    response = """
    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    summary: Issues
    unresolved: []
    ---END-DUET-TRAILER---
    """

    assert {:ok, turn, [:synthesized_no_details]} =
             Turn.record_response(task_id, "CODE", 1, "codex", response)

    assert turn.verdict == :request_changes
    assert turn.unresolved == ["no_details_provided"]

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["kind"] == "turn_response"
    assert event["verdict"] == "REQUEST_CHANGES"
    assert event["unresolved"] == ["no_details_provided"]
  end

  test "record_response surfaces APPROVE-with-unresolved without a synthetic event" do
    task_id = "TURN-CONTRA"

    response = """
    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.8
    summary: Looks fine
    unresolved: [security_concern]
    ---END-DUET-TRAILER---
    """

    assert {:ok, turn, [{:approve_with_unresolved, ["security_concern"]}]} =
             Turn.record_response(task_id, "CODE", 1, "claude", response)

    assert turn.verdict == :approve
    assert turn.unresolved == ["security_concern"]

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["kind"] == "turn_response"
    assert event["unresolved"] == ["security_concern"]
  end

  test "record_response emits trailer_rejected when the trailer is missing" do
    task_id = "TURN-MISSING"

    assert {:error, :missing} =
             Turn.record_response(task_id, "SPEC", 1, "codex", "no trailer here")

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["kind"] == "trailer_rejected"
    assert event["reason"] == "missing"
  end

  test "record_response emits trailer_rejected when the trailer is malformed" do
    task_id = "TURN-MALFORMED"

    response = """
    ---DUET-TRAILER---
    verdict: BANANA
    summary: nope
    ---END-DUET-TRAILER---
    """

    assert {:error, :malformed} =
             Turn.record_response(task_id, "SPEC", 1, "codex", response)

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["reason"] == "malformed"
  end

  test "record_response emits trailer_rejected when the trailer is too far from the end" do
    task_id = "TURN-POS"

    filler = String.duplicate("filler\n", 60)

    response = """
    ---DUET-TRAILER---
    verdict: APPROVE
    summary: Top of response
    unresolved: []
    ---END-DUET-TRAILER---
    #{filler}
    """

    assert {:error, :position_invalid} =
             Turn.record_response(task_id, "SPEC", 1, "codex", response)

    assert {:ok, [event]} = EventLog.read(task_id)
    assert event["reason"] == "position_invalid"
  end

  test "record_response propagates event log failures while recording trailer rejection" do
    bad_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-turn-bad-root-#{System.unique_integer([:positive])}"
      )

    File.write!(bad_root, "not a directory")
    on_exit(fn -> File.rm_rf(bad_root) end)
    EventLog.set_root(bad_root)

    assert {:error, {:event_log_failed, :enotdir}} =
             Turn.record_response("TURN-LOG-FAIL", "SPEC", 1, "codex", "no trailer here")
  end
end
