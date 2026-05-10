defmodule SymphonyElixir.Duet.NotificationHook.Runner do
  @moduledoc """
  Behaviour for executing Duet notification hooks.
  Implementations include the default no-op `NullRunner` and (in future
  slices) Slack / HTTP / exec runners.
  """

  @type event_kind :: atom()
  @type payload :: map()
  @type opts :: keyword()
  @type result :: :ok | {:error, term()}

  @callback dispatch(event_kind(), payload(), opts()) :: result()
end
