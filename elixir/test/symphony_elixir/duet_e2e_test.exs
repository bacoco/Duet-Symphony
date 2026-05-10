defmodule SymphonyElixir.DuetE2ETest do
  @moduledoc """
  End-to-end tests that verify `duet.enabled: true` routes through
  RunnerSelector to PairRunner and drives the phase pipeline.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, PairRunner}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RunnerSelector

  # ── SequenceDriver ──────────────────────────────────────────────
  # Reads canned responses from an Agent in FIFO order, exactly as
  # runner_selector_test.exs defines it.

  defmodule SequenceDriver do
    @behaviour SymphonyElixir.Duet.TurnDriver

    @impl SymphonyElixir.Duet.TurnDriver
    def drive_turn(prompt, opts) do
      agent = Keyword.fetch!(opts, :sequence_agent)
      test_pid = Keyword.get(opts, :test_pid)

      response =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {"(no more responses)", []}
        end)

      if test_pid, do: send(test_pid, {:duet_prompt, prompt})
      {:ok, response}
    end
  end

  # ── Test 1 ──────────────────────────────────────────────────────

  @tag :e2e
  test "RunnerSelector routes to PairRunner and SPEC phase completes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-e2e-duet-dispatch-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        duet_yaml: """
        duet:
          enabled: true
        """
      )

      issue = %Issue{
        id: "issue-e2e-duet-1",
        identifier: "E2E-1",
        title: "E2E dispatch test",
        description: "End to end dispatch test",
        state: "In Progress",
        url: "https://example.org/issues/E2E-1"
      }

      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      response = approve_response("E2E SPEC")

      assert RunnerSelector.choose(Config.settings!()) == PairRunner

      assert :ok =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response],
                 tree_hash: "tree-e2e-dispatch"
               )

      assert {:ok, events} = EventLog.read(issue)

      kinds = Enum.map(events, & &1["kind"])
      assert "task_started" in kinds
      assert "agent_routing_selected" in kinds
      assert "phase_started" in kinds
      assert "phase_frozen" in kinds

      routing = Enum.find(events, &(&1["kind"] == "agent_routing_selected"))
      assert routing["mode"] == "full_duet"

      frozen = Enum.find(events, &(&1["kind"] == "phase_frozen"))
      assert frozen["phase"] == "SPEC"
      assert frozen["next_phase"] == "PLAN"
    after
      File.rm_rf(test_root)
    end
  end

  # ── Test 2 ──────────────────────────────────────────────────────

  @tag :e2e
  test "Orchestrator completes full task lifecycle with duet pair loop" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-e2e-duet-full-lifecycle-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        poll_interval_ms: 60_000,
        duet_yaml: """
        duet:
          enabled: true
        """
      )

      issue = %Issue{
        id: "issue-e2e-duet-lifecycle",
        identifier: "E2E-LIFECYCLE",
        title: "Full lifecycle",
        description: "Drive all four phases to completion",
        state: "In Progress",
        url: "https://example.org/issues/E2E-LIFECYCLE"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      {:ok, agent} =
        Agent.start_link(fn ->
          [
            # SPEC: author + reviewer
            approve_response("SPEC author"),
            approve_response("SPEC reviewer"),
            # PLAN: author + reviewer
            approve_response("PLAN author"),
            approve_response("PLAN reviewer"),
            # CODE: author + reviewer
            approve_response("CODE author"),
            approve_response("CODE reviewer"),
            # REVIEW: coder_ack + reviewer
            approve_response("REVIEW coder ack"),
            approve_response("REVIEW reviewer")
          ]
        end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      opts = [
        turn_driver: SequenceDriver,
        turn_driver_opts: [sequence_agent: agent, test_pid: self()],
        tree_hash_provider: fn _ws, phase, _cycle, _actor ->
          "tree-#{phase}"
        end
      ]

      # Simulate four Orchestrator dispatch cycles (one per phase).
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)

      assert {:ok, events} = EventLog.read(issue)

      # All four phases should be frozen.
      frozen = Enum.filter(events, &(&1["kind"] == "phase_frozen"))
      assert Enum.map(frozen, & &1["phase"]) == ["SPEC", "PLAN", "CODE", "REVIEW"]

      assert Enum.map(frozen, & &1["next_phase"]) ==
               ["PLAN", "CODE", "REVIEW", nil]

      # task_completed event must exist.
      assert Enum.any?(events, &(&1["kind"] == "task_completed"))
      completed = Enum.find(events, &(&1["kind"] == "task_completed"))
      assert completed["phase"] == "REVIEW"

      # Verify alternating author/reviewer roles across phases.
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

      # All verdicts should be APPROVE.
      assert Enum.all?(turn_responses, &(&1["verdict"] == "APPROVE"))
    after
      File.rm_rf(test_root)
    end
  end

  # ── Test 3 ──────────────────────────────────────────────────────

  @tag :e2e
  test "Orchestrator retries after awaiting_operator gate (human checkpoint)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-e2e-duet-human-checkpoint-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        poll_interval_ms: 60_000,
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
        id: "issue-e2e-duet-checkpoint",
        identifier: "E2E-CHECKPOINT",
        title: "Human checkpoint gate",
        description: "Pause after SPEC convergence",
        state: "In Progress",
        url: "https://example.org/issues/E2E-CHECKPOINT"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      EventLog.set_root(Path.join(test_root, ".duet/logs"))

      response = approve_response("E2E SPEC checkpoint")

      # First dispatch: PairRunner should pause with human_checkpoint.
      assert {:error, :human_checkpoint} =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response],
                 tree_hash: "tree-e2e-checkpoint"
               )

      assert {:ok, events} = EventLog.read(issue)

      assert Enum.any?(events, &(&1["kind"] == "human_checkpoint_requested"))
      refute Enum.any?(events, &(&1["kind"] == "phase_frozen"))

      # The pair loop ran author + reviewer turns before hitting the gate.
      turn_responses = Enum.filter(events, &(&1["kind"] == "turn_response"))
      assert length(turn_responses) == 2
      assert Enum.all?(turn_responses, &(&1["verdict"] == "APPROVE"))

      # Retry dispatch: the gate is still pending so the runner
      # returns the same human_checkpoint error.
      assert {:error, :human_checkpoint} =
               PairRunner.run(issue, self(),
                 turn_driver: SymphonyElixir.Duet.TurnDrivers.Mock,
                 turn_driver_opts: [response: response],
                 tree_hash: "tree-e2e-checkpoint"
               )

      # No new turn events should have been appended; the runner
      # detected the pending gate on re-entry.
      assert {:ok, retry_events} = EventLog.read(issue)
      retry_turn_responses = Enum.filter(retry_events, &(&1["kind"] == "turn_response"))
      assert length(retry_turn_responses) == 2
    after
      File.rm_rf(test_root)
    end
  end

  # ── Test 4 ──────────────────────────────────────────────────────

  defmodule MockGhCliRunner do
    @behaviour SymphonyElixir.Duet.GhCli.Runner

    @impl SymphonyElixir.Duet.GhCli.Runner
    def run(args, opts) do
      test_pid = opts[:test_pid] || self()
      send(test_pid, {:gh_cli_invoked, args, opts})

      case List.first(args) do
        "pr" -> pr_response(args)
        _ -> {:ok, ""}
      end
    end

    defp pr_response(["pr", "create" | _]), do: {:ok, "https://github.com/test/repo/pull/42"}
    defp pr_response(_args), do: {:ok, ""}
  end

  defmodule MockBranchRunner do
    @behaviour SymphonyElixir.Duet.BranchHarness.Runner

    @impl SymphonyElixir.Duet.BranchHarness.Runner
    def run(args, opts) do
      test_pid = opts[:test_pid] || self()
      send(test_pid, {:branch_invoked, args, opts})

      case args do
        ["rev-parse", "--verify" | _] -> {:error, {:exit_status, 128, "not found"}}
        ["worktree", "list" | _] -> {:ok, ""}
        ["worktree", "add", path | _] -> File.mkdir_p!(path) && {:ok, ""}
        _ -> {:ok, ""}
      end
    end
  end

  @tag :e2e
  test "full lifecycle with side_effects wires branch and PR operations" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-e2e-duet-side-effects-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        poll_interval_ms: 60_000,
        duet_yaml: """
        duet:
          enabled: true
        """
      )

      issue = %Issue{
        id: "issue-e2e-side-effects",
        identifier: "E2E-SIDE-FX",
        title: "Side effects lifecycle",
        description: "Verify branch + PR operations during pair loop",
        state: "In Progress",
        url: "https://example.org/issues/E2E-SIDE-FX"
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
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
        tree_hash_provider: fn _ws, phase, _cycle, _actor -> "tree-#{phase}" end,
        side_effects: true,
        branch_runner: MockBranchRunner,
        gh_runner: MockGhCliRunner
      ]

      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)
      assert :ok = PairRunner.run(issue, self(), opts)

      assert {:ok, events} = EventLog.read(issue)

      # All four phases should be frozen.
      frozen = Enum.filter(events, &(&1["kind"] == "phase_frozen"))
      assert length(frozen) == 4
      assert Enum.map(frozen, & &1["phase"]) == ["SPEC", "PLAN", "CODE", "REVIEW"]

      # Base branch created at task start.
      assert_received {:branch_invoked, ["rev-parse", "--verify", "refs/heads/duet-base/issue-e2e-side-effects"], _}
      assert_received {:branch_invoked, ["branch", "duet-base/issue-e2e-side-effects", "main"], _}

      # Phase branches created for SPEC, PLAN, CODE (not REVIEW).
      assert_received {:branch_invoked, ["rev-parse", "--verify", "refs/heads/duet-phase/issue-e2e-side-effects/spec"], _}

      assert_received {:branch_invoked, ["rev-parse", "--verify", "refs/heads/duet-phase/issue-e2e-side-effects/plan"], _}

      assert_received {:branch_invoked, ["rev-parse", "--verify", "refs/heads/duet-phase/issue-e2e-side-effects/code"], _}

      # PR opened events recorded for each phase.
      pr_events = Enum.filter(events, &(&1["kind"] == "pr_opened"))
      pr_phases = Enum.map(pr_events, & &1["phase"])
      assert "SPEC" in pr_phases
      assert "PLAN" in pr_phases
      assert "CODE" in pr_phases

      # Freeze actions recorded.
      freeze_actions = Enum.filter(events, &(&1["kind"] == "freeze_action_executed"))
      action_names = Enum.map(freeze_actions, & &1["action"])
      assert "merge_phase_pr_into_base" in action_names
      assert "delete_phase_sub_branch" in action_names
      assert "merge_code_pr_into_base" in action_names
      assert "merge_base_branch" in action_names

      # task_completed emitted.
      assert Enum.any?(events, &(&1["kind"] == "task_completed"))
    after
      File.rm_rf(test_root)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

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
end
