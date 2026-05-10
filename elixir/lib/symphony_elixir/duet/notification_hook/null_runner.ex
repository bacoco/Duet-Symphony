defmodule SymphonyElixir.Duet.NotificationHook.NullRunner do
  @moduledoc """
  Default Duet notification-hook runner: a no-op that always returns `:ok`.

  Used when no notification hook is configured. Logs at `:debug` so test
  runs and dev environments don't get spammed but the dispatch trace is
  still visible.
  """

  @behaviour SymphonyElixir.Duet.NotificationHook.Runner
  require Logger

  @impl true
  @spec dispatch(SymphonyElixir.Duet.NotificationHook.Runner.event_kind(), SymphonyElixir.Duet.NotificationHook.Runner.payload(), SymphonyElixir.Duet.NotificationHook.Runner.opts()) ::
          SymphonyElixir.Duet.NotificationHook.Runner.result()
  def dispatch(event_kind, payload, _opts) do
    Logger.debug(fn -> "Duet notification hook (null runner): #{inspect(event_kind)} payload=#{inspect(payload)}" end)
    :ok
  end
end
