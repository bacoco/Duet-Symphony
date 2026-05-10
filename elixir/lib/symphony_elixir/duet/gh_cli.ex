defmodule SymphonyElixir.Duet.GhCli do
  @moduledoc """
  Thin Duet-side wrapper over the `gh` CLI for the pair-loop's GitHub
  operations.

  All functions accept `runner: ModuleImplementingRunner` to inject a
  `SymphonyElixir.Duet.GhCli.Runner` module for tests; the default is
  `SymphonyElixir.Duet.GhCli.SystemRunner`. Each function builds the
  `gh` argv, dispatches via the Runner, and returns either a typed
  success tuple or `{:error, reason}` propagated from the Runner.

  Per spec §9.3 the Author emits its verdict as a `---DUET-TRAILER---`
  block (§10.1) inside a regular PR issue-comment (`post_comment/1`),
  while the Reviewer submits its verdict via the standard PR review API
  (`submit_review/1`). Branch creation and per-phase merges into
  `duet-base/<task_id>` (§9.1, §9.2) are handled by the orchestrator's
  Git driver — this module only covers the GitHub-side operations
  (`open_pr/1`, `mark_ready/1`, `merge_pr/1`, `post_comment/1`,
  `submit_review/1`, `list_reviews/1`, `mergeability/1`).

  This module deliberately does NOT implement retry / backoff /
  rate-limit handling per spec §11. The orchestrator wraps these calls
  in its retry policy; the wrapper here is intentionally one-shot so
  the orchestrator stays in charge of timing decisions.
  """

  alias SymphonyElixir.Duet.GhCli.SystemRunner
  alias SymphonyElixir.Duet.PRConflict

  @type opts :: keyword()
  @type pr_number :: pos_integer()
  @type pr_url :: String.t()
  @type body :: String.t()

  @doc """
  Opens a PR.

  Required opts: `:base`, `:head`, `:title`, `:body`, `:cwd`.
  Optional: `:draft` (boolean), `:repo` (`"owner/repo"` string),
  `:runner` (Runner module override).

  Returns `{:ok, %{number: pr_number, url: pr_url}}` on success. The PR
  number is parsed from the trailing `/pull/<N>` segment of the URL
  printed by `gh pr create`.
  """
  @spec open_pr(opts()) :: {:ok, %{number: pr_number(), url: pr_url()}} | {:error, term()}
  def open_pr(opts) when is_list(opts) do
    with {:ok, required} <- fetch_required(opts, [:base, :head, :title, :body, :cwd]) do
      args =
        ["pr", "create"]
        |> add_repo(opts)
        |> append_flag("--base", required[:base])
        |> append_flag("--head", required[:head])
        |> append_flag("--title", required[:title])
        |> append_flag("--body", required[:body])
        |> maybe_add_draft(opts)

      case dispatch(args, opts) do
        {:ok, stdout} -> parse_pr_create_output(stdout)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Marks a draft PR as ready-for-review via `gh pr ready <number>`.

  Required: `:number`, `:cwd`. Optional: `:repo`, `:runner`.
  """
  @spec mark_ready(opts()) :: :ok | {:error, term()}
  def mark_ready(opts) when is_list(opts) do
    with {:ok, %{number: number}} <- fetch_required(opts, [:number, :cwd]) do
      args =
        ["pr", "ready", to_string(number)]
        |> add_repo(opts)

      ok_or_error(dispatch(args, opts))
    end
  end

  @doc """
  Merges a PR via `gh pr merge <number>`.

  Required: `:number`, `:cwd`. Optional: `:method`
  (`"merge" | "squash" | "rebase"`, default `"merge"`),
  `:delete_branch` (boolean, default `false`), `:repo`, `:runner`.
  """
  @spec merge_pr(opts()) :: :ok | {:error, term()}
  def merge_pr(opts) when is_list(opts) do
    with {:ok, %{number: number}} <- fetch_required(opts, [:number, :cwd]),
         {:ok, method_flag} <- merge_method_flag(Keyword.get(opts, :method, "merge")) do
      args =
        ["pr", "merge", to_string(number)]
        |> add_repo(opts)
        |> Kernel.++([method_flag])
        |> maybe_add_delete_branch(opts)

      ok_or_error(dispatch(args, opts))
    end
  end

  @doc """
  Posts an issue-comment on a PR via `gh pr comment <number> --body <body>`.

  Used for the §9.3 Author trailer-comment flow (the trailer body is
  produced by `SymphonyElixir.Duet.Trailer`; this wrapper does not
  inspect it).

  Required: `:number`, `:body`, `:cwd`. Optional: `:repo`, `:runner`.
  """
  @spec post_comment(opts()) :: :ok | {:error, term()}
  def post_comment(opts) when is_list(opts) do
    with {:ok, required} <- fetch_required(opts, [:number, :body, :cwd]) do
      args =
        ["pr", "comment", to_string(required[:number])]
        |> add_repo(opts)
        |> append_flag("--body", required[:body])

      ok_or_error(dispatch(args, opts))
    end
  end

  @doc """
  Submits a PR review via `gh pr review <number>`.

  Required: `:number`, `:event`
  (`"APPROVE" | "REQUEST_CHANGES" | "COMMENT"`), `:body`, `:cwd`.
  Optional: `:repo`, `:runner`.
  """
  @spec submit_review(opts()) :: :ok | {:error, term()}
  def submit_review(opts) when is_list(opts) do
    with {:ok, required} <- fetch_required(opts, [:number, :event, :body, :cwd]),
         {:ok, event_flag} <- review_event_flag(required[:event]) do
      args =
        ["pr", "review", to_string(required[:number])]
        |> add_repo(opts)
        |> Kernel.++([event_flag])
        |> append_flag("--body", required[:body])

      ok_or_error(dispatch(args, opts))
    end
  end

  @doc """
  Lists reviews for a PR via `gh api repos/{owner}/{repo}/pulls/<n>/reviews`.

  Returns the parsed JSON array as a list of maps. The caller passes the
  result to `SymphonyElixir.Duet.GithubReview.parse_reviews/1`.

  Required: `:number`, `:cwd`. Optional: `:repo` (`"owner/repo"` string;
  when absent the literal `{owner}/{repo}` placeholder is left in place
  so `gh` resolves it from the local clone), `:runner`.
  """
  @spec list_reviews(opts()) :: {:ok, [map()]} | {:error, term()}
  def list_reviews(opts) when is_list(opts) do
    with {:ok, %{number: number}} <- fetch_required(opts, [:number, :cwd]) do
      repo_segment = repo_path_segment(opts)
      args = ["api", "repos/#{repo_segment}/pulls/#{number}/reviews"]

      case dispatch(args, opts) do
        {:ok, stdout} -> decode_json_array(stdout)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns a PR's mergeability triple suitable for
  `SymphonyElixir.Duet.PRConflict.evaluate/1`.

  Calls `gh pr view <number> --json mergeable,mergeStateStatus` and
  decodes; the camelCase keys are mapped to the spec §8.3.1 atom keys
  (`:mergeable` and `:mergeable_state`). The
  `mergeStateStatus` value is lowercased and converted to an atom from
  the canonical set in
  `SymphonyElixir.Duet.PRConflict.known_states/0`.

  Required: `:number`, `:cwd`. Optional: `:repo`, `:runner`.
  """
  @spec mergeability(opts()) :: {:ok, map()} | {:error, term()}
  def mergeability(opts) when is_list(opts) do
    with {:ok, %{number: number}} <- fetch_required(opts, [:number, :cwd]) do
      args =
        ["pr", "view", to_string(number), "--json", "mergeable,mergeStateStatus"]
        |> add_repo(opts)

      case dispatch(args, opts) do
        {:ok, stdout} -> parse_mergeability(stdout)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns the configured Runner module.

  Resolution order:
    1. `opts[:runner]` if it is a module.
    2. `Application.get_env(:symphony_elixir, :duet_gh_cli_runner)` if it is a module.
    3. `SymphonyElixir.Duet.GhCli.SystemRunner`.
  """
  @spec runner(opts()) :: module()
  def runner(opts \\ []) do
    case Keyword.get(opts, :runner) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _ ->
        case Application.get_env(:symphony_elixir, :duet_gh_cli_runner) do
          module when is_atom(module) and not is_nil(module) -> module
          _ -> SystemRunner
        end
    end
  end

  # --- internals -----------------------------------------------------------

  defp dispatch(args, opts) do
    runner_module = runner(opts)
    runner_opts = build_runner_opts(opts)
    runner_module.run(args, runner_opts)
  end

  defp build_runner_opts(opts) do
    cwd = Keyword.get(opts, :cwd)
    extra = Keyword.get(opts, :runner_opts, [])

    base = if is_binary(cwd), do: [cwd: cwd], else: []
    Keyword.merge(base, extra)
  end

  defp fetch_required(opts, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, {:missing_opt, key}}}
      end
    end)
  end

  defp add_repo(args, opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" -> args ++ ["--repo", repo]
      _ -> args
    end
  end

  defp maybe_add_draft(args, opts) do
    if Keyword.get(opts, :draft, false), do: args ++ ["--draft"], else: args
  end

  defp maybe_add_delete_branch(args, opts) do
    if Keyword.get(opts, :delete_branch, false), do: args ++ ["--delete-branch"], else: args
  end

  defp append_flag(args, flag, value) when is_binary(value), do: args ++ [flag, value]
  defp append_flag(args, flag, value), do: args ++ [flag, to_string(value)]

  defp merge_method_flag("merge"), do: {:ok, "--merge"}
  defp merge_method_flag("squash"), do: {:ok, "--squash"}
  defp merge_method_flag("rebase"), do: {:ok, "--rebase"}
  defp merge_method_flag(other), do: {:error, {:invalid_merge_method, other}}

  defp review_event_flag("APPROVE"), do: {:ok, "--approve"}
  defp review_event_flag("REQUEST_CHANGES"), do: {:ok, "--request-changes"}
  defp review_event_flag("COMMENT"), do: {:ok, "--comment"}
  defp review_event_flag(other), do: {:error, {:invalid_review_event, other}}

  defp repo_path_segment(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" -> repo
      _ -> "{owner}/{repo}"
    end
  end

  defp ok_or_error({:ok, _stdout}), do: :ok
  defp ok_or_error({:error, reason}), do: {:error, reason}

  defp parse_pr_create_output(stdout) when is_binary(stdout) do
    url =
      stdout
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reverse()
      |> Enum.find(fn line -> String.contains?(line, "/pull/") end)

    case url do
      nil ->
        {:error, {:pr_url_not_found, stdout}}

      line ->
        parse_pr_url_line(line, stdout)
    end
  end

  defp parse_pr_url_line(line, stdout) do
    trimmed = String.trim(line)

    case Regex.run(~r{/pull/(\d+)/?$}, trimmed, capture: :all_but_first) do
      [number_str] -> parse_pr_number(number_str, trimmed, stdout)
      _ -> {:error, {:pr_url_not_found, stdout}}
    end
  end

  defp parse_pr_number(number_str, url, stdout) do
    case Integer.parse(number_str) do
      {number, ""} when number > 0 -> {:ok, %{number: number, url: url}}
      _ -> {:error, {:pr_url_not_found, stdout}}
    end
  end

  defp decode_json_array(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, {:unexpected_json_shape, other}}
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
    end
  end

  defp parse_mergeability(stdout) when is_binary(stdout) do
    case Jason.decode(stdout) do
      {:ok, payload} when is_map(payload) ->
        {:ok,
         %{
           mergeable: extract_mergeable(payload),
           mergeable_state: extract_mergeable_state(payload)
         }}

      {:ok, other} ->
        {:error, {:unexpected_json_shape, other}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:invalid_json, err}}
    end
  end

  defp extract_mergeable(%{"mergeable" => true}), do: true
  defp extract_mergeable(%{"mergeable" => false}), do: false
  defp extract_mergeable(%{"mergeable" => "MERGEABLE"}), do: true
  defp extract_mergeable(%{"mergeable" => "CONFLICTING"}), do: false
  defp extract_mergeable(_payload), do: nil

  defp extract_mergeable_state(%{"mergeStateStatus" => raw}) when is_binary(raw) do
    state = String.downcase(raw)

    Enum.find(PRConflict.known_states(), :unknown, &(Atom.to_string(&1) == state))
  end

  defp extract_mergeable_state(_payload), do: :unknown
end
