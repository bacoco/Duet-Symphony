defmodule SymphonyElixir.RunnerSelectorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.PairRunner
  alias SymphonyElixir.RunnerSelector

  test "selects AgentRunner by default" do
    assert RunnerSelector.choose(Config.settings!()) == AgentRunner
  end

  test "selects PairRunner when duet is enabled" do
    write_workflow_file!(Workflow.workflow_file_path(), duet_enabled: true)

    assert RunnerSelector.choose(Config.settings!()) == PairRunner
  end

  test "PairRunner is a not implemented stub" do
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

      assert {:error, :not_implemented} = PairRunner.run(issue)
      assert {:error, :not_implemented} = PairRunner.run(issue, self())
      assert {:error, :not_implemented} = PairRunner.run(issue, self(), [])
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
    after
      File.rm_rf(test_root)
    end
  end
end
