defmodule SymphonyElixir.Duet.PhaseTransition do
  @moduledoc """
  Pure state machine for the Duet phase pipeline (spec §8.2, §8.3).

  Phase strings are uppercase per the §13.1 event-kind convention
  (`"SPEC"`, `"PLAN"`, `"CODE"`, `"REVIEW"`). The orchestrator wires
  the side-effect actions returned by this module to actual GitHub /
  filesystem calls; this module never performs I/O.

  ## Spec references

  ### §8.2 Phase ordering

  Phases run strictly in order: SPEC → PLAN → CODE → REVIEW. A phase
  MUST NOT begin until the previous phase has reached *frozen* state.
  "Frozen" does not always mean "PR merged" (§8.3 below). For SPEC and
  PLAN, freeze coincides with the phase PR's merge. For CODE, freeze
  means convergence on the CODE PR — the PR is **not** merged yet; it
  is held open so REVIEW can run on the same PR before it lands.

  ### §8.3 Phase frozen state

  * **SPEC / PLAN** (doc-only phases, freeze = merge): finalize and
    merge the phase PR into `duet-base/<task_id>`, delete the phase
    sub-branch, emit a phase-freeze message for the next phase.
  * **CODE** (freeze ≠ merge): finalize the CODE PR (held open), record
    the CODE-frozen tree-hash for REVIEW, emit a phase-freeze message.
  * **REVIEW** (terminal, merges the CODE PR): merge the CODE PR into
    `duet-base/<task_id>`, delete the CODE sub-branch, emit phase-freeze
    and `task_completed`.

  ### §9.1 / §9.2 Branch topology

  Only SPEC, PLAN, and CODE have phase sub-branches. REVIEW reuses the
  still-open CODE PR and has no branch of its own.
  """

  @phase_order ~w(SPEC PLAN CODE REVIEW)

  @type phase :: String.t()

  @type freeze_action ::
          :merge_phase_pr_into_base
          | :hold_open_for_review
          | :merge_code_pr_into_base
          | :delete_phase_sub_branch
          | :delete_code_sub_branch
          | :emit_phase_freeze_message
          | :emit_task_completed
          | :record_code_tree_hash

  @doc """
  The canonical phase order used by the spec.
  """
  @spec phase_order() :: [phase()]
  def phase_order, do: @phase_order

  @doc """
  Returns the next phase after the given one, or `nil` if the given
  phase is terminal (`"REVIEW"`) or unknown.
  """
  @spec next_phase(phase()) :: phase() | nil
  def next_phase("SPEC"), do: "PLAN"
  def next_phase("PLAN"), do: "CODE"
  def next_phase("CODE"), do: "REVIEW"
  def next_phase("REVIEW"), do: nil
  def next_phase(_other), do: nil

  @doc """
  Returns `true` if the phase is the terminal phase (`"REVIEW"`).
  """
  @spec terminal?(phase()) :: boolean()
  def terminal?("REVIEW"), do: true
  def terminal?(_other), do: false

  @doc """
  Returns `true` if a phase's freeze coincides with merging the phase PR
  (SPEC and PLAN), `false` otherwise. CODE freezes hold the PR open;
  REVIEW freeze merges the CODE PR (a different PR than the one named
  by `phase`).
  """
  @spec freeze_merges_phase_pr?(phase()) :: boolean()
  def freeze_merges_phase_pr?("SPEC"), do: true
  def freeze_merges_phase_pr?("PLAN"), do: true
  def freeze_merges_phase_pr?("CODE"), do: false
  def freeze_merges_phase_pr?("REVIEW"), do: false
  def freeze_merges_phase_pr?(_other), do: false

  @doc """
  Returns the ordered list of side-effect actions the orchestrator should
  apply on freeze for the given phase. Spec §8.3.
  """
  @spec freeze_actions(phase()) :: [freeze_action()]
  def freeze_actions("SPEC"),
    do: [:merge_phase_pr_into_base, :delete_phase_sub_branch, :emit_phase_freeze_message]

  def freeze_actions("PLAN"),
    do: [:merge_phase_pr_into_base, :delete_phase_sub_branch, :emit_phase_freeze_message]

  def freeze_actions("CODE"),
    do: [:hold_open_for_review, :record_code_tree_hash, :emit_phase_freeze_message]

  def freeze_actions("REVIEW"),
    do: [:merge_code_pr_into_base, :delete_code_sub_branch, :emit_phase_freeze_message, :emit_task_completed]

  def freeze_actions(_other), do: []

  @doc """
  Returns `true` if the phase has its own sub-branch
  (`duet-phase/<id>/<phase>`). Per §9.1 only SPEC, PLAN, and CODE have
  phase sub-branches; REVIEW reuses the CODE PR.
  """
  @spec has_phase_branch?(phase()) :: boolean()
  def has_phase_branch?("SPEC"), do: true
  def has_phase_branch?("PLAN"), do: true
  def has_phase_branch?("CODE"), do: true
  def has_phase_branch?("REVIEW"), do: false
  def has_phase_branch?(_other), do: false

  @doc """
  Validates a phase transition: `from` must be the current phase and `to`
  must be either the same phase (a re-entry, e.g. for retries) or its
  canonical next phase. Returns `:ok` or `{:error, reason}`.

  Order of precedence:
  1. If either is unknown → `{:error, :unknown_phase}`.
  2. If `from == to` → `:ok` (re-entry).
  3. If `next_phase(from) == to` → `:ok` (canonical forward step).
  4. Otherwise → `{:error, :invalid_transition}`.
  """
  @spec validate_transition(phase(), phase()) :: :ok | {:error, atom()}
  def validate_transition(from, to) do
    cond do
      not known_phase?(from) -> {:error, :unknown_phase}
      not known_phase?(to) -> {:error, :unknown_phase}
      from == to -> :ok
      next_phase(from) == to -> :ok
      true -> {:error, :invalid_transition}
    end
  end

  defp known_phase?(phase) when is_binary(phase), do: phase in @phase_order
  defp known_phase?(_other), do: false
end
