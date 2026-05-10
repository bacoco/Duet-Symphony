defmodule SymphonyElixir.RunnerSelectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, RoutingSelection, Transcripts}
  alias SymphonyElixir.Duet.PairRunner
  alias SymphonyElixir.RunnerSelector

  test "selects AgentRunner by default" do
    assert RunnerSelector.choose(Config.settings!()) == AgentRunner
  end

  test "selects PairRunner when duet is enabled" do
    write_workflow_file!(Workflow.workflow_file_path(), duet_enabled: true)

    assert RunnerSelector.choose(Config.settings!()) == PairRunner
  end

  test "PairRunner is a not implemented stub for non-Codex SPEC authors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-stub-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces")
      )

      issue = %Issue{id: "issue-duet", identifier: "DUET-1"}
      EventLog.set_root(Path.join(test_root, ".duet/logs"))
      assert {:ok, _payload} = RoutingSelection.select(Config.settings!().duet, "claude_only_dev")

      assert {:error, :not_implemented} = PairRunner.run(issue)
      assert {:error, :not_implemented} = PairRunner.run(issue, self())
      assert {:error, :not_implemented} = PairRunner.run(issue, self(), [])

      assert {:ok, events} = EventLog.read(issue)
      assert Enum.map(events, & &1["kind"]) == ["task_started", "agent_routing_selected", "phase_started", "task_failed"]
      assert Enum.find(events, &(&1["kind"] == "agent_routing_selected"))["profile_name"] == "claude_only_dev"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner drives one Codex SPEC author turn before stopping at the missing reviewer" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-codex-author-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-duet-codex-author",
        identifier: "DUET-CODEX-AUTHOR",
        title: "Write the spec",
        description: "Create a deterministic SPEC draft",
        state: "In Progress",
        url: "https://example.org/issues/DUET-CODEX-AUTHOR"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))
      assert {:ok, _payload} = RoutingSelection.select(Config.settings!().duet, "codex_only_dev")

      response = """
      Draft SPEC content.

      ---DUET-TRAILER---
      verdict: APPROVE
      confidence: 0.9
      summary: SPEC draft is ready for review
      unresolved: []
      ---END-DUET-TRAILER---
      """

      assert {:error, :reviewer_not_implemented} =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response]
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.map(events, & &1["kind"]) == [
               "task_started",
               "agent_routing_selected",
               "phase_started",
               "turn_request",
               "turn_response",
               "task_failed"
             ]

      turn_request = Enum.find(events, &(&1["kind"] == "turn_request"))
      assert turn_request["phase"] == "SPEC"
      assert turn_request["cycle"] == 1
      assert turn_request["actor"] == "codex"

      turn_response = Enum.find(events, &(&1["kind"] == "turn_response"))
      assert turn_response["verdict"] == "APPROVE"
      assert turn_response["summary"] == "SPEC draft is ready for review"

      task_failed = List.last(events)
      assert task_failed["kind"] == "task_failed"
      assert task_failed["reason"] == "reviewer_not_implemented"

      assert {:ok, transcript} = Transcripts.read(issue, "SPEC", 1, "codex")

      assert transcript =~ "[DUET SPEC TURN]"
      assert transcript =~ "Draft SPEC content."

      assert_receive {:worker_runtime_info, "issue-duet-codex-author", %{workspace_path: workspace_path}}, 500
      assert Path.basename(workspace_path) == "DUET-CODEX-AUTHOR"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner uses the shared workspace lifecycle before the stub returns" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-lifecycle-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf created > after_create.txt",
        hook_before_run: "printf before > before_run.txt",
        hook_after_run: "printf after > after_run.txt"
      )

      issue = %Issue{id: "issue-duet-lifecycle", identifier: "DUET-LIFE"}
      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      assert {:error, :not_implemented} = PairRunner.run(issue, self(), [])

      assert_receive {:worker_runtime_info, "issue-duet-lifecycle",
                      %{
                        worker_host: nil,
                        workspace_path: workspace_path
                      }},
                     500

      assert Path.basename(workspace_path) == "DUET-LIFE"
      assert workspace_path =~ "symphony-elixir-pair-runner-lifecycle"
      assert File.dir?(workspace_path)
      assert File.read!(Path.join(workspace_path, "after_create.txt")) == "created"
      assert File.read!(Path.join(workspace_path, "before_run.txt")) == "before"
      assert File.read!(Path.join(workspace_path, "after_run.txt")) == "after"

      assert {:ok, [task_started, routing_selected, phase_started, task_failed]} = EventLog.read(issue)

      assert task_started["kind"] == "task_started"
      assert task_started["task_id"] == "issue-duet-lifecycle"
      assert task_started["identifier"] == "DUET-LIFE"

      assert routing_selected["kind"] == "agent_routing_selected"
      assert routing_selected["task_id"] == "issue-duet-lifecycle"
      assert routing_selected["profile_name"] == "duet_balanced"
      assert routing_selected["mode"] == "full_duet"
      assert routing_selected["degraded"] == false
      assert routing_selected["phases"]["spec"]["author"] == "claude"
      assert routing_selected["phases"]["spec"]["reviewers"] == ["codex"]

      assert phase_started["kind"] == "phase_started"
      assert phase_started["task_id"] == "issue-duet-lifecycle"
      assert phase_started["phase"] == "SPEC"
      assert phase_started["cycle"] == 1

      assert task_failed["kind"] == "task_failed"
      assert task_failed["task_id"] == "issue-duet-lifecycle"
      assert task_failed["reason"] == "not_implemented"
    after
      File.rm_rf(test_root)
    end
  end
end
