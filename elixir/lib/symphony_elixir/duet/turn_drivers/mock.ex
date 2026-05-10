defmodule SymphonyElixir.Duet.TurnDrivers.Mock do
  @moduledoc """
  Deterministic in-process implementation of
  `SymphonyElixir.Duet.TurnDriver` for tests and stubs.

  Real drivers (Codex, Claude) talk to long-running agent
  runtimes; in tests we want to assert pair-loop behaviour
  without booting either. This mock injects a canned response
  (or canned error) per call, driven entirely from the `opts`
  keyword list passed to `drive_turn/2`. No state is kept
  between calls — each invocation is independent.

  Recognised options:

  * `:response` — when set to a binary, `drive_turn/2` returns
    `{:ok, response}`. This is the common path for happy-path
    pair-loop tests.
  * `:error` — when set (and `:response` is not a binary),
    `drive_turn/2` returns `{:error, reason}` where `reason` is
    the value supplied. Use this to exercise driver-failure
    branches such as event-log emission of `trailer_rejected`.

  When neither key is provided the mock returns
  `{:error, :no_canned_response}` so a missing fixture surfaces
  loudly instead of silently returning empty text.
  """

  @behaviour SymphonyElixir.Duet.TurnDriver

  @impl SymphonyElixir.Duet.TurnDriver
  @spec drive_turn(String.t(), keyword()) :: SymphonyElixir.Duet.TurnDriver.result()
  def drive_turn(prompt, opts) when is_binary(prompt) and is_list(opts) do
    case Keyword.fetch(opts, :response) do
      {:ok, response} when is_binary(response) ->
        {:ok, response}

      _ ->
        case Keyword.fetch(opts, :error) do
          {:ok, reason} -> {:error, reason}
          :error -> {:error, :no_canned_response}
        end
    end
  end
end
