defmodule SymphonyElixir.DuetOperatorResolutionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, OperatorResolution, TaskState}

  setup do
    previous_root = Application.get_env(:symphony_elixir, :duet_event_log_root)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-op-resolution-#{System.unique_integer([:positive])}"
      )

    EventLog.set_root(Path.join(test_root, ".duet/logs"))

    on_exit(fn ->
      restore_app_env(:duet_event_log_root, previous_root)
      File.rm_rf(test_root)
    end)

    :ok
  end

  describe "resolve/3 with a task in awaiting_operator state" do
    test "human_checkpoint approve records event and returns action" do
      task_id = "OP-RES-1"
      seed_human_checkpoint(task_id)

      assert {:ok, result} = OperatorResolution.resolve(task_id, :approve)
      assert result.action == "continue_freeze"
      assert result.reason == "human_checkpoint"

      {:ok, events} = EventLog.read(task_id)
      kinds = Enum.map(events, & &1["kind"])
      assert "operator_resolution" in kinds

      resolution = Enum.find(events, &(&1["kind"] == "operator_resolution"))
      assert resolution["reason"] == "human_checkpoint"
      assert resolution["decision"] == "approve"
      assert resolution["action"] == "continue_freeze"
    end

    test "pause_on_freeze continue records event and returns action" do
      task_id = "OP-RES-FREEZE"
      seed_pause_on_freeze(task_id)

      assert {:ok, result} = OperatorResolution.resolve(task_id, :continue)
      assert result.action == "continue_freeze"
      assert result.reason == "pause_on_freeze"
    end

    test "phase_cap_escalation approve_author records event and returns action" do
      task_id = "OP-RES-CAP"
      seed_phase_cap_escalation(task_id)

      assert {:ok, result} = OperatorResolution.resolve(task_id, :approve_author)
      assert result.action == "freeze_with_mode:operator_override_author"
      assert result.reason == "phase_cap_escalation"
    end

    test "fail decision records task_failed event" do
      task_id = "OP-RES-FAIL"
      seed_human_checkpoint(task_id)

      assert {:ok, result} = OperatorResolution.resolve(task_id, :fail)
      assert result.action == :fail
      assert result.reason == "human_rejected"

      {:ok, events} = EventLog.read(task_id)
      kinds = Enum.map(events, & &1["kind"])
      assert "task_failed" in kinds

      failed = Enum.find(events, &(&1["kind"] == "task_failed"))
      assert failed["reason"] == "human_rejected"
    end
  end

  describe "resolve/3 with a task NOT in awaiting_operator" do
    test "returns error for running task" do
      task_id = "OP-RES-RUNNING"

      {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-R1"})
      {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "SPEC", cycle: 1})

      assert {:error, :not_awaiting_operator} = OperatorResolution.resolve(task_id, :approve)
    end

    test "returns error for completed task" do
      task_id = "OP-RES-DONE"

      {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-D1"})
      {:ok, _} = EventLog.append(task_id, "task_completed", %{phase: "REVIEW", cycle: 1})

      assert {:error, :not_awaiting_operator} = OperatorResolution.resolve(task_id, :approve)
    end
  end

  describe "resolve/3 with illegal decision" do
    test "returns illegal_decision error for wrong decision on reason" do
      task_id = "OP-RES-ILLEGAL"
      seed_human_checkpoint(task_id)

      # :continue is not legal for :human_checkpoint
      assert {:error, {:illegal_decision, :continue, :human_checkpoint}} =
               OperatorResolution.resolve(task_id, :continue)
    end

    test "returns illegal_decision for approve_author on human_checkpoint" do
      task_id = "OP-RES-ILLEGAL2"
      seed_human_checkpoint(task_id)

      assert {:error, {:illegal_decision, :approve_author, :human_checkpoint}} =
               OperatorResolution.resolve(task_id, :approve_author)
    end
  end

  describe "pending_gates/1" do
    test "returns gate info for paused task" do
      task_id = "OP-GATE-1"
      seed_human_checkpoint(task_id)

      assert {:ok, gate} = OperatorResolution.pending_gates(task_id)
      assert gate.reason == "human_checkpoint"
      assert gate.phase == "SPEC"
      assert gate.cycle == 1
    end

    test "returns gate info for phase_cap_escalation" do
      task_id = "OP-GATE-CAP"
      seed_phase_cap_escalation(task_id)

      assert {:ok, gate} = OperatorResolution.pending_gates(task_id)
      assert gate.reason == "phase_cap_escalation"
      assert gate.phase == "CODE"
      assert gate.cycle == 5
    end

    test "returns error for non-paused task" do
      task_id = "OP-GATE-RUNNING"

      {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-G1"})
      {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "SPEC", cycle: 1})

      assert {:error, :not_awaiting_operator} = OperatorResolution.pending_gates(task_id)
    end

    test "returns error for task with no events" do
      task_id = "OP-GATE-EMPTY"

      assert {:error, :not_awaiting_operator} = OperatorResolution.pending_gates(task_id)
    end
  end

  describe "resolve_human_checkpoint/2" do
    test "approve records human_checkpoint_resolved event" do
      task_id = "OP-HC-APPROVE"
      seed_human_checkpoint(task_id)

      assert {:ok, result} = OperatorResolution.resolve_human_checkpoint(task_id, :approve)
      assert result.action == "continue_freeze"
      assert result.reason == "human_checkpoint"

      {:ok, events} = EventLog.read(task_id)
      kinds = Enum.map(events, & &1["kind"])
      assert "human_checkpoint_resolved" in kinds
      assert "operator_resolution" in kinds

      resolved = Enum.find(events, &(&1["kind"] == "human_checkpoint_resolved"))
      assert resolved["decision"] == "approve"
    end

    test "request_changes records human_checkpoint_resolved with return_to_phase action" do
      task_id = "OP-HC-CHANGES"
      seed_human_checkpoint_at_review(task_id)

      assert {:ok, result} = OperatorResolution.resolve_human_checkpoint(task_id, :request_changes)
      assert result.action == "return_to_phase:CODE"

      {:ok, events} = EventLog.read(task_id)
      resolved = Enum.find(events, &(&1["kind"] == "human_checkpoint_resolved"))
      assert resolved["decision"] == "request_changes"
      assert resolved["action"] == "return_to_phase:CODE"
    end

    test "fail records task_failed event" do
      task_id = "OP-HC-FAIL"
      seed_human_checkpoint(task_id)

      assert {:ok, result} = OperatorResolution.resolve_human_checkpoint(task_id, :fail)
      assert result.action == :fail
      assert result.reason == "human_rejected"

      {:ok, events} = EventLog.read(task_id)
      assert Enum.any?(events, &(&1["kind"] == "task_failed"))
    end

    test "returns error when reason is not human_checkpoint" do
      task_id = "OP-HC-WRONG"
      seed_pause_on_freeze(task_id)

      assert {:error, :not_human_checkpoint} =
               OperatorResolution.resolve_human_checkpoint(task_id, :approve)
    end
  end

  describe "post-resolution task state" do
    test "TaskState.recover shows gate cleared after human_checkpoint_resolved" do
      task_id = "OP-CLEAR-1"
      seed_human_checkpoint(task_id)

      # Before resolution
      {:ok, state_before} = TaskState.recover(task_id)
      assert state_before.status == "awaiting_operator"
      assert state_before.awaiting_operator_reason == "human_checkpoint"

      # Resolve
      assert {:ok, _result} = OperatorResolution.resolve_human_checkpoint(task_id, :approve)

      # After resolution
      {:ok, state_after} = TaskState.recover(task_id)
      assert state_after.status == "running"
      assert state_after.awaiting_operator_reason == nil
    end

    test "TaskState.recover shows gate cleared after generic resolve/3 (pause_on_freeze)" do
      task_id = "OP-CLEAR-GENERIC"
      seed_pause_on_freeze(task_id)

      {:ok, state_before} = TaskState.recover(task_id)
      assert state_before.status == "awaiting_operator"
      assert state_before.awaiting_operator_reason == "pause_on_freeze"

      assert {:ok, _result} = OperatorResolution.resolve(task_id, :continue)

      {:ok, state_after} = TaskState.recover(task_id)
      assert state_after.status == "running"
      assert state_after.awaiting_operator_reason == nil
    end

    test "TaskState.recover shows gate cleared after phase_cap_escalation resolve" do
      task_id = "OP-CLEAR-CAP"
      seed_phase_cap_escalation(task_id)

      {:ok, state_before} = TaskState.recover(task_id)
      assert state_before.status == "awaiting_operator"
      assert state_before.awaiting_operator_reason == "phase_cap_escalation"

      assert {:ok, _result} = OperatorResolution.resolve(task_id, :approve_author)

      {:ok, state_after} = TaskState.recover(task_id)
      assert state_after.status == "running"
      assert state_after.awaiting_operator_reason == nil
    end

    test "TaskState.recover shows failed after fail resolution" do
      task_id = "OP-CLEAR-FAIL"
      seed_human_checkpoint(task_id)

      assert {:ok, _result} = OperatorResolution.resolve(task_id, :fail)

      {:ok, state_after} = TaskState.recover(task_id)
      assert state_after.status == "failed"
      assert state_after.awaiting_operator_reason == nil
    end
  end

  # -- Test helpers ----------------------------------------------------------

  defp seed_human_checkpoint(task_id) do
    {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-1"})
    {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "SPEC", cycle: 1})

    {:ok, _} =
      EventLog.append(task_id, "human_checkpoint_requested", %{
        phase: "SPEC",
        cycle: 1,
        tree_hash: "abc",
        reason: "human_checkpoint"
      })
  end

  defp seed_human_checkpoint_at_review(task_id) do
    {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-1"})
    {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "REVIEW", cycle: 1})

    {:ok, _} =
      EventLog.append(task_id, "human_checkpoint_requested", %{
        phase: "REVIEW",
        cycle: 1,
        tree_hash: "abc",
        reason: "human_checkpoint"
      })
  end

  defp seed_pause_on_freeze(task_id) do
    {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-1"})
    {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "SPEC", cycle: 1})

    {:ok, _} =
      EventLog.append(task_id, "phase_frozen", %{
        phase: "SPEC",
        cycle: 1,
        tree_hash: "abc",
        awaiting_operator_reason: "pause_on_freeze"
      })
  end

  defp seed_phase_cap_escalation(task_id) do
    {:ok, _} = EventLog.append(task_id, "task_started", %{identifier: "TEST-1"})
    {:ok, _} = EventLog.append(task_id, "phase_started", %{phase: "CODE", cycle: 5})

    {:ok, _} =
      EventLog.append(task_id, "phase_cap_escalation", %{
        phase: "CODE",
        cycle: 5,
        reason: "phase_cap_escalation"
      })
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
