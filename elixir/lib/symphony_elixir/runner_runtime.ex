defmodule SymphonyElixir.RunnerRuntime do
  @moduledoc """
  Shared workspace lifecycle wrapper for worker runners.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Workspace}

  @type worker_host :: String.t() | nil
  @type workspace_runner ::
          (Path.t(), map(), pid() | nil, keyword(), worker_host() -> :ok | {:error, term()})

  @spec run(String.t(), map(), pid() | nil, keyword(), workspace_runner()) ::
          :ok | {:error, term()}
  def run(runner_name, issue, update_recipient, opts, workspace_runner)
      when is_binary(runner_name) and is_function(workspace_runner, 5) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting #{runner_name} run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    run_on_worker_host(runner_name, issue, update_recipient, opts, worker_host, workspace_runner)
  end

  defp run_on_worker_host(runner_name, issue, update_recipient, opts, worker_host, workspace_runner) do
    Logger.info("Starting #{runner_name} worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            workspace_runner.(workspace, issue, update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
