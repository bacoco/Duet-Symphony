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
      assert Enum.map(events, & &1["kind"]) == ["task_started", "agent_routing_selected", "task_failed"]
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

  test "PairRunner advances SPEC, PLAN, CODE, and REVIEW across continuation dispatches" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-full-pipeline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-duet-full-pipeline",
        identifier: "DUET-FULL",
        title: "Run all phases",
        description: "Drive the minimum viable phase pipeline",
        state: "In Progress",
        url: "https://example.org/issues/DUET-FULL"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("SPEC author"),
            approve_response("SPEC reviewer"),
            approve_response("PLAN author"),
            approve_response("PLAN reviewer"),
            approve_response("CODE author"),
            approve_response("CODE reviewer"),
            approve_response("REVIEW coder ack"),
            approve_response("REVIEW reviewer")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      opts = [
        turn_driver: SequenceDriver,
        turn_driver_opts: [sequence_agent: agent, test_pid: self()],
        tree_hash_provider: fn _workspace, phase, _cycle, _actor -> "tree-#{phase}" end
      ]

      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)

      assert {:ok, events} = EventLog.read(issue)

      frozen = Enum.filter(events, &(&1["kind"] == "phase_frozen"))
      assert Enum.map(frozen, & &1["phase"]) == ["SPEC", "PLAN", "CODE", "REVIEW"]
      assert Enum.map(frozen, & &1["next_phase"]) == ["PLAN", "CODE", "REVIEW", nil]
      assert Enum.map(frozen, & &1["tree_hash"]) == ["tree-SPEC", "tree-PLAN", "tree-CODE", "tree-REVIEW"]

      turn_responses = Enum.filter(events, &(&1["kind"] == "turn_response"))

      assert Enum.map(turn_responses, &{&1["phase"], &1["actor"]}) == [
               {"SPEC", "claude"},
               {"SPEC", "codex"},
               {"PLAN", "codex"},
               {"PLAN", "claude"},
               {"CODE", "codex"},
               {"CODE", "claude"},
               {"REVIEW", "codex"},
               {"REVIEW", "claude"}
             ]

      assert List.last(events)["kind"] == "task_completed"
      assert List.last(events)["phase"] == "REVIEW"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner pauses before freeze when a blocking human checkpoint is configured" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-human-checkpoint-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
          human_checkpoints:
            enabled: true
            default_mode: blocking
            phases:
              spec: true
              plan: false
              code: false
              review: false
        """
      )

      issue = %Issue{
        id: "issue-duet-human-checkpoint",
        identifier: "DUET-HUMAN",
        title: "Human gate",
        description: "Pause after machine convergence",
        state: "In Progress",
        url: "https://example.org/issues/DUET-HUMAN"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      assert {:error, :human_checkpoint} =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: approve_response("SPEC")],
                 tree_hash: "tree-human"
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.any?(events, &(&1["kind"] == "human_checkpoint_requested"))
      refute Enum.any?(events, &(&1["kind"] == "phase_frozen"))
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner injects verification evidence into the Reviewer prompt" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-verification-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
          verification_gate:
            enabled: true
            phases: [spec]
            mode: local_command
            inject_into: reviewer
            on_timeout: warn
        """
      )

      issue = %Issue{
        id: "issue-duet-verification",
        identifier: "DUET-VERIFY",
        title: "Verification gate",
        description: "Inject objective evidence before reviewer dispatch",
        state: "In Progress",
        url: "https://example.org/issues/DUET-VERIFY"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("SPEC author with verification"),
            approve_response("SPEC reviewer with verification")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SequenceDriver,
                 turn_driver_opts: [sequence_agent: agent, test_pid: self()],
                 tree_hash: "tree-verification",
                 verification_checks_provider: fn "SPEC", 1 ->
                   [%{name: "mix test", status: :pass, summary: "239 tests, 0 failures"}]
                 end
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.map(events, & &1["kind"]) == [
               "task_started",
               "agent_routing_selected",
               "phase_started",
               "turn_request",
               "turn_response",
               "verification_completed",
               "turn_request",
               "turn_response",
               "phase_frozen"
             ]

      verification = Enum.find(events, &(&1["kind"] == "verification_completed"))
      assert verification["phase"] == "SPEC"
      assert verification["cycle"] == 1
      assert verification["status"] == "pass"

      assert [%{"name" => "mix test", "status" => "pass", "summary" => "239 tests, 0 failures"}] =
               verification["checks"]

      assert_receive {:duet_prompt, author_prompt}
      assert_receive {:duet_prompt, reviewer_prompt}
      refute author_prompt =~ "---DUET-VERIFICATION---"
      assert reviewer_prompt =~ "---DUET-VERIFICATION---"
      assert reviewer_prompt =~ "status: pass"
      assert reviewer_prompt =~ "mix test"
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner blocks Reviewer dispatch when verification times out in block mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-verification-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
          verification_gate:
            enabled: true
            phases: [spec]
            mode: local_command
            inject_into: reviewer
            on_timeout: block
        """
      )

      issue = %Issue{
        id: "issue-duet-verification-timeout",
        identifier: "DUET-VERIFY-TIMEOUT",
        title: "Verification timeout",
        description: "Block reviewer dispatch on timeout",
        state: "In Progress",
        url: "https://example.org/issues/DUET-VERIFY-TIMEOUT"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      assert {:error, :verification_timeout} =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: approve_response("SPEC author before timeout")],
                 tree_hash: "tree-verification-timeout",
                 verification_checks_provider: fn "SPEC", 1 -> :timeout end
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.map(events, & &1["kind"]) == [
               "task_started",
               "agent_routing_selected",
               "phase_started",
               "turn_request",
               "turn_response",
               "verification_completed"
             ]

      verification = List.last(events)
      assert verification["status"] == "timeout"
      refute Enum.any?(events, &(&1["actor"] == "codex" and &1["kind"] == "turn_request"))
      refute Enum.any?(events, &(&1["kind"] == "phase_frozen"))
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner keeps a frozen phase paused when pause_on_freeze is enabled" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-pause-on-freeze-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
          pause_on_freeze: true
        """
      )

      issue = %Issue{
        id: "issue-duet-pause-on-freeze",
        identifier: "DUET-PAUSE",
        title: "Pause on freeze",
        description: "Operator pause after frozen phase",
        state: "In Progress",
        url: "https://example.org/issues/DUET-PAUSE"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("SPEC author before pause"),
            approve_response("SPEC reviewer before pause")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      opts = [
        turn_driver: SequenceDriver,
        turn_driver_opts: [sequence_agent: agent, test_pid: self()],
        tree_hash: "tree-pause"
      ]

      assert {:error, :pause_on_freeze} = PairRunner.run(issue, self(), opts)
      assert {:error, :pause_on_freeze} = PairRunner.run(issue, self(), opts)

      assert {:ok, events} = EventLog.read(issue)
      frozen = Enum.filter(events, &(&1["kind"] == "phase_frozen"))
      assert length(frozen) == 1
      assert hd(frozen)["phase"] == "SPEC"
      assert hd(frozen)["awaiting_operator_reason"] == "pause_on_freeze"
      assert Enum.map(Enum.filter(events, &(&1["kind"] == "phase_started")), & &1["phase"]) == ["SPEC"]
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner pauses REVIEW freeze when CODE PR mergeability reports a conflict" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-code-pr-conflict-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-duet-code-pr-conflict",
        identifier: "DUET-CONFLICT",
        title: "CODE PR conflict",
        description: "Pause when the held-open CODE PR cannot merge",
        state: "In Progress",
        url: "https://example.org/issues/DUET-CONFLICT"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("SPEC author"),
            approve_response("SPEC reviewer"),
            approve_response("PLAN author"),
            approve_response("PLAN reviewer"),
            approve_response("CODE author"),
            approve_response("CODE reviewer"),
            approve_response("REVIEW coder ack"),
            approve_response("REVIEW reviewer")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      opts = [
        turn_driver: SequenceDriver,
        turn_driver_opts: [sequence_agent: agent, test_pid: self()],
        tree_hash_provider: fn _workspace, phase, _cycle, _actor -> "tree-#{phase}" end,
        code_pr_mergeability_provider: fn %{phase: "REVIEW"} ->
          {:conflict,
           %{
             paths: ["lib/conflict.ex"],
             base_head: "base-head",
             pr_permalink: "https://example.org/pull/42"
           }}
        end
      ]

      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert {:error, :code_pr_conflict} = PairRunner.run(issue, self(), opts)

      assert {:ok, events} = EventLog.read(issue)
      assert Enum.map(Enum.filter(events, &(&1["kind"] == "phase_frozen")), & &1["phase"]) == ["SPEC", "PLAN", "CODE"]

      conflict = Enum.find(events, &(&1["kind"] == "code_pr_conflict"))
      assert conflict["phase"] == "REVIEW"
      assert conflict["reason"] == "code_pr_conflict"
      assert conflict["conflicting_paths"] == ["lib/conflict.ex"]
      assert conflict["base_head"] == "base-head"
      assert conflict["pr_permalink"] == "https://example.org/pull/42"
      refute Enum.any?(events, &(&1["kind"] == "task_completed"))
    after
      File.rm_rf(test_root)
    end
  end

  test "PairRunner appends configured tool-profile constraints to turn prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pair-runner-tool-profile-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
          tool_profiles:
            enabled: true
            default_profile: default
            profiles:
              default:
                spec:
                  author: [file_read]
                  reviewers:
                    default: [git_diff]
        """
      )

      issue = %Issue{
        id: "issue-duet-tool-profile",
        identifier: "DUET-TOOLS",
        title: "Tool profile",
        description: "Constrain tools per role",
        state: "In Progress",
        url: "https://example.org/issues/DUET-TOOLS"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            approve_response("SPEC author under tool profile"),
            approve_response("SPEC reviewer under tool profile")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SequenceDriver,
                 turn_driver_opts: [sequence_agent: agent, test_pid: self()],
                 tree_hash: "tree-tools"
               )

      assert_receive {:duet_prompt, author_prompt}
      assert_receive {:duet_prompt, reviewer_prompt}
      assert author_prompt =~ "Allowed tools for this turn: file_read"
      assert reviewer_prompt =~ "Allowed tools for this turn: git_diff"
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
