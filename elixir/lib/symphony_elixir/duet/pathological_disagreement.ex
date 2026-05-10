defmodule SymphonyElixir.Duet.PathologicalDisagreement do
  @moduledoc """
  Detects pathological disagreement per spec §10.5 — three consecutive
  cycles in the same phase producing the same `unresolved` list (after
  normalization).

  When the rule trips the orchestrator MUST:

  1. Halt the phase.
  2. Mark the task `failed` with `reason = pathological_disagreement`.
  3. Surface the unresolved list to the operator via the event log and
     (if configured) a notification hook.

  Restart requires operator action; the harness does not auto-recover
  from deadlock. This module is the pure detection step — it inspects
  the per-phase history of `unresolved` lists and reports whether the
  last `required_repeats/0` entries are identical after normalization.
  It performs no I/O and does not mutate state.

  ## Normalization

  Every entry is normalized before comparison so that incidental
  differences (casing, whitespace, item order, duplicates) do not mask a
  genuine deadlock. Each `unresolved` list is canonicalized as follows:

  * Each item is `String.trim/1`-ed.
  * Inner whitespace is collapsed to a single space (`~r/\\s+/` → `" "`).
  * Each item is lowercased via `String.downcase/1`.
  * Items that are empty after trim are dropped.
  * Duplicate items inside one cycle are coalesced via `Enum.uniq/1`.
  * The list is sorted via `Enum.sort/1` so item order does not matter.

  ## Edge cases

  * Empty history → `:ok`.
  * Fewer than `required_repeats/0` (3) entries → `:ok`.
  * Three consecutive empty `[]` lists → `{:pathological, []}`. The
    spec is mechanical: "string-equal after normalization" with `[]`
    against `[]` holds, so the rule fires. In practice this should not
    occur because §10.1.1 synthesizes `["no_details_provided"]` for any
    `REQUEST_CHANGES` trailer that omits details, so a real cycle never
    surfaces an empty unresolved list. Operators that see this signal
    should treat it as a serious harness bug rather than as a normal
    deadlock.
  """

  @required_repeats 3

  @type unresolved :: [String.t()]
  @type result :: {:pathological, unresolved()} | :ok

  @doc """
  Returns the number of consecutive identical `unresolved` lists
  required to declare pathological disagreement (`3`, per §10.5).
  """
  @spec required_repeats() :: pos_integer()
  def required_repeats, do: @required_repeats

  @doc """
  Examines the per-cycle history of `unresolved` lists for one phase.

  The history is ordered oldest → newest. Returns
  `{:pathological, normalized}` when the LAST `required_repeats/0`
  entries are all string-equal after normalization, otherwise `:ok`.

  Only the last `required_repeats/0` entries matter; earlier entries
  are ignored. See `normalize/1` for the canonical form used to
  compare entries.
  """
  @spec detect([unresolved()]) :: result()
  def detect(history) when is_list(history) do
    case Enum.take(history, -@required_repeats) do
      tail when length(tail) < @required_repeats ->
        :ok

      tail ->
        normalized = Enum.map(tail, &normalize/1)
        [first | rest] = normalized

        if Enum.all?(rest, &(&1 == first)) do
          {:pathological, first}
        else
          :ok
        end
    end
  end

  @doc """
  Normalizes a single `unresolved` list, exposed for callers that want
  to surface the canonical form in events / notifications.

  See the moduledoc for the full list of rules. Items that are not
  binaries are passed through `to_string/1` first so callers do not
  need to coerce up-front.
  """
  @spec normalize(unresolved()) :: unresolved()
  def normalize(unresolved) when is_list(unresolved) do
    unresolved
    |> Enum.map(&normalize_item/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_item(item) when is_binary(item) do
    item
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.downcase()
  end

  defp normalize_item(item), do: normalize_item(to_string(item))
end
