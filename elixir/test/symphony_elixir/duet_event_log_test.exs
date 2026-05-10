defmodule SymphonyElixir.DuetEventLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.EventLog

  test "EventLog appends and reads task events as JSONL" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-event-log-#{System.unique_integer([:positive])}"
      )

    try do
      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      assert {:ok, event} =
               EventLog.append("TASK/1", "task_started", %{
                 phase: "SPEC",
                 extra: %{profile_name: "duet_balanced"}
               })

      assert event["kind"] == "task_started"
      assert event["task_id"] == "TASK/1"
      assert event["phase"] == "SPEC"
      assert event["extra"]["profile_name"] == "duet_balanced"

      path = EventLog.path_for_task("TASK/1")
      assert path =~ "TASK_1/events.jsonl"
      assert File.exists?(path)

      assert {:ok, [read_event]} = EventLog.read("TASK/1")
      assert read_event == event
    after
      File.rm_rf(test_root)
    end
  end

  test "CLI logs root configures the Duet event log root" do
    logs_root = Path.expand("tmp/duet-logs-test")

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        Application.put_env(:symphony_elixir, :log_file, SymphonyElixir.LogFile.default_log_file(path))
        EventLog.set_root(SymphonyElixir.LogFile.default_duet_event_log_root(path))
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok =
             CLI.evaluate(
               [
                 "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
                 "--logs-root",
                 logs_root,
                 "WORKFLOW.md"
               ],
               deps
             )

    assert Application.get_env(:symphony_elixir, :duet_event_log_root) ==
             Path.join(logs_root, ".duet/logs")
  end
end
