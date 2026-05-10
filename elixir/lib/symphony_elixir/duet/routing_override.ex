defmodule SymphonyElixir.Duet.RoutingOverride do
  @moduledoc """
  Per-task routing overrides on top of the runtime-global `Duet.RoutingSelection`.

  Per spec §13.4, an operator may change the routing profile for a specific
  task after the initial `agent_routing_selected` event has fired. That
  change MUST be recorded as a `routing_override_applied` event in the
  task's event log AND in app env so subsequent `Duet.PairRunner` retries
  for the same task pick up the new profile.

  The per-task override is layered above `Duet.RoutingSelection`:
  - A task with no override falls back to `RoutingSelection.selected_profile_name/1`,
    which itself falls back to `agent_routing.default_profile`.
  - A task with an override uses the override's profile_name even if the
    runtime-global selection differs.

  Stale overrides (referencing a profile that no longer exists in
  `agent_routing.profiles`) are auto-cleared with a warning log on the
  next dispatch, mirroring the `RoutingSelection` orphan-fallback behavior.
  """

  require Logger

  alias SymphonyElixir.Duet.{EventLog, Routing, RoutingSelection}
  alias SymphonyElixir.Linear.Issue

  @env_key :duet_per_task_routing_profile
  @valid_sources ~w(operator_ui operator_api operator_cli routing_menu)a

  @type task_id :: String.t()
  @type source :: :operator_ui | :operator_api | :operator_cli | :routing_menu
  @type duet_settings :: map() | struct()

  @doc """
  Returns the per-task selected profile name, or `nil` if no override is
  set. Returns `nil` (and clears the stored override) when the stored
  profile name no longer exists in `agent_routing.profiles`.
  """
  @spec selected_profile_name_for_task(task_id(), duet_settings()) :: String.t() | nil
  def selected_profile_name_for_task(task_id, duet_settings) when is_binary(task_id) do
    overrides = read_overrides()

    case Map.get(overrides, task_id) do
      nil ->
        nil

      profile_name when is_binary(profile_name) ->
        if profile_known?(duet_settings, profile_name) do
          profile_name
        else
          Logger.warning("Per-task Duet routing override #{inspect(profile_name)} for task #{inspect(task_id)} no longer present in agent_routing.profiles; clearing override")

          clear_for_task(task_id)
          nil
        end
    end
  end

  @doc """
  Resolves the effective profile for the given task: per-task override if
  set, otherwise falls back to `RoutingSelection.resolve/1`.
  """
  @spec resolve_for_task(task_id(), duet_settings()) :: {:ok, Routing.profile()} | {:error, term()}
  def resolve_for_task(task_id, duet_settings) when is_binary(task_id) do
    case selected_profile_name_for_task(task_id, duet_settings) do
      nil -> RoutingSelection.resolve(duet_settings)
      profile_name -> Routing.resolve(duet_settings, profile_name)
    end
  end

  @doc """
  Applies a per-task override:
  1. Validates that `profile_name` exists in `duet_settings.agent_routing.profiles`
     (delegates to `Routing.resolve/2`).
  2. Stores the override in app env keyed by task_id.
  3. Appends a `routing_override_applied` event to the task's event log
     with phase matrix, mode, degraded flag, source, and the previous
     profile name (if any).
  4. Returns `{:ok, applied_profile_struct}`.

  Returns `{:error, reason}` if the profile doesn't exist or the source
  is not in `@valid_sources`. If the event log append fails, the app env
  change is rolled back and `{:error, {:event_log_failed, reason}}` is
  returned.
  """
  @spec apply_override(task_id() | Issue.t() | map(), String.t(), source(), duet_settings()) ::
          {:ok, Routing.profile()} | {:error, term()}
  def apply_override(task_or_issue, profile_name, source, duet_settings) when is_binary(profile_name) do
    with :ok <- validate_source(source),
         {:ok, applied_profile} <- Routing.resolve(duet_settings, profile_name) do
      task_id = task_id(task_or_issue)
      previous_overrides = read_overrides()
      previous_profile_name = Map.get(previous_overrides, task_id)
      next_overrides = Map.put(previous_overrides, task_id, applied_profile.name)

      Application.put_env(:symphony_elixir, @env_key, next_overrides)

      attrs = event_attrs(applied_profile, source, previous_profile_name)

      case EventLog.append(task_or_issue, "routing_override_applied", attrs) do
        {:ok, _event} ->
          {:ok, applied_profile}

        {:error, reason} ->
          Application.put_env(:symphony_elixir, @env_key, previous_overrides)
          {:error, {:event_log_failed, reason}}
      end
    end
  end

  def apply_override(_task_or_issue, _profile_name, _source, _duet_settings) do
    {:error, :missing_profile_name}
  end

  @doc """
  Clears the per-task override. Returns `:ok` (idempotent: clearing an
  already-empty override is a no-op).
  """
  @spec clear_for_task(task_id()) :: :ok
  def clear_for_task(task_id) when is_binary(task_id) do
    overrides = read_overrides()

    case Map.pop(overrides, task_id) do
      {nil, _unchanged} ->
        :ok

      {_removed, %{} = remaining} when map_size(remaining) == 0 ->
        Application.delete_env(:symphony_elixir, @env_key)
        :ok

      {_removed, remaining} ->
        Application.put_env(:symphony_elixir, @env_key, remaining)
        :ok
    end
  end

  @doc """
  Returns the list of task_ids with an active per-task override
  (read from app env). Used by the dashboard to show overrides.
  """
  @spec active_overrides() :: [task_id()]
  def active_overrides do
    read_overrides()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Builds the `routing_override_applied` event payload for a given applied
  profile and source. Exposed so non-event-log callers (e.g. the HTTP API
  that wants to return the same payload as a response) can reuse it.
  """
  @spec event_attrs(Routing.profile(), source(), String.t() | nil) :: map()
  def event_attrs(applied_profile, source, previous_profile_name \\ nil) do
    routing_attrs = Routing.to_event_attrs(applied_profile)

    %{
      profile_name: applied_profile.name,
      mode: applied_profile.mode,
      degraded: applied_profile.degraded?,
      phases: routing_attrs.phases,
      source: Atom.to_string(source),
      previous_profile_name: previous_profile_name
    }
  end

  @doc """
  Returns the canonical list of `source` atoms recognized by
  `apply_override/4`.
  """
  @spec valid_sources() :: [source()]
  def valid_sources, do: @valid_sources

  defp validate_source(source) when source in @valid_sources, do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  defp read_overrides do
    case Application.get_env(:symphony_elixir, @env_key) do
      nil -> %{}
      overrides when is_map(overrides) -> overrides
      _other -> %{}
    end
  end

  defp profile_known?(%{agent_routing: agent_routing}, name), do: profile_known?(agent_routing, name)

  defp profile_known?(agent_routing, name) when is_map(agent_routing) and is_binary(name) do
    agent_routing
    |> normalize_keys()
    |> Map.get("profiles", %{})
    |> Map.has_key?(name)
  end

  defp profile_known?(_agent_routing, _name), do: false

  defp task_id(%Issue{id: id, identifier: identifier}), do: id || identifier
  defp task_id(%{"id" => id, "identifier" => identifier}), do: id || identifier
  defp task_id(%{id: id, identifier: identifier}), do: id || identifier
  defp task_id(task_id) when is_binary(task_id), do: task_id

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value), do: value
end
