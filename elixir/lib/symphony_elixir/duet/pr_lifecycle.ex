defmodule SymphonyElixir.Duet.PRLifecycle do
  @moduledoc """
  Phase-aware PR lifecycle operations for the Duet pair loop.

  Wraps the pure `Duet.GhCli`, `Duet.PR`, and `Duet.PhaseTransition`
  modules into the high-level operations that `PairRunner` calls at
  phase boundaries (open PR, post trailer, submit verdict, execute
  freeze actions).

  All functions are stateless — state flows through the event log and
  the `ctx` / `opts` maps passed by the caller. GhCli runner injection
  follows the same pattern as `Duet.GhCli`: pass `:runner` in opts or
  configure `:duet_gh_cli_runner` via Application env.

  ## Spec references

  * §9 — PR lifecycle (open, comment, review, merge)
  * §9.1 / §9.2 — Branch topology (REVIEW reuses CODE PR)
  * §9.3 — Author trailer as PR comment; Reviewer verdict as PR review
  * §9.4 — PR title and body format
  * §8.3 — Phase freeze actions
  """

  alias SymphonyElixir.Duet.Branches
  alias SymphonyElixir.Duet.BranchHarness
  alias SymphonyElixir.Duet.EventLog
  alias SymphonyElixir.Duet.GhCli
  alias SymphonyElixir.Duet.PhaseTransition
  alias SymphonyElixir.Duet.PR

  @type ctx :: map()

  @doc """
  Opens a PR for the current phase.

  Uses `Duet.PR` for title/body and `GhCli.open_pr/1` for creation.
  Records a `"pr_opened"` event on success. Returns the PR number for
  later operations.

  For REVIEW, no new PR is opened — the CODE PR number is resolved from
  the event log via `resolve_code_pr_number/1`.

  Required ctx keys: `:task_id`, `:phase`, `:issue_title`,
  `:issue_description`, `:workspace`.
  Optional ctx keys: `:cycle` (default 1), `:profile`.
  """
  @spec open_phase_pr(ctx()) :: {:ok, pos_integer()} | {:error, term()}
  def open_phase_pr(%{phase: "REVIEW", task_id: task_id}) do
    resolve_code_pr_number(%{task_id: task_id})
  end

  def open_phase_pr(%{task_id: task_id, phase: phase} = ctx) do
    pr_struct = build_pr_struct(ctx)
    title = PR.title(pr_struct)
    body = PR.body(pr_struct)

    with {:ok, base_branch} <- Branches.base_branch(task_id),
         {:ok, head_branch} <- Branches.phase_branch(task_id, phase) do
      gh_opts =
        [
          base: base_branch,
          head: head_branch,
          title: title,
          body: body,
          draft: true,
          cwd: ctx[:workspace]
        ]
        |> maybe_add_runner(ctx)

      with {:ok, %{number: number}} <- GhCli.open_pr(gh_opts),
           :ok <-
             record_event(task_id, "pr_opened", %{
               phase: phase,
               pr_number: number,
               title: title
             }) do
        {:ok, number}
      end
    end
  end

  @doc """
  Posts an author's trailer as a PR comment via `GhCli.post_comment/1`.

  Required opts: `:cwd`. Optional: `:runner`.
  """
  @spec post_author_trailer(
          pos_integer(),
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def post_author_trailer(pr_number, trailer_text, opts \\ []) do
    gh_opts =
      [number: pr_number, body: trailer_text, cwd: opts[:cwd]]
      |> maybe_add_runner_from_opts(opts)

    GhCli.post_comment(gh_opts)
  end

  @doc """
  Submits a reviewer's verdict as a PR review via `GhCli.submit_review/1`.

  Maps `:approve` to `"APPROVE"` and `:request_changes` to
  `"REQUEST_CHANGES"` for the GhCli event parameter.

  Required opts: `:cwd`. Optional: `:runner`.
  """
  @spec submit_reviewer_verdict(
          pos_integer(),
          :approve | :request_changes,
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def submit_reviewer_verdict(pr_number, verdict, body, opts \\ []) do
    event = verdict_to_event(verdict)

    gh_opts =
      [number: pr_number, event: event, body: body, cwd: opts[:cwd]]
      |> maybe_add_runner_from_opts(opts)

    GhCli.submit_review(gh_opts)
  end

  @doc """
  Executes the freeze actions for a phase per
  `PhaseTransition.freeze_actions/1`.

  Each action is dispatched to the appropriate GhCli or BranchHarness
  call. Records a `"freeze_action_executed"` event for each action.

  GhCli actions (merge PR, mark ready) require a non-nil `pr_number`.
  When `pr_number` is nil, those actions are skipped. BranchHarness
  actions (delete branch, merge base) use `:task_id` and `:cwd` from
  opts and do not require a PR number.

  Required opts: `:cwd`, `:task_id`.
  Optional: `:runner` (GhCli), `:branch_runner` (BranchHarness).
  """
  @spec execute_freeze_actions(
          String.t(),
          pos_integer() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def execute_freeze_actions(phase, pr_number, opts \\ []) do
    actions = PhaseTransition.freeze_actions(phase)
    task_id = Keyword.fetch!(opts, :task_id)
    action_opts = Keyword.put(opts, :phase, phase)

    Enum.reduce_while(actions, :ok, fn action, :ok ->
      with :ok <- execute_single_action(action, pr_number, action_opts),
           :ok <-
             record_event(task_id, "freeze_action_executed", %{
               phase: phase,
               action: Atom.to_string(action),
               pr_number: pr_number
             }) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Reads the event log to find the CODE phase `pr_opened` event's PR
  number. Used by REVIEW to reuse the CODE PR.
  """
  @spec resolve_code_pr_number(map()) ::
          {:ok, pos_integer()} | {:error, :code_pr_not_found}
  def resolve_code_pr_number(%{task_id: task_id}) do
    case EventLog.read(task_id) do
      {:ok, events} ->
        events
        |> Enum.filter(fn e ->
          e["kind"] == "pr_opened" && e["phase"] == "CODE"
        end)
        |> List.last()
        |> case do
          %{"pr_number" => number} when is_integer(number) ->
            {:ok, number}

          _ ->
            {:error, :code_pr_not_found}
        end

      {:error, _reason} ->
        {:error, :code_pr_not_found}
    end
  end

  # --- internals ---------------------------------------------------------

  defp build_pr_struct(ctx) do
    %PR{
      task_id: ctx[:task_id],
      phase: ctx[:phase],
      issue_title: ctx[:issue_title],
      issue_description: ctx[:issue_description],
      cycle: Map.get(ctx, :cycle, 1),
      event_log_path: event_log_path(ctx[:task_id])
    }
  end

  defp event_log_path(task_id) when is_binary(task_id) do
    EventLog.path_for_task(task_id)
  end

  defp event_log_path(_), do: nil

  defp verdict_to_event(:approve), do: "APPROVE"
  defp verdict_to_event(:request_changes), do: "REQUEST_CHANGES"

  # -- GhCli actions (require non-nil pr_number) --

  defp execute_single_action(:merge_phase_pr_into_base, nil, _opts), do: :ok

  defp execute_single_action(:merge_phase_pr_into_base, pr_number, opts) do
    gh_opts =
      [number: pr_number, cwd: opts[:cwd]]
      |> maybe_add_runner_from_opts(opts)

    GhCli.merge_pr(gh_opts)
  end

  defp execute_single_action(:merge_code_pr_into_base, nil, _opts), do: :ok

  defp execute_single_action(:merge_code_pr_into_base, pr_number, opts) do
    gh_opts =
      [number: pr_number, cwd: opts[:cwd]]
      |> maybe_add_runner_from_opts(opts)

    GhCli.merge_pr(gh_opts)
  end

  defp execute_single_action(:mark_code_pr_ready, nil, _opts), do: :ok

  defp execute_single_action(:mark_code_pr_ready, pr_number, opts) do
    gh_opts =
      [number: pr_number, cwd: opts[:cwd]]
      |> maybe_add_runner_from_opts(opts)

    GhCli.mark_ready(gh_opts)
  end

  # -- BranchHarness actions (use task_id + phase from opts) --

  defp execute_single_action(:delete_phase_sub_branch, _pr_number, opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    phase = Keyword.fetch!(opts, :phase)
    BranchHarness.cleanup_phase_branch(task_id, phase, branch_harness_opts(opts))
  end

  defp execute_single_action(:delete_code_sub_branch, _pr_number, opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    BranchHarness.cleanup_phase_branch(task_id, "CODE", branch_harness_opts(opts))
  end

  defp execute_single_action(:merge_base_branch, _pr_number, opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    BranchHarness.merge_base_into_main(task_id, branch_harness_opts(opts))
  end

  # -- No-op actions --

  defp execute_single_action(:hold_open_for_review, _pr_number, _opts), do: :ok
  defp execute_single_action(:emit_phase_freeze_message, _pr_number, _opts), do: :ok
  defp execute_single_action(:emit_task_completed, _pr_number, _opts), do: :ok
  defp execute_single_action(:record_code_tree_hash, _pr_number, _opts), do: :ok

  defp branch_harness_opts(opts) do
    bh_opts = [cwd: Keyword.fetch!(opts, :cwd)]

    case Keyword.get(opts, :branch_runner) do
      runner when is_atom(runner) and not is_nil(runner) ->
        Keyword.put(bh_opts, :runner, runner)

      _ ->
        bh_opts
    end
  end

  defp record_event(task_id, kind, attrs) do
    case EventLog.append(task_id, kind, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, {:event_log_failed, reason}}
    end
  end

  defp maybe_add_runner(opts, %{runner: runner}) when is_atom(runner) and not is_nil(runner) do
    Keyword.put(opts, :runner, runner)
  end

  defp maybe_add_runner(opts, _ctx), do: opts

  defp maybe_add_runner_from_opts(gh_opts, opts) do
    case Keyword.get(opts, :runner) do
      runner when is_atom(runner) and not is_nil(runner) ->
        Keyword.put(gh_opts, :runner, runner)

      _ ->
        gh_opts
    end
  end
end
