defmodule SymphonyElixir.Duet.TurnDrivers.ClaudeCode.SystemRunner do
  @moduledoc """
  Default Claude Code CLI runner for `Duet.TurnDrivers.ClaudeCode`.

  It executes `claude --print --output-format stream-json` with the prompt
  supplied on stdin, from the task workspace. Missing binaries and non-zero
  exits are returned as data so the pair loop can decide whether to retry,
  escalate, or fail.
  """

  @behaviour SymphonyElixir.Duet.TurnDrivers.ClaudeCode.Runner

  alias SymphonyElixir.Duet.TurnDrivers.ClaudeCode.Runner

  @impl Runner
  @spec run(Runner.args(), Runner.input(), Runner.opts()) :: Runner.result()
  def run(args, input, opts \\ []) when is_list(args) and is_binary(input) and is_list(opts) do
    executable = Keyword.get(opts, :executable, "claude")

    case System.find_executable(executable) do
      nil -> {:error, :claude_not_found}
      path -> do_run(path, args, input, opts)
    end
  end

  defp do_run(executable, args, input, opts) do
    port =
      Port.open(
        {:spawn_executable, executable},
        build_port_opts(args, opts)
      )

    send(port, {self(), {:command, input}})
    send(port, {self(), :eof})
    collect_output(port, [])
  end

  defp build_port_opts(args, opts) do
    opts
    |> Keyword.delete(:executable)
    |> Keyword.delete(:extra_args)
    |> Keyword.delete(:model)
    |> Keyword.delete(:resume)
    |> Keyword.delete(:permission_mode)
    |> Keyword.delete(:runner)
    |> Keyword.take([:cwd])
    |> maybe_put_cd()
    |> Kernel.++([:binary, :exit_status, :stderr_to_stdout, args: args])
  end

  defp maybe_put_cd(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" ->
        opts
        |> Keyword.delete(:cwd)
        |> Keyword.put(:cd, String.to_charlist(cwd))

      _ ->
        opts
    end
  end

  defp collect_output(port, chunks) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | chunks])

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
    end
  end
end
