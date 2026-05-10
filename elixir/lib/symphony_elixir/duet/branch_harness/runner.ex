defmodule SymphonyElixir.Duet.BranchHarness.Runner do
  @moduledoc """
  Behaviour for executing `git` CLI commands. The default implementation
  shells out to the real `git` binary; tests inject a mock module that
  returns canned `{:ok, stdout}` or `{:error, reason}` tuples.

  Implementations receive the fully-built `git` argv (without the leading
  `git`) plus a keyword list of runner-side options (`:cwd`, env vars,
  ...). They must return `{:ok, stdout}` on success and
  `{:error, reason}` otherwise. Reason terms are opaque to callers: the
  `SymphonyElixir.Duet.BranchHarness` wrapper propagates them verbatim
  so the orchestrator can inspect them when applying its retry / backoff
  policy per spec S11.

  This behaviour mirrors the `GhCli.Runner` shape used elsewhere in Duet
  so callers can swap implementations through a single keyword option.
  """

  @type args :: [String.t()]
  @type opts :: keyword()
  @type result :: {:ok, String.t()} | {:error, term()}

  @callback run(args(), opts()) :: result()
end
