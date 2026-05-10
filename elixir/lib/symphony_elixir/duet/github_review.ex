defmodule SymphonyElixir.Duet.GithubReview do
  @moduledoc """
  Pure parser for the GitHub PR Reviews API JSON.

  Used by the future convergence wiring to extract the binding §9.3
  Reviewer signal from `gh api ... /pulls/<n>/reviews`. Per spec §11.1
  the binding state is the latest non-dismissed review per identity.

  This module never makes HTTP calls; callers shell out via `gh` (or
  the GitHub HTTP API directly) and feed the decoded JSON array to
  `parse_reviews/1`.
  """

  defstruct [:id, :reviewer, :state, :commit_id, :submitted_at, :body]

  @type state :: String.t()
  @type t :: %__MODULE__{
          id: integer() | nil,
          reviewer: String.t(),
          state: state(),
          commit_id: String.t() | nil,
          submitted_at: DateTime.t() | nil,
          body: String.t() | nil
        }

  @approved_state "APPROVED"
  @changes_requested_state "CHANGES_REQUESTED"
  @dismissed_state "DISMISSED"
  @binding_states [@approved_state, @changes_requested_state]

  @doc """
  Parses a list of GitHub review JSON objects (each is a map with string
  keys) into a list of `t()` structs.

  Reviews with a missing/null `user` are skipped. Reviews where
  `user.login` is missing or non-binary, or where `state` is missing or
  non-binary, are skipped silently. Reviews with unparseable timestamps
  produce a struct whose `submitted_at` is `nil`.

  The result preserves input order. Inputs MUST use string keys
  (mirroring `Jason.decode!` output); atom-keyed maps are rejected.
  """
  @spec parse_reviews([map()]) :: [t()]
  def parse_reviews(json_array) when is_list(json_array) do
    Enum.flat_map(json_array, &parse_one/1)
  end

  defp parse_one(entry) when is_map(entry) do
    if atom_keyed?(entry) do
      raise ArgumentError,
            "SymphonyElixir.Duet.GithubReview.parse_reviews/1 expects string-keyed maps " <>
              "(as produced by Jason.decode!/1), got an atom-keyed map: #{inspect(entry)}"
    end

    with {:ok, reviewer} <- extract_reviewer(entry),
         {:ok, state} <- extract_state(entry) do
      [
        %__MODULE__{
          id: extract_id(entry),
          reviewer: reviewer,
          state: state,
          commit_id: extract_commit_id(entry),
          submitted_at: extract_submitted_at(entry),
          body: extract_body(entry)
        }
      ]
    else
      :skip -> []
    end
  end

  defp parse_one(_entry), do: []

  defp atom_keyed?(map) when map_size(map) == 0, do: false

  defp atom_keyed?(map) do
    Enum.any?(map, fn {key, _value} -> is_atom(key) and key not in [nil, true, false] end)
  end

  defp extract_reviewer(%{"user" => %{"login" => login}}) when is_binary(login), do: {:ok, login}
  defp extract_reviewer(_entry), do: :skip

  defp extract_state(%{"state" => state}) when is_binary(state), do: {:ok, state}
  defp extract_state(_entry), do: :skip

  defp extract_id(%{"id" => id}) when is_integer(id), do: id
  defp extract_id(_entry), do: nil

  defp extract_commit_id(%{"commit_id" => commit_id}) when is_binary(commit_id), do: commit_id
  defp extract_commit_id(_entry), do: nil

  defp extract_body(%{"body" => body}) when is_binary(body), do: body
  defp extract_body(_entry), do: nil

  defp extract_submitted_at(%{"submitted_at" => raw}) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp extract_submitted_at(_entry), do: nil

  @doc """
  Reduces a list of parsed reviews to the latest non-dismissed review
  per reviewer identity, keyed by `reviewer`.

  The order within the input list is the chronological order; for ties
  on `submitted_at` the later list position wins.

  DISMISSED reviews fully suppress that identity's signal — if the
  latest binding-state review for `claude-bot` is DISMISSED, the
  resulting map contains no entry for `claude-bot`.

  Reviews whose state is neither in `binding_states/0` nor `"DISMISSED"`
  (e.g. `"COMMENTED"`, `"PENDING"`) are ignored: they neither install
  nor remove an entry for that reviewer.
  """
  @spec latest_per_reviewer([t()]) :: %{String.t() => t()}
  def latest_per_reviewer(reviews) when is_list(reviews) do
    Enum.reduce(reviews, %{}, fn
      %__MODULE__{state: @dismissed_state, reviewer: reviewer}, acc ->
        Map.delete(acc, reviewer)

      %__MODULE__{state: state, reviewer: reviewer} = review, acc when state in @binding_states ->
        Map.put(acc, reviewer, review)

      %__MODULE__{}, acc ->
        acc
    end)
  end

  @doc """
  Maps a review's GitHub state string to the binding verdict atom.

  * `"APPROVED"` → `:approve`
  * `"CHANGES_REQUESTED"` → `:request_changes`
  * anything else (`"COMMENTED"`, `"DISMISSED"`, `"PENDING"`,
    `"approved"`, ...) → `:other`

  Accepts either a `t()` struct (whose `state` is read) or a raw state
  string. The strictness mirrors
  `SymphonyElixir.Duet.Convergence.from_github_review_state/1`: only the
  exact uppercase forms map to verdicts, every other value (including
  unknown states and any non-uppercase variant) is reported as `:other`.
  """
  @spec binding_state(t() | state()) :: :approve | :request_changes | :other
  def binding_state(%__MODULE__{state: state}), do: binding_state(state)
  def binding_state(@approved_state), do: :approve
  def binding_state(@changes_requested_state), do: :request_changes
  def binding_state(state) when is_binary(state), do: :other

  @doc """
  Returns the list of GitHub review states considered binding for §10.2
  convergence (i.e. `"APPROVED"` and `"CHANGES_REQUESTED"`).
  """
  @spec binding_states() :: [state()]
  def binding_states, do: @binding_states
end
