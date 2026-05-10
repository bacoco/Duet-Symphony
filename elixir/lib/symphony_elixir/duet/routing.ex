defmodule SymphonyElixir.Duet.Routing do
  @moduledoc """
  Resolves and validates Duet agent routing profiles.
  """

  @phases ~w(spec plan code review)
  @modes ~w(full_duet degraded_single_agent)
  @actors ~w(claude codex human none code_author non_coder)
  @machine_actors ~w(claude codex)

  defmodule Phase do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            author: String.t() | nil,
            reviewers: [String.t()],
            coder_ack: String.t() | nil,
            reviewer: String.t() | nil
          }

    defstruct [:name, :author, reviewers: [], coder_ack: nil, reviewer: nil]
  end

  defmodule Profile do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            mode: String.t(),
            degraded?: boolean(),
            phases: %{String.t() => Phase.t()}
          }

    defstruct [:name, :mode, degraded?: true, phases: %{}]
  end

  @type profile :: Profile.t()

  @spec to_event_attrs(profile()) :: map()
  def to_event_attrs(%Profile{} = profile) do
    %{
      profile_name: profile.name,
      mode: profile.mode,
      degraded: profile.degraded?,
      phases:
        Map.new(profile.phases, fn {phase, routing} ->
          {phase,
           %{
             author: routing.author,
             reviewers: routing.reviewers,
             coder_ack: routing.coder_ack,
             reviewer: routing.reviewer
           }}
        end)
    }
  end

  @spec default_agent_routing_config() :: map()
  def default_agent_routing_config do
    %{
      "default_profile" => "duet_balanced",
      "allow_single_agent_profiles" => true,
      "profiles" => %{
        "duet_balanced" => %{
          "mode" => "full_duet",
          "phases" => %{
            "spec" => %{"author" => "claude", "reviewers" => ["codex"]},
            "plan" => %{"author" => "codex", "reviewers" => ["claude"]},
            "code" => %{"author" => "codex", "reviewers" => ["claude"]},
            "review" => %{"coder_ack" => "code_author", "reviewer" => "non_coder"}
          }
        },
        "codex_only_dev" => %{
          "mode" => "degraded_single_agent",
          "phases" => %{
            "spec" => %{"author" => "codex", "reviewers" => []},
            "plan" => %{"author" => "codex", "reviewers" => []},
            "code" => %{"author" => "codex", "reviewers" => []},
            "review" => %{"coder_ack" => "code_author", "reviewer" => "human"}
          }
        },
        "claude_only_dev" => %{
          "mode" => "degraded_single_agent",
          "phases" => %{
            "spec" => %{"author" => "claude", "reviewers" => []},
            "plan" => %{"author" => "claude", "reviewers" => []},
            "code" => %{"author" => "claude", "reviewers" => []},
            "review" => %{"coder_ack" => "code_author", "reviewer" => "human"}
          }
        }
      }
    }
  end

  @spec resolve(map() | struct()) :: {:ok, profile()} | {:error, term()}
  def resolve(%{agent_routing: agent_routing}), do: resolve(agent_routing)

  def resolve(agent_routing) when is_map(agent_routing) do
    routing = merged_agent_routing(agent_routing)
    default_profile = Map.get(routing, "default_profile", "duet_balanced")
    profiles = Map.get(routing, "profiles", %{})

    case Map.fetch(profiles, default_profile) do
      {:ok, raw_profile} -> parse_profile(default_profile, raw_profile)
      :error -> {:error, {:unknown_default_profile, default_profile}}
    end
  end

  @spec validate_config(map()) :: :ok | {:error, String.t()}
  def validate_config(agent_routing) when is_map(agent_routing) do
    routing = merged_agent_routing(agent_routing)

    with :ok <- validate_default_profile(routing),
         :ok <- validate_profiles(routing) do
      :ok
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def validate_config(_agent_routing), do: {:error, "agent_routing must be a map"}

  defp merged_agent_routing(agent_routing) do
    deep_merge(default_agent_routing_config(), normalize_keys(agent_routing))
  end

  defp validate_default_profile(routing) do
    default_profile = Map.get(routing, "default_profile")
    profiles = Map.get(routing, "profiles", %{})

    cond do
      not is_binary(default_profile) or String.trim(default_profile) == "" ->
        {:error, :missing_default_profile}

      not Map.has_key?(profiles, default_profile) ->
        {:error, {:unknown_default_profile, default_profile}}

      true ->
        :ok
    end
  end

  defp validate_profiles(%{"profiles" => profiles}) when is_map(profiles) do
    profiles
    |> Enum.reduce_while(:ok, fn {name, raw_profile}, :ok ->
      case parse_profile(name, raw_profile) do
        {:ok, _profile} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_profiles(_routing), do: {:error, :missing_profiles}

  defp parse_profile(name, raw_profile) when is_binary(name) and is_map(raw_profile) do
    mode = Map.get(raw_profile, "mode")
    phases = Map.get(raw_profile, "phases")

    with :ok <- validate_mode(name, mode),
         {:ok, parsed_phases} <- parse_phases(name, phases),
         :ok <- validate_mode_semantics(name, mode, parsed_phases) do
      {:ok,
       %Profile{
         name: name,
         mode: mode,
         degraded?: mode != "full_duet",
         phases: parsed_phases
       }}
    end
  end

  defp parse_profile(name, _raw_profile), do: {:error, {:profile_not_map, name}}

  defp validate_mode(name, mode) do
    if mode in @modes do
      :ok
    else
      {:error, {:invalid_profile_mode, name, mode}}
    end
  end

  defp parse_phases(profile_name, phases) when is_map(phases) do
    @phases
    |> Enum.reduce_while({:ok, %{}}, fn phase, {:ok, parsed} ->
      case parse_phase(profile_name, phase, Map.get(phases, phase)) do
        {:ok, phase_routing} -> {:cont, {:ok, Map.put(parsed, phase, phase_routing)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_phases(profile_name, _phases), do: {:error, {:missing_phases, profile_name}}

  defp parse_phase(profile_name, phase, raw_phase) when phase in ~w(spec plan code) and is_map(raw_phase) do
    author = Map.get(raw_phase, "author")
    reviewers = Map.get(raw_phase, "reviewers", [])

    with :ok <- validate_actor(profile_name, phase, "author", author),
         {:ok, reviewers} <- validate_reviewers(profile_name, phase, reviewers) do
      {:ok, %Phase{name: phase, author: author, reviewers: reviewers}}
    end
  end

  defp parse_phase(profile_name, "review", raw_phase) when is_map(raw_phase) do
    coder_ack = Map.get(raw_phase, "coder_ack")
    reviewer = Map.get(raw_phase, "reviewer")

    with :ok <- validate_actor(profile_name, "review", "coder_ack", coder_ack),
         :ok <- validate_actor(profile_name, "review", "reviewer", reviewer) do
      {:ok, %Phase{name: "review", coder_ack: coder_ack, reviewer: reviewer}}
    end
  end

  defp parse_phase(profile_name, phase, _raw_phase), do: {:error, {:missing_phase, profile_name, phase}}

  defp validate_actor(profile_name, phase, role, actor) do
    cond do
      not is_binary(actor) or String.trim(actor) == "" ->
        {:error, {:missing_actor, profile_name, phase, role}}

      actor not in @actors ->
        {:error, {:invalid_actor, profile_name, phase, role, actor}}

      true ->
        :ok
    end
  end

  defp validate_reviewers(profile_name, phase, reviewers) when is_list(reviewers) do
    reviewers
    |> Enum.reduce_while({:ok, []}, fn reviewer, {:ok, parsed} ->
      case validate_actor(profile_name, phase, "reviewers", reviewer) do
        :ok -> {:cont, {:ok, parsed ++ [reviewer]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_reviewers(profile_name, phase, _reviewers), do: {:error, {:reviewers_not_list, profile_name, phase}}

  defp validate_mode_semantics(_profile_name, mode, _phases) when mode != "full_duet", do: :ok

  defp validate_mode_semantics(profile_name, "full_duet", phases) do
    ~w(spec plan code)
    |> Enum.reduce_while(:ok, fn phase, :ok ->
      phase_routing = Map.fetch!(phases, phase)
      reviewers = Enum.filter(phase_routing.reviewers, &(&1 in @machine_actors))

      cond do
        phase_routing.author not in @machine_actors ->
          {:halt, {:error, {:full_duet_author_not_machine, profile_name, phase, phase_routing.author}}}

        reviewers == [] ->
          {:halt, {:error, {:full_duet_missing_machine_reviewer, profile_name, phase}}}

        phase_routing.author in reviewers ->
          {:halt, {:error, {:full_duet_self_review, profile_name, phase}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp format_error(reason), do: "invalid duet.agent_routing: #{inspect(reason)}"

  defp normalize_keys(value) when is_map(value) do
    Map.new(value, fn {key, raw_value} -> {to_string(key), normalize_keys(raw_value)} end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right
end
