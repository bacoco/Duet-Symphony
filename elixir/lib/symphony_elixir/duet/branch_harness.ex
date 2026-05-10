defmodule SymphonyElixir.Duet.BranchHarness do
  @moduledoc """
  Orchestrates Git branch operations for the Duet pair loop.

  Wraps the pure `SymphonyElixir.Duet.Branches` module (which only
  computes branch names) with actual Git shell commands dispatched
  through an injectable `SymphonyElixir.Duet.BranchHarness.Runner`.

  All functions accept `runner: ModuleImplementingRunner` to inject a
  test double; the default is
  `SymphonyElixir.Duet.BranchHarness.SystemRunner`.

  ## Spec references

  ### S6.1 / S9.1  Workspace and Branch Invariants

    * `duet-base/<task_id>` is created from `main` at task start.
    * `duet-phase/<task_id>/<phase>` is created from `duet-base/<task_id>`
      at phase start.

  ### S8.3  Phase freeze actions

    * SPEC / PLAN freeze: phase branch merges into duet-base.
    * CODE freeze: phase branch stays open (CODE PR spans CODE + REVIEW).
    * REVIEW freeze: CODE branch merges into duet-base, then duet-base
      merges into main.

  ### S9.2  Worktree isolation

  Each phase branch gets its own Git worktree so agents can operate
  concurrently without interfering with each other.
  """

  alias SymphonyElixir.Duet.Branches
  alias SymphonyElixir.Duet.BranchHarness.SystemRunner
  alias SymphonyElixir.Duet.PhaseTransition

  @type opts :: keyword()

  @doc """
  Creates `duet-base/<task_id>` from `:base_ref` (default `"main"`) if
  it does not already exist.

  Required opts: `:cwd`.
  Optional: `:runner`, `:base_ref` (default `"main"`).
  """
  @spec ensure_base_branch(String.t(), opts()) :: :ok | {:error, term()}
  def ensure_base_branch(task_id, opts \\ []) when is_binary(task_id) and is_list(opts) do
    with {:ok, branch} <- Branches.base_branch(task_id),
         {:ok, _cwd} <- require_opt(opts, :cwd) do
      base_ref = Keyword.get(opts, :base_ref, "main")
      ensure_branch_from(branch, base_ref, opts)
    end
  end

  @doc """
  Creates `duet-phase/<task_id>/<phase>` from `duet-base/<task_id>` if
  it does not already exist. Skips REVIEW (returns `:ok` immediately)
  since REVIEW has no branch of its own per S9.1.

  Required opts: `:cwd`.
  Optional: `:runner`.
  """
  @spec ensure_phase_branch(String.t(), String.t(), opts()) :: :ok | {:error, term()}
  def ensure_phase_branch(task_id, phase, opts \\ [])
      when is_binary(task_id) and is_binary(phase) and is_list(opts) do
    if PhaseTransition.has_phase_branch?(phase) do
      do_ensure_phase_branch(task_id, phase, opts)
    else
      :ok
    end
  end

  defp do_ensure_phase_branch(task_id, phase, opts) do
    with {:ok, phase_br} <- Branches.phase_branch(task_id, phase),
         {:ok, base_br} <- Branches.base_branch(task_id),
         {:ok, _cwd} <- require_opt(opts, :cwd) do
      ensure_branch_from(phase_br, base_br, opts)
    end
  end

  @doc """
  Merges `duet-phase/<task_id>/<phase>` into `duet-base/<task_id>`.
  Used at SPEC/PLAN freeze per S8.3.

  Required opts: `:cwd`.
  Optional: `:runner`.
  """
  @spec merge_phase_into_base(String.t(), String.t(), opts()) :: :ok | {:error, term()}
  def merge_phase_into_base(task_id, phase, opts \\ [])
      when is_binary(task_id) and is_binary(phase) and is_list(opts) do
    with {:ok, phase_br} <- Branches.phase_branch(task_id, phase),
         {:ok, base_br} <- Branches.base_branch(task_id),
         {:ok, _cwd} <- require_opt(opts, :cwd) do
      merge_branch(phase_br, base_br, opts)
    end
  end

  @doc """
  Merges `duet-base/<task_id>` into `main`. Used at REVIEW freeze
  per S8.3.

  Required opts: `:cwd`.
  Optional: `:runner`, `:target` (default `"main"`).
  """
  @spec merge_base_into_main(String.t(), opts()) :: :ok | {:error, term()}
  def merge_base_into_main(task_id, opts \\ []) when is_binary(task_id) and is_list(opts) do
    with {:ok, base_br} <- Branches.base_branch(task_id),
         {:ok, _cwd} <- require_opt(opts, :cwd) do
      target = Keyword.get(opts, :target, "main")
      merge_branch(base_br, target, opts)
    end
  end

  @doc """
  Returns the worktree path for the phase branch. Creates the worktree
  if it does not already exist.

  The worktree is placed at `<cwd>/../.duet-worktrees/<task_id>/<phase>`
  (lowercase phase).

  Required opts: `:cwd`.
  Optional: `:runner`.
  """
  @spec phase_workspace(String.t(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, term()}
  def phase_workspace(task_id, phase, opts \\ [])
      when is_binary(task_id) and is_binary(phase) and is_list(opts) do
    with {:ok, phase_br} <- Branches.phase_branch(task_id, phase),
         {:ok, cwd} <- require_opt(opts, :cwd) do
      worktree_abs = worktree_path(cwd, task_id, phase)
      ensure_worktree(worktree_abs, phase_br, opts)
    end
  end

  @doc """
  Removes the worktree and deletes the phase branch after merge.

  Required opts: `:cwd`.
  Optional: `:runner`.
  """
  @spec cleanup_phase_branch(String.t(), String.t(), opts()) :: :ok | {:error, term()}
  def cleanup_phase_branch(task_id, phase, opts \\ [])
      when is_binary(task_id) and is_binary(phase) and is_list(opts) do
    with {:ok, phase_br} <- Branches.phase_branch(task_id, phase),
         {:ok, cwd} <- require_opt(opts, :cwd),
         wt_abs = worktree_path(cwd, task_id, phase),
         :ok <- remove_worktree(wt_abs, opts) do
      delete_branch(phase_br, opts)
    end
  end

  @doc """
  Returns the configured Runner module.

  Resolution order:
    1. `opts[:runner]` if it is a module.
    2. `Application.get_env(:symphony_elixir, :duet_branch_harness_runner)`.
    3. `SymphonyElixir.Duet.BranchHarness.SystemRunner`.
  """
  @spec runner(opts()) :: module()
  def runner(opts \\ []) do
    case Keyword.get(opts, :runner) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _ ->
        case Application.get_env(:symphony_elixir, :duet_branch_harness_runner) do
          module when is_atom(module) and not is_nil(module) -> module
          _ -> SystemRunner
        end
    end
  end

  # --- internals -----------------------------------------------------------

  defp git(args, opts) do
    runner_module = runner(opts)
    runner_opts = build_runner_opts(opts)
    runner_module.run(args, runner_opts)
  end

  defp build_runner_opts(opts) do
    cwd = Keyword.get(opts, :cwd)
    if is_binary(cwd), do: [cwd: cwd], else: []
  end

  defp require_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_opt, key}}
    end
  end

  defp ensure_branch_from(branch, start_point, opts) do
    case branch_exists?(branch, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> create_branch(branch, start_point, opts)
      {:error, _} = err -> err
    end
  end

  defp worktree_path(cwd, task_id, phase) do
    phase_lower = String.downcase(phase)

    [cwd, "..", ".duet-worktrees", task_id, phase_lower]
    |> Path.join()
    |> Path.expand()
  end

  defp ensure_worktree(worktree_abs, phase_br, opts) do
    case worktree_exists?(worktree_abs, opts) do
      {:ok, true} ->
        {:ok, worktree_abs}

      {:ok, false} ->
        case git(["worktree", "add", worktree_abs, phase_br], opts) do
          {:ok, _} -> {:ok, worktree_abs}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp branch_exists?(branch, opts) do
    case git(["rev-parse", "--verify", "refs/heads/#{branch}"], opts) do
      {:ok, _} -> {:ok, true}
      {:error, {:exit_status, _, _}} -> {:ok, false}
      {:error, _} = err -> err
    end
  end

  defp create_branch(branch, start_point, opts) do
    case git(["branch", branch, start_point], opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp merge_branch(source, target, opts) do
    with {:ok, _} <- git(["checkout", target], opts) do
      case git(
             ["merge", "--no-ff", "-m", "Merge #{source} into #{target}", source],
             opts
           ) do
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end

  defp worktree_exists?(path, opts) do
    case git(["worktree", "list", "--porcelain"], opts) do
      {:ok, output} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line -> String.starts_with?(line, "worktree ") && String.contains?(line, path) end)

        {:ok, exists}

      {:error, _} = err ->
        err
    end
  end

  defp remove_worktree(path, opts) do
    case git(["worktree", "remove", "--force", path], opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp delete_branch(branch, opts) do
    case git(["branch", "-D", branch], opts) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
