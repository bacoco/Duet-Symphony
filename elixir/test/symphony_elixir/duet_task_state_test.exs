defmodule SymphonyElixir.DuetTaskStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, Routing, TaskState}

  setup do
    previous_root = Application.get_env(:symphony_elixir, :duet_event_log_root)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-task-state-#{System.unique_integer([:positive])}"
      )

    EventLog.set_root(Path.join(test_root, ".duet/logs"))

    on_exit(fn ->
      restore_app_env(:duet_event_log_root, previous_root)
      File.rm_rf(test_root)
    end)

    :ok
  end

  test "recovers task phase state from Duet events" do
    task_id = "TASK-STATE"
    settings = Config.settings!().duet
    {:ok, profile} = Routing.resolve(settings)

    assert {:ok, _event} = EventLog.append(task_id, "task_started", %{identifier: "MT-900"})
    assert {:ok, _event} = EventLog.append(task_id, "agent_routing_selected", Routing.to_event_attrs(profile))
    assert {:ok, _event} = EventLog.append(task_id, "phase_started", %{phase: "SPEC", cycle: 1})

    assert {:ok, _event} =
             EventLog.append(task_id, "turn_response", %{
               phase: "SPEC",
               cycle: 1,
               actor: "codex",
               verdict: "APPROVE",
               tree_hash: "abc123"
             })

    assert {:ok, _event} =
             EventLog.append(task_id, "phase_frozen", %{
               phase: "SPEC",
               cycle: 1,
               tree_hash: "abc123"
             })

    assert {:ok, state} = TaskState.recover(task_id, settings)
    assert state.task_id == task_id
    assert state.status == "running"
    assert state.current_phase == "SPEC"
    assert state.events_count == 5
    assert state.routing_status == "matched"
    assert state.routing["profile_name"] == "duet_balanced"
    assert state.last_event["kind"] == "phase_frozen"

    assert state.phases["SPEC"].status == "frozen"
    assert state.phases["SPEC"].cycle == 1
    assert state.phases["SPEC"].actor == "codex"
    assert state.phases["SPEC"].verdict == "APPROVE"
    assert state.phases["SPEC"].tree_hash == "abc123"
  end

  test "detects routing divergence between event log and current config" do
    task_id = "TASK-DIVERGENCE"
    initial_settings = Config.settings!().duet
    {:ok, profile} = Routing.resolve(initial_settings)

    assert {:ok, _event} = EventLog.append(task_id, "agent_routing_selected", Routing.to_event_attrs(profile))

    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: codex_only_dev
      """
    )

    assert {:error, {:routing_divergence, recorded, current}} =
             TaskState.recover(task_id, Config.settings!().duet)

    assert recorded["profile_name"] == "duet_balanced"
    assert current["profile_name"] == "codex_only_dev"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
