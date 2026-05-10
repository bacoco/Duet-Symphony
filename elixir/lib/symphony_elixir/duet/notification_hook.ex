defmodule SymphonyElixir.Duet.NotificationHook do
  @moduledoc """
  Spec §11 / §10.4.2 / §10.5 notification hook dispatch.

  The orchestrator calls `dispatch/3` when a task pauses or fails on
  one of the spec-listed reasons. The actual transport is selected by
  the configured runner module; the default `NullRunner` is a no-op.

  Hook events recognized by this module:

  - `:phase_cap_escalation` (spec §10.4.2)
  - `:pathological_disagreement` (spec §10.5)
  - `:code_pr_conflict` (spec §8.3.1)
  - `:state_divergence` (spec §11.1)
  - `:human_checkpoint_timeout` (spec §11 / §8.6)
  - `:verification_timeout` (spec §8.7 with on_timeout=block)
  - `:superpower_artifact_invalid` (spec §8.5 enforce mode at cycle cap)
  - `:bot_integration_missing` (spec §11)

  Runner selection precedence:
  1. The `:runner` option to `dispatch/3`.
  2. `Application.get_env(:symphony_elixir, :duet_notification_hook_runner)`.
  3. `SymphonyElixir.Duet.NotificationHook.NullRunner`.
  """

  alias SymphonyElixir.Duet.NotificationHook.NullRunner

  @hook_events ~w(
    phase_cap_escalation
    pathological_disagreement
    code_pr_conflict
    state_divergence
    human_checkpoint_timeout
    verification_timeout
    superpower_artifact_invalid
    bot_integration_missing
  )a

  @type event_kind :: atom()
  @type payload :: map()
  @type opts :: keyword()

  @doc """
  Returns the canonical list of hook event atoms recognized by `dispatch/3`.
  """
  @spec hook_events() :: [event_kind()]
  def hook_events, do: @hook_events

  @doc """
  Returns `true` if `event_kind` is one of the recognized hook events.
  """
  @spec hook_event?(atom()) :: boolean()
  def hook_event?(event_kind), do: event_kind in @hook_events

  @doc """
  Resolves the active runner module: opts `:runner` > app env > NullRunner.
  """
  @spec runner(opts()) :: module()
  def runner(opts \\ []) do
    case Keyword.get(opts, :runner) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _ ->
        case Application.get_env(:symphony_elixir, :duet_notification_hook_runner) do
          module when is_atom(module) and not is_nil(module) -> module
          _ -> NullRunner
        end
    end
  end

  @doc """
  Dispatches a notification hook for `event_kind` with the given payload.

  Returns the runner's result tuple. Unrecognized event kinds return
  `{:error, {:unknown_event_kind, event_kind}}` without calling the runner.

  Required payload keys depend on the event kind; see the @moduledoc for
  each event's payload shape. This module does NOT enforce the payload
  shape at compile time — runners are free to be permissive.
  """
  @spec dispatch(event_kind(), payload(), opts()) :: :ok | {:error, term()}
  def dispatch(event_kind, payload, opts \\ []) when is_atom(event_kind) and is_map(payload) and is_list(opts) do
    if hook_event?(event_kind) do
      runner_module = runner(opts)
      runner_module.dispatch(event_kind, payload, opts)
    else
      {:error, {:unknown_event_kind, event_kind}}
    end
  end
end
