defmodule SymphonyElixir.Duet.Convergence do
  @moduledoc """
  Evaluates the spec §9.3 split-signal model and the §10.2 convergence rule.

  Both agents emit machine-readable verdicts, but through different GitHub
  channels because GitHub does not allow PR authors to submit `APPROVE`
  reviews on their own PRs. The spec splits the convergence signal:

  * The **Reviewer** (whichever agent is *not* the PR author for that
    phase) submits a GitHub PR review via the standard review API. State
    is `APPROVE` ↔ trailer `verdict: APPROVE`; `REQUEST_CHANGES` ↔
    trailer `verdict: REQUEST_CHANGES`.
  * The **Author** (the agent who pushed the artifact commits, and is
    therefore the PR creator) emits their verdict as a
    `---DUET-TRAILER---` block (§10.1) inside a regular PR issue-comment,
    not a review.

  Per §10.2 a phase reaches *convergence* iff both of the following hold
  for the same revision of the artifact within the same cycle:

  1. The Reviewer's GitHub PR review state is `APPROVED` (equivalent to
     trailer `verdict: APPROVE`), AND
  2. The Author's most recent `---DUET-TRAILER---` comment on the PR
     carries `verdict: APPROVE`.

  Both signals MUST reference the same revision (commit tree-hash on the
  phase sub-branch's HEAD). When at least one tree-hash is missing we
  cannot prove the same-revision invariant, so the rule treats that as
  `:tree_hash_mismatch`.
  """

  @approved_state "APPROVED"
  @changes_requested_state "CHANGES_REQUESTED"

  defstruct [
    :reviewer_verdict,
    :reviewer_tree_hash,
    :author_verdict,
    :author_tree_hash
  ]

  @type verdict :: :approve | :request_changes
  @type signal :: %{verdict: verdict() | nil, tree_hash: String.t() | nil}

  @type t :: %__MODULE__{
          reviewer_verdict: verdict() | nil,
          reviewer_tree_hash: String.t() | nil,
          author_verdict: verdict() | nil,
          author_tree_hash: String.t() | nil
        }

  @type not_converged_reason ::
          :reviewer_not_approved
          | :author_not_approved
          | :tree_hash_mismatch
          | :missing_reviewer_signal
          | :missing_author_signal

  @type result :: :converged | {:not_converged, not_converged_reason()}

  @doc """
  Maps a GitHub PR review `state` string to a Duet verdict atom.

  GitHub returns review states as uppercase strings. Only the exact
  values `"APPROVED"` and `"CHANGES_REQUESTED"` are mapped to verdicts;
  every other state (including `"COMMENTED"`, `"PENDING"`, `"DISMISSED"`,
  unknown values, and any non-uppercase variant) is reported as
  `:other`. The strictness is deliberate: relaxing the mapping would
  silently absorb GitHub API changes that the orchestrator should
  surface instead.
  """
  @spec from_github_review_state(String.t()) :: verdict() | :other
  def from_github_review_state(@approved_state), do: :approve
  def from_github_review_state(@changes_requested_state), do: :request_changes
  def from_github_review_state(state) when is_binary(state), do: :other

  @doc """
  Evaluates the §10.2 convergence rule against a pair of signals.

  Returns `:converged` only when both verdicts are `:approve` *and* both
  tree-hashes are non-nil binaries that compare equal. Otherwise returns
  `{:not_converged, reason}` where `reason` is one of:

  * `:missing_reviewer_signal` — no reviewer verdict has been recorded.
  * `:missing_author_signal` — reviewer verdict is present, author
    verdict is missing.
  * `:reviewer_not_approved` — reviewer verdict is `:request_changes`.
  * `:author_not_approved` — author verdict is `:request_changes`.
  * `:tree_hash_mismatch` — both verdicts are `:approve` but the
    tree-hashes differ or at least one is `nil` (we cannot prove the
    same-revision invariant).
  """
  @spec evaluate(t()) :: result()
  def evaluate(%__MODULE__{reviewer_verdict: nil}), do: {:not_converged, :missing_reviewer_signal}

  def evaluate(%__MODULE__{author_verdict: nil}), do: {:not_converged, :missing_author_signal}

  def evaluate(%__MODULE__{reviewer_verdict: reviewer_verdict}) when reviewer_verdict != :approve do
    {:not_converged, :reviewer_not_approved}
  end

  def evaluate(%__MODULE__{author_verdict: author_verdict}) when author_verdict != :approve do
    {:not_converged, :author_not_approved}
  end

  def evaluate(%__MODULE__{reviewer_tree_hash: hash, author_tree_hash: hash}) when is_binary(hash) do
    :converged
  end

  def evaluate(%__MODULE__{}), do: {:not_converged, :tree_hash_mismatch}
end
