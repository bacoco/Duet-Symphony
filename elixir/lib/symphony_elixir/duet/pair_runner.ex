defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Placeholder for the future Claude + Codex pair runner.

  Until the pair loop is implemented, `run/3` returns
  `{:error, :not_implemented}` after running the shared workspace lifecycle.
  This means the workspace can be created and hooks can run before the stub
  fails. The orchestrator dispatch wrapper (`SymphonyElixir.Orchestrator`)
  raises a `RuntimeError` when a runner returns an error tuple, which causes
  the issue task to crash and trigger the standard retry policy. Do not enable
  `duet: enabled: true` in a production `WORKFLOW.md` until this stub is
  replaced; every claimed task will crash and exhaust the retry policy
  without producing useful work.
  """

  alias SymphonyElixir.RunnerRuntime

  @spec run(map(), pid() | nil, keyword()) :: {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_stub/5)
  end

  defp run_pair_stub(_workspace, _issue, _update_recipient, _opts, _worker_host) do
    {:error, :not_implemented}
  end
end
