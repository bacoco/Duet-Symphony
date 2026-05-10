defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Placeholder for the future Claude + Codex pair runner.

  Until the pair loop is implemented, `run/3` returns
  `{:error, :not_implemented}`. The orchestrator dispatch wrapper
  (`SymphonyElixir.Orchestrator`) raises a `RuntimeError` when a runner
  returns an error tuple, which causes the issue task to crash and trigger
  the standard retry policy. Do not enable `duet: enabled: true` in a
  production `WORKFLOW.md` until this stub is replaced — every claimed task
  will crash and exhaust the retry policy without producing useful work.
  """

  @spec run(map(), pid() | nil, keyword()) :: {:error, :not_implemented}
  def run(_issue, _update_recipient \\ nil, _opts \\ []) do
    {:error, :not_implemented}
  end
end
