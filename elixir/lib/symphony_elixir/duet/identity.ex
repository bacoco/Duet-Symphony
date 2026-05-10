defmodule SymphonyElixir.Duet.Identity do
  @moduledoc """
  Resolves and validates GitHub identities per Duet actor per spec §9.3.

  This first slice reads identities from environment variables, with optional
  in-process overrides for tests. Wiring `WORKFLOW.md` `duet.agents.<actor>.github_identity`
  fields into `Config.Schema` is a future slice; that schema change is intentionally
  deferred so this module can be exercised standalone today.

  Environment variables:

  - `DUET_CLAUDE_GITHUB_IDENTITY`
  - `DUET_CODEX_GITHUB_IDENTITY`

  In-process overrides (for tests / runtime overrides) are stored under app env:

  - `:duet_claude_github_identity`
  - `:duet_codex_github_identity`
  """

  @env_keys %{
    "claude" => :duet_claude_github_identity,
    "codex" => :duet_codex_github_identity
  }

  @env_var_names %{
    "claude" => "DUET_CLAUDE_GITHUB_IDENTITY",
    "codex" => "DUET_CODEX_GITHUB_IDENTITY"
  }

  @machine_actors ~w(claude codex)

  @type actor :: String.t()
  @type identity :: String.t()
  @type validation_error ::
          {:missing_identity, [actor()]}
          | {:shared_identity, identity()}

  @spec for_actor(actor()) :: {:ok, identity()} | {:error, :missing}
  def for_actor(actor) when is_binary(actor) do
    case Map.fetch(@env_keys, actor) do
      {:ok, app_env_key} ->
        resolve_identity(app_env_key, Map.fetch!(@env_var_names, actor))

      :error ->
        {:error, :missing}
    end
  end

  @doc """
  Sets an in-process override for the given actor's identity. Used by tests
  and by future runtime UI flows. Returns `:ok`.
  """
  @spec set_for_actor(actor(), identity() | nil) :: :ok
  def set_for_actor(actor, identity) when is_binary(actor) do
    case Map.fetch(@env_keys, actor) do
      {:ok, app_env_key} ->
        cond do
          is_nil(identity) ->
            Application.delete_env(:symphony_elixir, app_env_key)
            :ok

          is_binary(identity) ->
            Application.put_env(:symphony_elixir, app_env_key, identity)
            :ok

          true ->
            :ok
        end

      :error ->
        :ok
    end
  end

  @doc """
  Validates that all machine actors (claude and codex) have distinct,
  non-empty identities. Returns `:ok` or `{:error, reason}`.

  - `{:error, {:missing_identity, [actors]}}` when any machine actor has no identity.
  - `{:error, {:shared_identity, value}}` when both machine actors resolve to the same value.
  """
  @spec validate_distinct_machine_identities() :: :ok | {:error, validation_error()}
  def validate_distinct_machine_identities do
    resolved =
      Enum.map(@machine_actors, fn actor ->
        {actor, for_actor(actor)}
      end)

    missing =
      resolved
      |> Enum.filter(fn {_actor, result} -> match?({:error, :missing}, result) end)
      |> Enum.map(fn {actor, _result} -> actor end)

    case missing do
      [_ | _] ->
        {:error, {:missing_identity, missing}}

      [] ->
        identities = Enum.map(resolved, fn {_actor, {:ok, identity}} -> identity end)
        unique = Enum.uniq(identities)

        case {identities, unique} do
          {[first | _rest], [_only_one]} -> {:error, {:shared_identity, first}}
          _ -> :ok
        end
    end
  end

  @doc """
  Returns the list of machine actors covered by the distinct-identity rule.
  """
  @spec machine_actors() :: [actor()]
  def machine_actors, do: @machine_actors

  defp resolve_identity(app_env_key, env_var_name) do
    case Application.get_env(:symphony_elixir, app_env_key) do
      value when is_binary(value) ->
        case normalize(value) do
          nil -> resolve_from_system_env(env_var_name)
          trimmed -> {:ok, trimmed}
        end

      _ ->
        resolve_from_system_env(env_var_name)
    end
  end

  defp resolve_from_system_env(env_var_name) do
    case System.get_env(env_var_name) do
      value when is_binary(value) ->
        case normalize(value) do
          nil -> {:error, :missing}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing}
    end
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
