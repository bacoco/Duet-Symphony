defmodule SymphonyElixir.Duet.PRConflict do
  @moduledoc """
  Pure decider for spec §8.3.1 CODE PR mergeability into `duet-base/<task_id>`.

  This module never talks to GitHub. The future orchestrator wiring queries
  `gh api .../pulls/<n>` (or the equivalent), feeds the parsed
  `mergeable` / `mergeable_state` / `conflicting_paths` triple into
  `evaluate/1`, and uses the result to decide whether to fall through to
  the §8.3 REVIEW-freeze merge or to emit `code_pr_conflict` and pause
  the task.

  ## Spec §8.3.1 (relevant)

  Each task's `duet-base/<task_id>` branch is exclusive to that task, so
  concurrent Duet tasks cannot cause conflicts on it. However, external
  modifications — an operator rebasing or pushing directly to the task
  branch, or merge conflicts discovered when landing
  `duet-base/<task_id>` onto `main` — may make the CODE PR unmergeable
  after REVIEW convergence.

  The orchestrator MUST check mergeability of the CODE PR into
  `duet-base/<task_id>` immediately before executing the REVIEW-freeze
  merge (§8.3, REVIEW step 1). If the merge cannot be completed cleanly:

  1. The task transitions to `awaiting_operator` with
     `reason = code_pr_conflict`.
  2. The orchestrator emits a `code_pr_conflict` event including the
     CODE PR permalink, the conflicting paths, and the current
     `duet-base` HEAD.
  3. The operator resolves the conflict manually and resumes via
     `duet resolve <task_id> --continue`.

  Conflicts between `duet-base/<task_id>` and the parent repo's main
  branch at final land time are outside Duet's scope.
  """

  @type mergeable_state ::
          :clean
          | :dirty
          | :unstable
          | :behind
          | :blocked
          | :unknown
          | :draft
          | :has_hooks

  @type evaluation_input :: %{
          required(:mergeable) => boolean() | nil,
          required(:mergeable_state) => mergeable_state(),
          optional(:conflicting_paths) => [String.t()],
          optional(:base_head) => String.t() | nil,
          optional(:pr_permalink) => String.t() | nil
        }

  @type evaluation_result ::
          :mergeable
          | {:conflict, %{paths: [String.t()], base_head: String.t() | nil}}
          | {:retry_later, mergeable_state()}

  @known_states ~w(clean dirty unstable behind blocked unknown draft has_hooks)a

  @doc """
  Decides whether the CODE PR can be merged immediately, must be paused
  due to a conflict, or should be retried later because GitHub has not
  yet computed mergeability.

  - `mergeable: true` AND `mergeable_state: :clean` → `:mergeable`.
  - `mergeable: false` (any state) → `{:conflict, %{paths, base_head}}`.
  - `mergeable: nil` (GitHub still computing) OR `mergeable_state: :unknown`
    → `{:retry_later, mergeable_state}`.
  - any other case where GitHub flags a non-clean state but `mergeable`
    is true (`:behind`, `:unstable`, `:blocked`) → `:mergeable`. The
    orchestrator may still need to handle these but they are not §8.3.1
    conflicts (they're branch-protection / status-check policy issues
    outside this module's scope).
  - `:draft` mergeable_state with `mergeable: true` → `:mergeable`. The
    orchestrator decides separately whether a draft PR should be merged
    (see §9.2.1 draft PR lifecycle).
  """
  @spec evaluate(evaluation_input()) :: evaluation_result()
  def evaluate(input) when is_map(input) do
    mergeable = Map.get(input, :mergeable)
    state = Map.get(input, :mergeable_state, :unknown)

    cond do
      is_nil(mergeable) -> {:retry_later, state}
      state == :unknown -> {:retry_later, state}
      mergeable == false -> conflict(input)
      mergeable == true -> :mergeable
    end
  end

  defp conflict(input) do
    paths =
      case Map.get(input, :conflicting_paths) do
        list when is_list(list) -> list
        _ -> []
      end

    base_head = Map.get(input, :base_head)

    {:conflict, %{paths: paths, base_head: base_head}}
  end

  @doc """
  Builds the spec §8.3.1 `code_pr_conflict` event payload. The orchestrator
  is expected to call `EventLog.append/3` with this payload under kind
  `"code_pr_conflict"`.

  Coerces a non-list `conflicting_paths` (e.g. `nil`) to `[]`. Keeps `nil`
  values for `pr_permalink` and `base_head` rather than dropping the keys,
  so consumers can rely on the shape.
  """
  @spec event_attrs(String.t() | nil, [String.t()], String.t() | nil) :: map()
  def event_attrs(pr_permalink, conflicting_paths, base_head) do
    paths =
      case conflicting_paths do
        list when is_list(list) -> list
        _ -> []
      end

    %{
      pr_permalink: pr_permalink,
      conflicting_paths: paths,
      base_head: base_head
    }
  end

  @doc """
  Returns the canonical mergeable_state atoms recognized by `evaluate/1`.
  """
  @spec known_states() :: [mergeable_state()]
  def known_states, do: @known_states
end
