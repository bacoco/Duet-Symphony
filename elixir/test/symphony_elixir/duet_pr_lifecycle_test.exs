defmodule SymphonyElixir.DuetPRLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.EventLog
  alias SymphonyElixir.Duet.PRLifecycle

  defmodule MockRunner do
    @moduledoc false
    @behaviour SymphonyElixir.Duet.GhCli.Runner

    @impl SymphonyElixir.Duet.GhCli.Runner
    def run(args, opts) do
      send(self(), {:gh_cli_invoked, args, opts})

      case Process.get(:gh_cli_response) do
        {:ok, _stdout} = ok -> ok
        {:error, _reason} = err -> err
        nil -> {:ok, ""}
      end
    end
  end

  defmodule MockBranchRunner do
    @moduledoc false
    @behaviour SymphonyElixir.Duet.BranchHarness.Runner

    @impl SymphonyElixir.Duet.BranchHarness.Runner
    def run(args, opts) do
      send(self(), {:branch_invoked, args, opts})
      {:ok, ""}
    end
  end

  defp put_response(response), do: Process.put(:gh_cli_response, response)

  defp assert_invoked(expected_args) do
    assert_received {:gh_cli_invoked, ^expected_args, _opts}
  end

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pr-lifecycle-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    EventLog.set_root(Path.join(test_root, ".duet/logs"))

    on_exit(fn ->
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root}
  end

  defp base_ctx(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "test-task-001",
        phase: "SPEC",
        issue_title: "Implement feature X",
        issue_description: "A longer description of the feature.",
        workspace: "/tmp/ws",
        cycle: 1,
        runner: MockRunner
      },
      overrides
    )
  end

  describe "open_phase_pr/1" do
    test "opens PR with correct title/body from Duet.PR and records event" do
      put_response({:ok, "https://github.com/owner/repo/pull/42\n"})

      assert {:ok, 42} = PRLifecycle.open_phase_pr(base_ctx())

      assert_received {:gh_cli_invoked, args, _opts}
      assert Enum.take(args, 2) == ["pr", "create"]
      base_idx = Enum.find_index(args, &(&1 == "--base"))
      assert Enum.at(args, base_idx + 1) == "duet-base/test-task-001"
      head_idx = Enum.find_index(args, &(&1 == "--head"))
      assert Enum.at(args, head_idx + 1) == "duet-phase/test-task-001/spec"
      title_idx = Enum.find_index(args, &(&1 == "--title"))
      assert Enum.at(args, title_idx + 1) == "[duet:test-task-001] SPEC: Implement feature X"
      assert "--body" in args

      assert {:ok, events} = EventLog.read("test-task-001")
      assert [event] = events
      assert event["kind"] == "pr_opened"
      assert event["phase"] == "SPEC"
      assert event["pr_number"] == 42
    end

    test "opens PLAN PR with correct branch names" do
      put_response({:ok, "https://github.com/owner/repo/pull/55\n"})

      assert {:ok, 55} = PRLifecycle.open_phase_pr(base_ctx(%{phase: "PLAN"}))

      assert_received {:gh_cli_invoked, args, _opts}
      assert "--base" in args
      base_idx = Enum.find_index(args, &(&1 == "--base"))
      assert Enum.at(args, base_idx + 1) == "duet-base/test-task-001"

      head_idx = Enum.find_index(args, &(&1 == "--head"))
      assert Enum.at(args, head_idx + 1) == "duet-phase/test-task-001/plan"
    end

    test "opens CODE PR as draft" do
      put_response({:ok, "https://github.com/owner/repo/pull/60\n"})

      assert {:ok, 60} = PRLifecycle.open_phase_pr(base_ctx(%{phase: "CODE"}))

      assert_received {:gh_cli_invoked, args, _opts}
      assert "--draft" in args
    end

    test "REVIEW returns CODE PR number from events" do
      # First, open a CODE PR so we have an event to read
      put_response({:ok, "https://github.com/owner/repo/pull/77\n"})
      assert {:ok, 77} = PRLifecycle.open_phase_pr(base_ctx(%{phase: "CODE"}))

      # Consume the CODE PR creation message
      assert_received {:gh_cli_invoked, ["pr", "create" | _], _}

      # Now open REVIEW — should reuse the CODE PR number
      assert {:ok, 77} = PRLifecycle.open_phase_pr(base_ctx(%{phase: "REVIEW"}))

      # No gh cli invocation for REVIEW
      refute_received {:gh_cli_invoked, ["pr", "create" | _], _}
    end

    test "REVIEW returns error when no CODE PR exists" do
      assert {:error, :code_pr_not_found} =
               PRLifecycle.open_phase_pr(base_ctx(%{phase: "REVIEW"}))
    end

    test "propagates GhCli error" do
      put_response({:error, {:exit_status, 1, "gh: failed"}})

      assert {:error, {:exit_status, 1, "gh: failed"}} =
               PRLifecycle.open_phase_pr(base_ctx())
    end
  end

  describe "post_author_trailer/3" do
    test "posts comment with correct body" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.post_author_trailer(
                 42,
                 "---DUET-TRAILER---\nverdict: proceed",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked([
        "pr",
        "comment",
        "42",
        "--body",
        "---DUET-TRAILER---\nverdict: proceed"
      ])
    end

    test "propagates GhCli error" do
      put_response({:error, {:exit_status, 1, "nope"}})

      assert {:error, {:exit_status, 1, "nope"}} =
               PRLifecycle.post_author_trailer(
                 42,
                 "body",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end
  end

  describe "submit_reviewer_verdict/4" do
    test "submits APPROVE review with mapped event type" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.submit_reviewer_verdict(
                 42,
                 :approve,
                 "LGTM, looks good.",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked([
        "pr",
        "review",
        "42",
        "--approve",
        "--body",
        "LGTM, looks good."
      ])
    end

    test "submits REQUEST_CHANGES review with mapped event type" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.submit_reviewer_verdict(
                 42,
                 :request_changes,
                 "Please fix the tests.",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked([
        "pr",
        "review",
        "42",
        "--request-changes",
        "--body",
        "Please fix the tests."
      ])
    end

    test "propagates GhCli error" do
      put_response({:error, {:exit_status, 1, "review failed"}})

      assert {:error, {:exit_status, 1, "review failed"}} =
               PRLifecycle.submit_reviewer_verdict(
                 42,
                 :approve,
                 "body",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end
  end

  describe "execute_freeze_actions/3" do
    test "SPEC merges phase PR, cleans up branch, and records events" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.execute_freeze_actions(
                 "SPEC",
                 42,
                 cwd: "/tmp/ws",
                 task_id: "test-task-001",
                 runner: MockRunner,
                 branch_runner: MockBranchRunner
               )

      assert_invoked(["pr", "merge", "42", "--merge"])

      assert {:ok, events} = EventLog.read("test-task-001")
      freeze_events = Enum.filter(events, &(&1["kind"] == "freeze_action_executed"))
      actions = Enum.map(freeze_events, & &1["action"])
      assert "merge_phase_pr_into_base" in actions
      assert "delete_phase_sub_branch" in actions
      assert "emit_phase_freeze_message" in actions

      assert_received {:branch_invoked, ["worktree", "remove", "--force", _path], _opts}
    end

    test "PLAN merges phase PR and cleans up branch" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.execute_freeze_actions(
                 "PLAN",
                 50,
                 cwd: "/tmp/ws",
                 task_id: "test-task-001",
                 runner: MockRunner,
                 branch_runner: MockBranchRunner
               )

      assert_invoked(["pr", "merge", "50", "--merge"])
      assert_received {:branch_invoked, ["worktree", "remove", "--force", _path], _opts}
    end

    test "CODE holds PR open (no merge, no mark_ready)" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.execute_freeze_actions(
                 "CODE",
                 60,
                 cwd: "/tmp/ws",
                 task_id: "test-task-001",
                 runner: MockRunner
               )

      # CODE freeze should NOT merge or mark ready
      refute_received {:gh_cli_invoked, ["pr", "merge" | _], _}
      refute_received {:gh_cli_invoked, ["pr", "ready" | _], _}

      assert {:ok, events} = EventLog.read("test-task-001")
      freeze_events = Enum.filter(events, &(&1["kind"] == "freeze_action_executed"))
      actions = Enum.map(freeze_events, & &1["action"])
      assert "hold_open_for_review" in actions
      assert "record_code_tree_hash" in actions
    end

    test "REVIEW marks ready, merges CODE PR, merges base, cleans up branch" do
      put_response({:ok, ""})

      assert :ok =
               PRLifecycle.execute_freeze_actions(
                 "REVIEW",
                 77,
                 cwd: "/tmp/ws",
                 task_id: "test-task-001",
                 runner: MockRunner,
                 branch_runner: MockBranchRunner
               )

      assert_invoked(["pr", "ready", "77"])
      assert_invoked(["pr", "merge", "77", "--merge"])

      assert {:ok, events} = EventLog.read("test-task-001")
      freeze_events = Enum.filter(events, &(&1["kind"] == "freeze_action_executed"))
      actions = Enum.map(freeze_events, & &1["action"])
      assert "mark_code_pr_ready" in actions
      assert "merge_code_pr_into_base" in actions
      assert "merge_base_branch" in actions
      assert "delete_code_sub_branch" in actions
      assert "emit_task_completed" in actions

      assert_received {:branch_invoked, ["checkout", "main"], _opts}
    end

    test "error propagation stops remaining actions" do
      put_response({:error, {:exit_status, 1, "merge failed"}})

      assert {:error, {:exit_status, 1, "merge failed"}} =
               PRLifecycle.execute_freeze_actions(
                 "SPEC",
                 42,
                 cwd: "/tmp/ws",
                 task_id: "test-task-001",
                 runner: MockRunner
               )

      # No freeze_action_executed events should be recorded
      assert {:ok, events} = EventLog.read("test-task-001")
      freeze_events = Enum.filter(events, &(&1["kind"] == "freeze_action_executed"))
      assert freeze_events == []
    end
  end

  describe "resolve_code_pr_number/1" do
    test "finds CODE PR number from event log" do
      EventLog.append("test-task-001", "pr_opened", %{
        phase: "CODE",
        pr_number: 88
      })

      assert {:ok, 88} = PRLifecycle.resolve_code_pr_number(%{task_id: "test-task-001"})
    end

    test "returns error when no CODE PR event exists" do
      EventLog.append("test-task-001", "pr_opened", %{
        phase: "SPEC",
        pr_number: 10
      })

      assert {:error, :code_pr_not_found} =
               PRLifecycle.resolve_code_pr_number(%{task_id: "test-task-001"})
    end

    test "returns error for empty event log" do
      assert {:error, :code_pr_not_found} =
               PRLifecycle.resolve_code_pr_number(%{task_id: "test-task-001"})
    end
  end
end
