defmodule SymphonyElixir.Duet.ToolProfile do
  @moduledoc """
  Resolves and validates spec §7.8 tool-profile constraints.

  Operates on the raw `tool_profiles` config map (mirrors the §7.8 YAML
  shape). Per spec §17, the implementation-defined tool identifier set
  for this port is enumerated by `known_tools/0`.

  This slice provides resolution and validation only. Wiring the
  resolved tool list into runtime sandbox policy / prompt injection is
  a separate orchestrator slice.
  """

  @known_tools ~w(file_read file_write git_diff git_push shell shell_readonly web_search)
  @phases ~w(spec plan code review)
  @code_roles ~w(author reviewer)
  @review_roles ~w(coder_ack reviewer)

  @type tool :: String.t()
  @type role :: String.t()
  @type phase :: String.t()
  @type tools_or_all :: :all | [tool()]
  @type config :: map()

  @doc """
  Returns the implementation-defined set of recognized tool identifiers.
  """
  @spec known_tools() :: [tool()]
  def known_tools, do: @known_tools

  @doc """
  Returns whether the tool-profile feature is enabled for this configuration.
  """
  @spec enabled?(config()) :: boolean()
  def enabled?(tool_profiles_config) when is_map(tool_profiles_config) do
    normalized = normalize_keys(tool_profiles_config)
    Map.get(normalized, "enabled", false) == true
  end

  @doc """
  Resolves the active profile name from `default_profile`, defaulting to `"default"`
  when the field is absent.
  """
  @spec default_profile_name(config()) :: String.t()
  def default_profile_name(tool_profiles_config) when is_map(tool_profiles_config) do
    tool_profiles_config
    |> normalize_keys()
    |> Map.get("default_profile", "default")
  end

  @doc """
  Resolves the allowed tools for one (profile, phase, role) tuple.

  - Returns `:all` when:
    - the feature is disabled, OR
    - the profile/phase/role triple resolves to `"all"` (string) or `:all` (atom), OR
    - the triple is missing (no constraint declared — default unrestricted).
  - Returns a sorted list of tool strings when an explicit list is configured.
  - Returns `{:error, reason}` when:
    - the named profile does not exist in `profiles`,
    - the phase is not one of `["spec", "plan", "code", "review"]`,
    - the role is invalid for the phase,
    - the configured tool list contains an unknown identifier.
  """
  @spec resolve(config(), String.t(), phase(), role()) ::
          {:ok, tools_or_all()} | {:error, term()}
  def resolve(tool_profiles_config, profile_name, phase, role)
      when is_map(tool_profiles_config) and is_binary(profile_name) do
    normalized = normalize_keys(tool_profiles_config)
    phase_str = stringify_lower(phase)
    role_str = stringify_lower(role)

    cond do
      not enabled?(tool_profiles_config) ->
        {:ok, :all}

      phase_str not in @phases ->
        {:error, {:invalid_phase, phase_str}}

      not valid_role_for_phase?(phase_str, role_str) ->
        {:error, {:invalid_role, profile_name, phase_str, role_str}}

      true ->
        resolve_in_profile(normalized, profile_name, phase_str, role_str)
    end
  end

  @doc """
  Returns `true` when the named tool is allowed under (profile, phase, role).
  Equivalent to `resolve/4 == :all` OR `tool in resolved_list`.
  """
  @spec allows?(config(), String.t(), phase(), role(), tool()) :: boolean()
  def allows?(tool_profiles_config, profile_name, phase, role, tool) do
    case resolve(tool_profiles_config, profile_name, phase, role) do
      {:ok, :all} -> true
      {:ok, tools} when is_list(tools) -> tool in tools
      {:error, _reason} -> false
    end
  end

  @doc """
  Validates the structure of a `tool_profiles` config map. Returns `:ok`
  or `{:error, message}` describing the first offending field.
  """
  @spec validate_config(config()) :: :ok | {:error, String.t()}
  def validate_config(tool_profiles_config) when is_map(tool_profiles_config) do
    normalized = normalize_keys(tool_profiles_config)

    with :ok <- validate_enabled(normalized),
         :ok <- validate_default_profile(normalized),
         :ok <- validate_profiles(normalized) do
      :ok
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def validate_config(_tool_profiles_config), do: {:error, "tool_profiles must be a map"}

  defp resolve_in_profile(normalized, profile_name, phase_str, role_str) do
    profiles = Map.get(normalized, "profiles", %{})

    case Map.fetch(profiles, profile_name) do
      :error ->
        {:error, {:unknown_profile, profile_name}}

      {:ok, raw_profile} when is_map(raw_profile) ->
        phase_map = Map.get(normalize_keys(raw_profile), phase_str)
        resolve_role_value(profile_name, phase_str, role_str, phase_map)

      {:ok, _other} ->
        {:error, {:profile_not_map, profile_name}}
    end
  end

  defp resolve_role_value(_profile_name, _phase, _role, nil), do: {:ok, :all}

  defp resolve_role_value(profile_name, phase, role, phase_map) when is_map(phase_map) do
    case Map.fetch(phase_map, role) do
      :error -> {:ok, :all}
      {:ok, value} -> coerce_tools(profile_name, phase, role, value)
    end
  end

  defp resolve_role_value(profile_name, phase, _role, _phase_map),
    do: {:error, {:phase_not_map, profile_name, phase}}

  defp coerce_tools(_profile_name, _phase, _role, :all), do: {:ok, :all}
  defp coerce_tools(_profile_name, _phase, _role, "all"), do: {:ok, :all}

  defp coerce_tools(profile_name, phase, role, tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case validate_tool(profile_name, phase, role, tool) do
        {:ok, tool_str} -> {:cont, {:ok, [tool_str | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coerce_tools(profile_name, phase, role, _other),
    do: {:error, {:invalid_tools_value, profile_name, phase, role}}

  defp validate_tool(profile_name, phase, role, tool) do
    tool_str = if is_atom(tool), do: Atom.to_string(tool), else: tool

    cond do
      not is_binary(tool_str) ->
        {:error, {:invalid_tool_type, profile_name, phase, role, tool}}

      tool_str not in @known_tools ->
        {:error, {:unknown_tool, profile_name, phase, role, tool_str}}

      true ->
        {:ok, tool_str}
    end
  end

  defp valid_role_for_phase?(phase, role) when phase in ~w(spec plan code), do: role in @code_roles
  defp valid_role_for_phase?("review", role), do: role in @review_roles
  defp valid_role_for_phase?(_phase, _role), do: false

  defp validate_enabled(normalized) do
    case Map.fetch(normalized, "enabled") do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, other} ->
        {:error, "tool_profiles.enabled must be a boolean (got #{inspect(other)})"}
    end
  end

  defp validate_default_profile(normalized) do
    case Map.fetch(normalized, "default_profile") do
      :error ->
        :ok

      {:ok, name} when is_binary(name) ->
        if Map.get(normalized, "enabled", false) == true and
             not Map.has_key?(Map.get(normalized, "profiles", %{}), name) do
          {:error, "tool_profiles.default_profile #{inspect(name)} is not declared in tool_profiles.profiles"}
        else
          :ok
        end

      {:ok, other} ->
        {:error, "tool_profiles.default_profile must be a string (got #{inspect(other)})"}
    end
  end

  defp validate_profiles(normalized) do
    case Map.fetch(normalized, "profiles") do
      :error -> :ok
      {:ok, profiles} when is_map(profiles) -> validate_profiles_map(profiles)
      {:ok, other} -> {:error, "tool_profiles.profiles must be a map (got #{inspect(other)})"}
    end
  end

  defp validate_profiles_map(profiles) do
    Enum.reduce_while(profiles, :ok, fn {name, raw_profile}, :ok ->
      case validate_profile(name, raw_profile) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  defp validate_profile(name, raw_profile) when is_map(raw_profile) do
    Enum.reduce_while(raw_profile, :ok, fn {phase_key, phase_value}, :ok ->
      validate_profile_phase(name, phase_key, phase_value)
    end)
  end

  defp validate_profile(name, _raw_profile),
    do: {:error, "tool_profiles.profiles.#{name} must be a map"}

  defp validate_profile_phase(name, phase_key, phase_value) do
    phase_str = stringify_lower(phase_key)

    cond do
      phase_str not in @phases ->
        {:halt, {:error, "tool_profiles.profiles.#{name} declares unknown phase #{inspect(phase_key)}"}}

      not is_map(phase_value) ->
        {:halt, {:error, "tool_profiles.profiles.#{name}.#{phase_str} must be a map"}}

      true ->
        case validate_phase_roles(name, phase_str, phase_value) do
          :ok -> {:cont, :ok}
          {:error, msg} -> {:halt, {:error, msg}}
        end
    end
  end

  defp validate_phase_roles(profile_name, phase, phase_map) do
    expected_roles = roles_for_phase(phase)

    Enum.reduce_while(phase_map, :ok, fn {role_key, role_value}, :ok ->
      validate_phase_role_entry(profile_name, phase, expected_roles, role_key, role_value)
    end)
  end

  defp validate_phase_role_entry(profile_name, phase, expected_roles, role_key, role_value) do
    role_str = stringify_lower(role_key)

    if role_str in expected_roles do
      case validate_role_value(profile_name, phase, role_str, role_value) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    else
      {:halt,
       {:error,
        "tool_profiles.profiles.#{profile_name}.#{phase} declares unknown role #{inspect(role_key)} " <>
          "(expected one of #{inspect(expected_roles)})"}}
    end
  end

  defp validate_role_value(_profile_name, _phase, _role, :all), do: :ok
  defp validate_role_value(_profile_name, _phase, _role, "all"), do: :ok

  defp validate_role_value(profile_name, phase, role, value) when is_list(value) do
    Enum.reduce_while(value, :ok, fn tool, :ok ->
      case validate_tool(profile_name, phase, role, tool) do
        {:ok, _tool_str} ->
          {:cont, :ok}

        {:error, {:unknown_tool, _, _, _, tool_str}} ->
          {:halt,
           {:error,
            "tool_profiles.profiles.#{profile_name}.#{phase}.#{role} contains unknown tool " <>
              "#{inspect(tool_str)} (allowed: #{inspect(@known_tools)})"}}

        {:error, {:invalid_tool_type, _, _, _, raw}} ->
          {:halt,
           {:error,
            "tool_profiles.profiles.#{profile_name}.#{phase}.#{role} entries must be strings " <>
              "(got #{inspect(raw)})"}}
      end
    end)
  end

  defp validate_role_value(profile_name, phase, role, other) do
    {:error,
     "tool_profiles.profiles.#{profile_name}.#{phase}.#{role} must be \"all\" or a list of tool " <>
       "identifiers (got #{inspect(other)})"}
  end

  defp roles_for_phase("review"), do: @review_roles
  defp roles_for_phase(_phase), do: @code_roles

  defp stringify_lower(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  defp stringify_lower(value) when is_binary(value), do: String.downcase(value)
  defp stringify_lower(value), do: value

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {to_string(key), normalize_keys(raw_value)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp format_error(reason), do: "invalid duet.tool_profiles: #{inspect(reason)}"
end
