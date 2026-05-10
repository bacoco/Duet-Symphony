defmodule SymphonyElixir.Duet.BranchHarness.SystemRunner do
  @moduledoc """
  Default `SymphonyElixir.Duet.BranchHarness.Runner` implementation that
  shells out to `git` via `System.cmd/3`.

  Returns `{:ok, stdout}` when `git` exits with status 0; otherwise
  returns `{:error, {:exit_status, status, output}}` so the caller can
  log / retry based on the exact failure. When `git` is not installed
  the runner returns `{:error, :git_not_found}` rather than letting the
  underlying `:enoent` raise.

  Honors a `:cwd` option to set the working directory; this is critical
  for Duet because each task's branch operations must run inside its
  isolated workspace per spec S6.
  """

  @behaviour SymphonyElixir.Duet.BranchHarness.Runner

  @impl SymphonyElixir.Duet.BranchHarness.Runner
  @spec run(
          SymphonyElixir.Duet.BranchHarness.Runner.args(),
          SymphonyElixir.Duet.BranchHarness.Runner.opts()
        ) :: SymphonyElixir.Duet.BranchHarness.Runner.result()
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

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
