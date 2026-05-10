defmodule SymphonyElixir.Duet.Branches do
  @moduledoc """
  Pure helpers for computing and validating Duet branch names.

  This module owns the canonical naming for Duet's two-namespace branch
  topology and the spec's `task_id` shape. It is intentionally pure: no
  config reads, no git calls, no I/O. Higher-level orchestration code is
  expected to call into this module rather than building branch names
  ad-hoc.

  ## Spec references

  ### §5.2 Task identity

  A task's `task_id` MUST match `[a-z0-9][a-z0-9-]{2,63}` and is used in
  branch names and filesystem paths. The regex implies a total length of
  3..64 characters (1 leading char + 2..63 trailing chars).

  ### §6.1 Workspace and Branch Invariants

  Duet branch names MUST keep the valid two-namespace topology:

    * `duet-base/<task_id>` for long-lived task branches.
    * `duet-phase/<task_id>/<phase>` for phase branches.

  ### §9.1 Branch topology

      main
       └── duet-base/<task_id>                   (long-lived feature branch)
            ├── duet-phase/<task_id>/spec        (sub-branch, ephemeral)
            ├── duet-phase/<task_id>/plan        (sub-branch, ephemeral)
            └── duet-phase/<task_id>/code        (sub-branch, ephemeral)

  Phase names in branch paths are lowercase (`spec`, `plan`, `code`) even
  though phase names in events are uppercase (`SPEC`, `PLAN`, `CODE`).
  REVIEW does NOT have its own phase branch — per §8.1 / §9.2 it runs on
  the still-open CODE PR — so `phase_branch/2` rejects `:review` and
  `"REVIEW"`.

  ## Note on configurability

  The spec mentions configurable `branch.base_prefix` / `branch.phase_prefix`
  values; this slice intentionally hardcodes the defaults. Wiring those
  through configuration is a future slice.
  """

  @base_prefix "duet-base"
  @phase_prefix "duet-phase"

  # Spec §5.2 task_id regex: [a-z0-9][a-z0-9-]{2,63}
  # Total length is 1 + 2..63 = 3..64 characters.
  @task_id_regex ~r/^[a-z0-9][a-z0-9-]{2,63}$/

  @type phase :: :spec | :plan | :code | String.t()

  @doc """
  Returns the constant `duet-base` namespace prefix used for long-lived task branches.
  """
  @spec base_prefix() :: String.t()
  def base_prefix, do: @base_prefix

  @doc """
  Returns the constant `duet-phase` namespace prefix used for ephemeral phase branches.
  """
  @spec phase_prefix() :: String.t()
  def phase_prefix, do: @phase_prefix

  @doc """
  Returns true iff `task_id` is a binary matching the spec §5.2 regex.

  Non-binary inputs (atoms, integers, nil, …) return `false` rather than
  crashing.
  """
  @spec valid_task_id?(term()) :: boolean()
  def valid_task_id?(task_id) when is_binary(task_id), do: Regex.match?(@task_id_regex, task_id)
  def valid_task_id?(_other), do: false

  @doc """
  Returns `:ok` when `task_id` is valid per spec §5.2, otherwise
  `{:error, :invalid_task_id}`.
  """
  @spec validate_task_id(term()) :: :ok | {:error, :invalid_task_id}
  def validate_task_id(task_id) do
    if valid_task_id?(task_id), do: :ok, else: {:error, :invalid_task_id}
  end

  @doc """
  Computes the long-lived base branch name for a task per spec §6.1 / §9.1:
  `duet-base/<task_id>`.

  Returns `{:error, :invalid_task_id}` when `task_id` does not match the
  spec §5.2 regex.
  """
  @spec base_branch(String.t()) :: {:ok, String.t()} | {:error, :invalid_task_id}
  def base_branch(task_id) do
    with :ok <- validate_task_id(task_id) do
      {:ok, @base_prefix <> "/" <> task_id}
    end
  end

  @doc """
  Computes the ephemeral phase branch name for a task per spec §6.1 / §9.1:
  `duet-phase/<task_id>/<phase>` (phase lowercase).

  Accepts either an atom (`:spec | :plan | :code`) or the corresponding
  uppercase string (`"SPEC" | "PLAN" | "CODE"`).

  REVIEW is intentionally not supported — per §8.1 / §9.2 the REVIEW phase
  runs on the still-open CODE PR and has no branch of its own. Passing
  `:review` or `"REVIEW"` returns `{:error, :invalid_phase}`.

  Returns `{:error, :invalid_task_id}` when `task_id` is invalid, and
  `{:error, :invalid_phase}` when `phase` is not one of the supported
  values.
  """
  @spec phase_branch(String.t(), phase()) ::
          {:ok, String.t()} | {:error, :invalid_task_id | :invalid_phase}
  def phase_branch(task_id, phase) do
    with :ok <- validate_task_id(task_id),
         {:ok, phase_segment} <- normalize_phase(phase) do
      {:ok, @phase_prefix <> "/" <> task_id <> "/" <> phase_segment}
    end
  end

  defp normalize_phase(:spec), do: {:ok, "spec"}
  defp normalize_phase(:plan), do: {:ok, "plan"}
  defp normalize_phase(:code), do: {:ok, "code"}
  defp normalize_phase("SPEC"), do: {:ok, "spec"}
  defp normalize_phase("PLAN"), do: {:ok, "plan"}
  defp normalize_phase("CODE"), do: {:ok, "code"}
  defp normalize_phase(_other), do: {:error, :invalid_phase}
end
