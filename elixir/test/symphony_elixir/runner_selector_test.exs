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
    issue = %Issue{id: "issue-duet", identifier: "DUET-1"}

    assert PairRunner.run(issue, self(), []) == {:error, :not_implemented}
  end
end
