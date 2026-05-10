defmodule SymphonyElixir.RunnerSelectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, RoutingSelection, Transcripts}
  alias SymphonyElixir.Duet.PairRunner
  alias SymphonyElixir.RunnerSelector

  defmodule SequenceDriver do
    @behaviour SymphonyElixir.Duet.TurnDriver

    @impl SymphonyElixir.Duet.TurnDriver
    def drive_turn(prompt, opts) do
      agent = Keyword.fetch!(opts, :sequence_agent)
      test_pid = Keyword.fetch!(opts, :test_pid)
      response = Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
      send(test_pid, {:duet_prompt, prompt})
      {:ok, response}
    end
  end

  test "selects AgentRunner by default" do
    assert RunnerSelector.choose(Config.settings!()) == AgentRunner
  end

  test "selects PairRunner when duet is enabled" do
    write_workflow_file!(Workflow.workflow_file_path(), duet_enabled: true)

    assert RunnerSelector.choose(Config.settings!()) == PairRunner
  end

  test "PairRunner fails before dispatch when the selected SPEC profile has no reviewer" do
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

      assert {:error, :reviewer_not_configured} = PairRunner.run(issue)
      assert {:error, :reviewer_not_configured} = PairRunner.run(issue, self())
      assert {:error, :reviewer_not_configured} = PairRunner.run(issue, self(), [])

      assert {:ok, events} = EventLog.read(issue)
      assert Enum.map(events, & &1["kind"]) == ["task_started", "agent_routing_selected", "phase_started", "task_failed"]
      assert Enum.find(events, &(&1["kind"] == "agent_routing_selected"))["profile_name"] == "claude_only_dev"
      assert List.last(events)["reason"] == "reviewer_not_configured"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner drives a converged SPEC Author and Reviewer cycle" do
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

      response = """
      Draft SPEC content.

      ---DUET-TRAILER---
      verdict: APPROVE
      confidence: 0.9
      summary: SPEC draft is ready for review
      unresolved: []
      ---END-DUET-TRAILER---
      """

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response],
                 tree_hash: "tree-spec-1"
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.map(events, & &1["kind"]) == [
               "task_started",
               "agent_routing_selected",
               "phase_started",
               "turn_request",
               "turn_response",
               "turn_request",
               "turn_response",
               "phase_frozen"
             ]

      turn_requests = Enum.filter(events, &(&1["kind"] == "turn_request"))
      assert Enum.map(turn_requests, & &1["actor"]) == ["claude", "codex"]
      assert Enum.all?(turn_requests, &(&1["phase"] == "SPEC"))
      assert Enum.all?(turn_requests, &(&1["cycle"] == 1))

      turn_responses = Enum.filter(events, &(&1["kind"] == "turn_response"))
      assert Enum.map(turn_responses, & &1["actor"]) == ["claude", "codex"]
      assert Enum.all?(turn_responses, &(&1["verdict"] == "APPROVE"))
      assert Enum.all?(turn_responses, &(&1["tree_hash"] == "tree-spec-1"))

      phase_frozen = List.last(events)
      assert phase_frozen["kind"] == "phase_frozen"
      assert phase_frozen["phase"] == "SPEC"
      assert phase_frozen["cycle"] == 1
      assert phase_frozen["mode"] == "consensus"
      assert phase_frozen["tree_hash"] == "tree-spec-1"
      assert phase_frozen["next_phase"] == "PLAN"

      assert {:ok, author_transcript} = Transcripts.read(issue, "SPEC", 1, "claude")
      assert {:ok, reviewer_transcript} = Transcripts.read(issue, "SPEC", 1, "codex")

      assert author_transcript =~ "[DUET SPEC TURN]"
      assert reviewer_transcript =~ "Current SPEC revision"
      assert reviewer_transcript =~ "Draft SPEC content."

      assert_receive {:worker_runtime_info, "issue-duet-codex-author", %{workspace_path: workspace_path}}, 500
      assert Path.basename(workspace_path) == "DUET-CODEX-AUTHOR"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner continues SPEC after reviewer requests changes, then freezes on convergence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-spec-cycle-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-duet-spec-cycle",
        identifier: "DUET-SPEC-CYCLE",
        title: "Iterate SPEC",
        description: "Reviewer should force a second cycle",
        state: "In Progress",
        url: "https://example.org/issues/DUET-SPEC-CYCLE"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("Author cycle 1"),
            request_changes_response("Reviewer cycle 1", ["Clarify acceptance criteria"]),
            approve_response("Author cycle 2"),
            approve_response("Reviewer cycle 2")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SequenceDriver,
                 turn_driver_opts: [sequence_agent: agent, test_pid: self()],
                 tree_hash: "tree-spec-cycle"
               )

      assert {:ok, events} = EventLog.read(issue)

      turn_responses = Enum.filter(events, &(&1["kind"] == "turn_response"))

      assert Enum.map(turn_responses, &{&1["cycle"], &1["actor"], &1["verdict"]}) == [
               {1, "claude", "APPROVE"},
               {1, "codex", "REQUEST_CHANGES"},
               {2, "claude", "APPROVE"},
               {2, "codex", "APPROVE"}
             ]

      phase_started = Enum.filter(events, &(&1["kind"] == "phase_started"))
      assert Enum.map(phase_started, & &1["cycle"]) == [1, 2]

      assert List.last(events)["kind"] == "phase_frozen"
      assert List.last(events)["cycle"] == 2

      assert_receive {:duet_prompt, author_cycle_1}
      assert_receive {:duet_prompt, reviewer_cycle_1}
      assert_receive {:duet_prompt, author_cycle_2}
      assert_receive {:duet_prompt, _reviewer_cycle_2}

      assert author_cycle_1 =~ "role=Author"
      assert reviewer_cycle_1 =~ "role=Reviewer"
      assert author_cycle_2 =~ "Previous reviewer verdict: request_changes"
      assert author_cycle_2 =~ "Clarify acceptance criteria"
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

      response = approve_response("Lifecycle SPEC")

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response],
                 tree_hash: "tree-lifecycle"
               )

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

      assert {:ok, events} = EventLog.read(issue)
      [task_started, routing_selected, phase_started | _rest] = events

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

      assert List.last(events)["kind"] == "phase_frozen"
      refute Enum.any?(events, &(&1["kind"] == "task_failed"))
    after
      File.rm_rf(test_root)
    end
  end

  defp approve_response(label) do
    """
    #{label}

    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.9
    summary: #{label} ready
    unresolved: []
    ---END-DUET-TRAILER---
    """
  end

  defp request_changes_response(label, unresolved) do
    """
    #{label}

    ---DUET-TRAILER---
    verdict: REQUEST_CHANGES
    confidence: 0.8
    summary: #{label} needs changes
    unresolved: #{inspect(unresolved)}
    ---END-DUET-TRAILER---
    """
  end
end
