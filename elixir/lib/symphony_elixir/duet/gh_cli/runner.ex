defmodule SymphonyElixir.Duet.GhCli.Runner do
  @moduledoc """
  Behaviour for executing `gh` CLI commands. The default implementation
  shells out to the real `gh` binary; tests inject a mock module that
  returns canned `{:ok, stdout}` or `{:error, reason}` tuples.

  Implementations receive the fully-built `gh` argv (without the leading
  `gh`) plus a keyword list of runner-side options (`:cwd`, env vars,
  ...). They must return `{:ok, stdout}` on success and
  `{:error, reason}` otherwise. Reason terms are opaque to callers: the
  `SymphonyElixir.Duet.GhCli` wrapper propagates them verbatim so the
  orchestrator can inspect them when applying its retry / backoff
  policy per spec §11.

  This behaviour deliberately mirrors the `TurnDriver` /
  `TurnDrivers.Mock` shape used elsewhere in Duet so callers can swap
  implementations through a single keyword option. It does NOT couple
  to `System.cmd/3` semantics; alternate implementations (in-process
  fakes, HTTP-only callers, distributed runners) are free to fulfil the
  contract any way they like.
  """

  @type args :: [String.t()]
  @type opts :: keyword()
  @type result :: {:ok, String.t()} | {:error, term()}

  @callback run(args(), opts()) :: result()
end
