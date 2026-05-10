defmodule SymphonyElixir.Duet.RoutingSelection do
  @moduledoc """
  Runtime-selected Duet routing profile for operator-supervised dispatch.

  The repository-owned `WORKFLOW.md` remains the source of available profiles.
  This module stores only the operator's current runtime selection.

  When `WORKFLOW.md` is reloaded and the previously-selected profile no longer
  exists, the stale runtime selection is cleared automatically so dispatch
  falls back to the configured default profile rather than crashing on every
  retry.
  """

  require Logger

  alias SymphonyElixir.Duet.Routing

  @env_key :duet_selected_routing_profile
  @phase_order ~w(spec plan code review)

  @type payload :: map()

  @spec selected_profile_name(map() | struct()) :: String.t()
  def selected_profile_name(%{agent_routing: agent_routing}) do
    selected_profile_name(agent_routing)
  end

  def selected_profile_name(agent_routing) when is_map(agent_routing) do
    case Application.get_env(:symphony_elixir, @env_key) do
      nil ->
        default_profile_name(agent_routing)

      selected when is_binary(selected) ->
        if profile_known?(agent_routing, selected) do
          selected
        else
          Logger.warning("Operator-selected Duet profile #{inspect(selected)} no longer present in agent_routing.profiles; reverting to default")
          Application.delete_env(:symphony_elixir, @env_key)
          default_profile_name(agent_routing)
        end
    end
  end

  defp profile_known?(agent_routing, name) when is_binary(name) do
    agent_routing
    |> normalize_keys()
    |> Map.get("profiles", %{})
    |> Map.has_key?(name)
  end

  @spec resolve(map() | struct()) :: {:ok, Routing.profile()} | {:error, term()}
  def resolve(%{agent_routing: _agent_routing} = duet_settings) do
    Routing.resolve(duet_settings, selected_profile_name(duet_settings))
  end

  def resolve(agent_routing) when is_map(agent_routing) do
    Routing.resolve(agent_routing, selected_profile_name(agent_routing))
  end

  @spec select(map() | struct(), String.t() | nil) :: {:ok, payload()} | {:error, term()}
  def select(_duet_settings, profile_name) when not is_binary(profile_name), do: {:error, :missing_profile_name}

  def select(duet_settings, profile_name) do
    profile_name = String.trim(profile_name)

    with {:ok, profile} <- Routing.resolve(duet_settings, profile_name) do
      Application.put_env(:symphony_elixir, @env_key, profile.name)
      payload(duet_settings)
    end
  end

  @spec clear() :: :ok
  def clear do
    Application.delete_env(:symphony_elixir, @env_key)
    :ok
  end

  @spec payload(map() | struct()) :: {:ok, payload()} | {:error, term()}
  def payload(%{agent_routing: agent_routing} = duet_settings) do
    with {:ok, profiles} <- Routing.available_profiles(duet_settings),
         {:ok, effective_profile} <- resolve(duet_settings) do
      {:ok,
       %{
         enabled: Map.get(duet_settings, :enabled, false),
         menu_enabled: menu_enabled?(duet_settings),
         require_selection_before_dispatch: require_selection_before_dispatch?(duet_settings),
         default_profile: default_profile_name(agent_routing),
         selected_profile: effective_profile.name,
         selection_source: selection_source(),
         effective_profile: profile_payload(effective_profile),
         profiles: Enum.map(profiles, &profile_payload/1),
         human_checkpoints: Map.get(duet_settings, :human_checkpoints, %{})
       }}
    end
  end

  def payload(agent_routing) when is_map(agent_routing) do
    with {:ok, profiles} <- Routing.available_profiles(agent_routing),
         {:ok, effective_profile} <- resolve(agent_routing) do
      {:ok,
       %{
         enabled: false,
         menu_enabled: true,
         require_selection_before_dispatch: false,
         default_profile: default_profile_name(agent_routing),
         selected_profile: effective_profile.name,
         selection_source: selection_source(),
         effective_profile: profile_payload(effective_profile),
         profiles: Enum.map(profiles, &profile_payload/1),
         human_checkpoints: %{}
       }}
    end
  end

  defp default_profile_name(agent_routing) do
    agent_routing
    |> normalize_keys()
    |> Map.get("default_profile", "duet_balanced")
  end

  defp menu_enabled?(duet_settings) do
    duet_settings
    |> Map.get(:agent_menu, %{})
    |> normalize_keys()
    |> Map.get("enabled", true)
  end

  defp require_selection_before_dispatch?(duet_settings) do
    duet_settings
    |> Map.get(:agent_menu, %{})
    |> normalize_keys()
    |> Map.get("require_selection_before_dispatch", false)
  end

  defp selection_source do
    if Application.get_env(:symphony_elixir, @env_key), do: "operator", else: "default"
  end

  defp profile_payload(%Routing.Profile{} = profile) do
    %{
      name: profile.name,
      mode: profile.mode,
      degraded: profile.degraded?,
      phases:
        @phase_order
        |> Enum.map(&phase_payload(&1, Map.fetch!(profile.phases, &1)))
    }
  end

  defp phase_payload(phase, routing) do
    %{
      phase: String.upcase(phase),
      author: routing.author,
      reviewers: routing.reviewers,
      coder_ack: routing.coder_ack,
      reviewer: routing.reviewer
    }
  end

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_keys(nested)} end)
  end

  defp normalize_keys(value), do: value
end
