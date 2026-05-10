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
    cmd_opts = build_cmd_opts(input, opts)

    case System.cmd(executable, args, cmd_opts) do
      {stdout, 0} ->
        {:ok, stdout}

      {output, status} when is_integer(status) ->
        {:error, {:exit_status, status, output}}
    end
  end

  defp build_cmd_opts(input, opts) do
    base = [stderr_to_stdout: true, input: input]

    opts
    |> Keyword.delete(:executable)
    |> Keyword.delete(:extra_args)
    |> Keyword.delete(:model)
    |> Keyword.delete(:resume)
    |> Keyword.delete(:permission_mode)
    |> Keyword.delete(:runner)
    |> maybe_put_cd()
    |> Keyword.merge(base)
  end

  defp maybe_put_cd(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" ->
        opts
        |> Keyword.delete(:cwd)
        |> Keyword.put(:cd, cwd)

      _ ->
        opts
    end
  end
end
