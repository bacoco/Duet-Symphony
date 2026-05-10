defmodule SymphonyElixir.Duet.TurnDrivers.ClaudeCode.Runner do
  @moduledoc """
  Behaviour for invoking the Claude Code CLI.

  The production runner shells out to `claude`; tests inject an in-process
  runner that receives the exact argv, prompt input, and command options.
  """

  @type args :: [String.t()]
  @type input :: String.t()
  @type opts :: keyword()
  @type result :: {:ok, String.t()} | {:error, term()}

  @callback run(args(), input(), opts()) :: result()
end
