defmodule SymphonyElixir.DuetBranchHarnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.BranchHarness

  defmodule MockRunner do
    @moduledoc false
    @behaviour SymphonyElixir.Duet.BranchHarness.Runner

    @impl SymphonyElixir.Duet.BranchHarness.Runner
    def run(args, opts) do
      send(self(), {:git_invoked, args, opts})

      case Process.get(:git_responses) do
        [response | rest] ->
          Process.put(:git_responses, rest)
          response

        [] ->
          {:ok, ""}

        nil ->
          {:ok, ""}
      end
    end
  end

  defp put_responses(responses) when is_list(responses) do
    Process.put(:git_responses, responses)
  end

  defp put_response(response), do: put_responses([response])

  defp base_opts(extra \\ []) do
    Keyword.merge([cwd: "/tmp/ws", runner: MockRunner], extra)
  end

  # ── ensure_base_branch ────────────────────────────────────────────

  describe "ensure_base_branch/2" do
    test "creates the branch from main when it does not exist" do
      # rev-parse fails (branch missing), then git branch succeeds
      put_responses([
        {:error, {:exit_status, 128, "not a valid ref"}},
        {:ok, ""}
      ])

      assert :ok = BranchHarness.ensure_base_branch("my-task", base_opts())

      assert_received {:git_invoked, ["rev-parse", "--verify", "refs/heads/duet-base/my-task"], _opts}

      assert_received {:git_invoked, ["branch", "duet-base/my-task", "main"], _opts}
    end

    test "skips creation when the branch already exists" do
      put_response({:ok, "abc123\n"})

      assert :ok = BranchHarness.ensure_base_branch("my-task", base_opts())

      assert_received {:git_invoked, ["rev-parse", "--verify", "refs/heads/duet-base/my-task"], _opts}

      refute_received {:git_invoked, ["branch" | _], _}
    end

    test "uses custom :base_ref when provided" do
      put_responses([
        {:error, {:exit_status, 128, "not a valid ref"}},
        {:ok, ""}
      ])

      assert :ok =
               BranchHarness.ensure_base_branch(
                 "my-task",
                 base_opts(base_ref: "develop")
               )

      assert_received {:git_invoked, ["branch", "duet-base/my-task", "develop"], _opts}
    end

    test "returns {:error, :invalid_task_id} for bad task ids" do
      assert {:error, :invalid_task_id} =
               BranchHarness.ensure_base_branch("AB", base_opts())
    end

    test "returns {:error, {:missing_opt, :cwd}} without :cwd" do
      assert {:error, {:missing_opt, :cwd}} =
               BranchHarness.ensure_base_branch("my-task", runner: MockRunner)
    end

    test "propagates runner failure from rev-parse" do
      put_response({:error, :git_not_found})

      assert {:error, :git_not_found} =
               BranchHarness.ensure_base_branch("my-task", base_opts())
    end

    test "propagates runner failure from branch creation" do
      put_responses([
        {:error, {:exit_status, 128, "not a valid ref"}},
        {:error, {:exit_status, 1, "fatal: cannot create"}}
      ])

      assert {:error, {:exit_status, 1, "fatal: cannot create"}} =
               BranchHarness.ensure_base_branch("my-task", base_opts())
    end
  end

  # ── ensure_phase_branch ───────────────────────────────────────────

  describe "ensure_phase_branch/3" do
    test "creates the phase branch from base when it does not exist" do
      put_responses([
        {:error, {:exit_status, 128, "not a valid ref"}},
        {:ok, ""}
      ])

      assert :ok = BranchHarness.ensure_phase_branch("my-task", "SPEC", base_opts())

      assert_received {:git_invoked, ["rev-parse", "--verify", "refs/heads/duet-phase/my-task/spec"], _opts}

      assert_received {:git_invoked, ["branch", "duet-phase/my-task/spec", "duet-base/my-task"], _opts}
    end

    test "skips creation when the phase branch already exists" do
      put_response({:ok, "abc123\n"})

      assert :ok = BranchHarness.ensure_phase_branch("my-task", "PLAN", base_opts())

      assert_received {:git_invoked, ["rev-parse", "--verify", "refs/heads/duet-phase/my-task/plan"], _opts}

      refute_received {:git_invoked, ["branch" | _], _}
    end

    test "returns :ok immediately for REVIEW (no branch)" do
      assert :ok = BranchHarness.ensure_phase_branch("my-task", "REVIEW", base_opts())

      refute_received {:git_invoked, _, _}
    end

    test "returns {:error, :invalid_task_id} for bad task ids" do
      assert {:error, :invalid_task_id} =
               BranchHarness.ensure_phase_branch("AB", "SPEC", base_opts())
    end

    test "propagates runner failure" do
      put_response({:error, :git_not_found})

      assert {:error, :git_not_found} =
               BranchHarness.ensure_phase_branch("my-task", "CODE", base_opts())
    end
  end

  # ── merge_phase_into_base ─────────────────────────────────────────

  describe "merge_phase_into_base/3" do
    test "checks out target then merges phase branch into base with --no-ff" do
      put_responses([{:ok, ""}, {:ok, ""}])

      assert :ok = BranchHarness.merge_phase_into_base("my-task", "SPEC", base_opts())

      assert_received {:git_invoked, ["checkout", "duet-base/my-task"], _opts}

      assert_received {:git_invoked, merge_args, _opts}

      assert merge_args == [
               "merge",
               "--no-ff",
               "-m",
               "Merge duet-phase/my-task/spec into duet-base/my-task",
               "duet-phase/my-task/spec"
             ]
    end

    test "works for PLAN phase" do
      put_responses([{:ok, ""}, {:ok, ""}])

      assert :ok = BranchHarness.merge_phase_into_base("my-task", "PLAN", base_opts())

      assert_received {:git_invoked, ["checkout", "duet-base/my-task"], _opts}
      assert_received {:git_invoked, merge_args, _opts}
      assert Enum.member?(merge_args, "duet-phase/my-task/plan")
    end

    test "returns {:error, :invalid_phase} for REVIEW" do
      assert {:error, :invalid_phase} =
               BranchHarness.merge_phase_into_base("my-task", "REVIEW", base_opts())
    end

    test "returns {:error, :invalid_task_id} for bad task ids" do
      assert {:error, :invalid_task_id} =
               BranchHarness.merge_phase_into_base("AB", "SPEC", base_opts())
    end

    test "propagates checkout failure before merge" do
      put_response({:error, {:exit_status, 1, "checkout failed"}})

      assert {:error, {:exit_status, 1, "checkout failed"}} =
               BranchHarness.merge_phase_into_base("my-task", "SPEC", base_opts())

      refute_received {:git_invoked, ["merge" | _], _}
    end

    test "propagates merge failure after successful checkout" do
      put_responses([
        {:ok, ""},
        {:error, {:exit_status, 1, "merge conflict"}}
      ])

      assert {:error, {:exit_status, 1, "merge conflict"}} =
               BranchHarness.merge_phase_into_base("my-task", "SPEC", base_opts())
    end
  end

  # ── merge_base_into_main ──────────────────────────────────────────

  describe "merge_base_into_main/2" do
    test "checks out main then merges base branch with --no-ff" do
      put_responses([{:ok, ""}, {:ok, ""}])

      assert :ok = BranchHarness.merge_base_into_main("my-task", base_opts())

      assert_received {:git_invoked, ["checkout", "main"], _opts}

      assert_received {:git_invoked, merge_args, _opts}

      assert merge_args == [
               "merge",
               "--no-ff",
               "-m",
               "Merge duet-base/my-task into main",
               "duet-base/my-task"
             ]
    end

    test "checks out custom :target when provided" do
      put_responses([{:ok, ""}, {:ok, ""}])

      assert :ok =
               BranchHarness.merge_base_into_main("my-task", base_opts(target: "develop"))

      assert_received {:git_invoked, ["checkout", "develop"], _opts}

      assert_received {:git_invoked, merge_args, _opts}

      assert merge_args == [
               "merge",
               "--no-ff",
               "-m",
               "Merge duet-base/my-task into develop",
               "duet-base/my-task"
             ]
    end

    test "returns {:error, :invalid_task_id} for bad task ids" do
      assert {:error, :invalid_task_id} =
               BranchHarness.merge_base_into_main("AB", base_opts())
    end

    test "propagates checkout failure" do
      put_response({:error, {:exit_status, 1, "checkout failed"}})

      assert {:error, {:exit_status, 1, "checkout failed"}} =
               BranchHarness.merge_base_into_main("my-task", base_opts())

      refute_received {:git_invoked, ["merge" | _], _}
    end

    test "propagates merge failure after checkout" do
      put_responses([
        {:ok, ""},
        {:error, {:exit_status, 1, "merge conflict"}}
      ])

      assert {:error, {:exit_status, 1, "merge conflict"}} =
               BranchHarness.merge_base_into_main("my-task", base_opts())
    end
  end

  # ── phase_workspace ───────────────────────────────────────────────

  describe "phase_workspace/3" do
    test "creates a worktree and returns the path when it does not exist" do
      # worktree list returns nothing relevant, then worktree add succeeds
      put_responses([
        {:ok, "worktree /other/path\n"},
        {:ok, ""}
      ])

      assert {:ok, path} =
               BranchHarness.phase_workspace("my-task", "SPEC", base_opts())

      assert String.ends_with?(path, ".duet-worktrees/my-task/spec")

      assert_received {:git_invoked, ["worktree", "list", "--porcelain"], _opts}
      assert_received {:git_invoked, ["worktree", "add", ^path, "duet-phase/my-task/spec"], _opts}
    end

    test "returns existing worktree path without creating" do
      cwd = "/tmp/ws"
      phase_lower = "plan"
      worktree_abs = Path.expand(Path.join([cwd, "..", ".duet-worktrees", "my-task", phase_lower]))

      put_response({:ok, "worktree #{worktree_abs}\n"})

      assert {:ok, ^worktree_abs} =
               BranchHarness.phase_workspace("my-task", "PLAN", base_opts())

      assert_received {:git_invoked, ["worktree", "list", "--porcelain"], _opts}
      refute_received {:git_invoked, ["worktree", "add" | _], _}
    end

    test "returns {:error, :invalid_phase} for REVIEW" do
      assert {:error, :invalid_phase} =
               BranchHarness.phase_workspace("my-task", "REVIEW", base_opts())
    end

    test "propagates runner failure" do
      put_response({:error, :git_not_found})

      assert {:error, :git_not_found} =
               BranchHarness.phase_workspace("my-task", "SPEC", base_opts())
    end
  end

  # ── cleanup_phase_branch ──────────────────────────────────────────

  describe "cleanup_phase_branch/3" do
    test "removes worktree and deletes the branch" do
      # worktree remove succeeds, then branch -D succeeds
      put_responses([
        {:ok, ""},
        {:ok, ""}
      ])

      assert :ok = BranchHarness.cleanup_phase_branch("my-task", "SPEC", base_opts())

      cwd = "/tmp/ws"
      worktree_abs = Path.expand(Path.join([cwd, "..", ".duet-worktrees", "my-task", "spec"]))

      assert_received {:git_invoked, ["worktree", "remove", "--force", ^worktree_abs], _opts}

      assert_received {:git_invoked, ["branch", "-D", "duet-phase/my-task/spec"], _opts}
    end

    test "returns {:error, :invalid_phase} for REVIEW" do
      assert {:error, :invalid_phase} =
               BranchHarness.cleanup_phase_branch("my-task", "REVIEW", base_opts())
    end

    test "propagates worktree removal failure" do
      put_response({:error, {:exit_status, 128, "not a worktree"}})

      assert {:error, {:exit_status, 128, "not a worktree"}} =
               BranchHarness.cleanup_phase_branch("my-task", "SPEC", base_opts())
    end

    test "propagates branch deletion failure" do
      put_responses([
        {:ok, ""},
        {:error, {:exit_status, 1, "branch not found"}}
      ])

      assert {:error, {:exit_status, 1, "branch not found"}} =
               BranchHarness.cleanup_phase_branch("my-task", "SPEC", base_opts())
    end
  end

  # ── runner/1 ──────────────────────────────────────────────────────

  describe "runner/1" do
    test "defaults to SystemRunner" do
      assert BranchHarness.runner([]) ==
               SymphonyElixir.Duet.BranchHarness.SystemRunner

      assert BranchHarness.runner() ==
               SymphonyElixir.Duet.BranchHarness.SystemRunner
    end

    test "honors :runner opt as the highest-priority override" do
      assert BranchHarness.runner(runner: MockRunner) == MockRunner
    end

    test "honors application env when no opt is supplied" do
      Application.put_env(:symphony_elixir, :duet_branch_harness_runner, MockRunner)
      assert BranchHarness.runner([]) == MockRunner
    after
      Application.delete_env(:symphony_elixir, :duet_branch_harness_runner)
    end
  end

  # ── cwd forwarding ────────────────────────────────────────────────

  describe "cwd forwarding" do
    test ":cwd is forwarded to the runner" do
      put_response({:ok, "abc123\n"})

      :ok = BranchHarness.ensure_base_branch("my-task", base_opts(cwd: "/custom/path"))

      assert_received {:git_invoked, _args, opts}
      assert opts[:cwd] == "/custom/path"
    end
  end
end
