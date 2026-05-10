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

  alias SymphonyElixir.Duet.{EventLog, Routing}
  alias SymphonyElixir.RunnerRuntime

  @spec run(map(), pid() | nil, keyword()) :: {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_stub/5)
  end

  defp run_pair_stub(_workspace, issue, _update_recipient, _opts, _worker_host) do
    case emit_agent_routing_selected(issue) do
      {:ok, _event} -> {:error, :not_implemented}
      {:error, reason} -> {:error, {:agent_routing_event_failed, reason}}
    end
  end

  defp emit_agent_routing_selected(issue) do
    with {:ok, profile} <- Routing.resolve(SymphonyElixir.Config.settings!().duet) do
      EventLog.append(issue, "agent_routing_selected", %{
        profile_name: profile.name,
        mode: profile.mode,
        degraded: profile.degraded?,
        phases: profile_phases(profile)
      })
    end
  end

  defp profile_phases(%Routing.Profile{phases: phases}) do
    Map.new(phases, fn {phase, routing} ->
      {phase,
       %{
         author: routing.author,
         reviewers: routing.reviewers,
         coder_ack: routing.coder_ack,
         reviewer: routing.reviewer
       }}
    end)
  end
end
