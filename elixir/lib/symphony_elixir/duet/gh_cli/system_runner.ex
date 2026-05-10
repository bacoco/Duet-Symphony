defmodule SymphonyElixir.Duet.GhCli.SystemRunner do
  @moduledoc """
  Default `SymphonyElixir.Duet.GhCli.Runner` implementation that shells
  out to the `gh` CLI via `System.cmd/3`.

  Returns `{:ok, stdout}` when `gh` exits with status 0; otherwise
  returns `{:error, {:exit_status, status, stderr}}` so the caller can
  log / retry based on the exact failure. When `gh` is not installed
  the runner returns `{:error, :gh_not_found}` rather than letting the
  underlying `:enoent` raise.

  Honors a `:cwd` option to set the working directory; this is critical
  for Duet because each task's GitHub operations must run inside its
  isolated workspace per spec §6. Any additional opts are passed
  through to `System.cmd/3`, which means callers may set `:env` or
  other recognised options without further wrapper changes.

  stdout and stderr are captured into a single combined buffer
  (`stderr_to_stdout: true`). On the success path the JSON / URL output
  produced by `gh` is the only thing on the buffer; on the failure path
  the same buffer holds the human-readable error message that `gh`
  writes to stderr, which is exactly what the orchestrator wants to log
  when applying its retry / backoff policy per spec §11.
  """

  @behaviour SymphonyElixir.Duet.GhCli.Runner

  @impl SymphonyElixir.Duet.GhCli.Runner
  @spec run(SymphonyElixir.Duet.GhCli.Runner.args(), SymphonyElixir.Duet.GhCli.Runner.opts()) ::
          SymphonyElixir.Duet.GhCli.Runner.result()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    case System.find_executable("gh") do
      nil ->
        {:error, :gh_not_found}

      executable ->
        do_run(executable, args, opts)
    end
  end

  defp do_run(executable, args, opts) do
    cmd_opts = build_cmd_opts(opts)

    case System.cmd(executable, args, cmd_opts) do
      {stdout, 0} ->
        {:ok, stdout}

      {output, status} when is_integer(status) ->
        {:error, {:exit_status, status, output}}
    end
  end

  @system_cmd_keys [:cd, :env, :stderr_to_stdout, :parallelism, :into, :lines]

  defp build_cmd_opts(opts) do
    {cwd, rest} = Keyword.pop(opts, :cwd)

    base =
      rest
      |> Keyword.take(@system_cmd_keys)
      |> Keyword.put(:stderr_to_stdout, true)

    if is_binary(cwd), do: Keyword.put(base, :cd, cwd), else: base
  end
end
