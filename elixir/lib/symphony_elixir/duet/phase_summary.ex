defmodule SymphonyElixir.Duet.PhaseSummary do
  @moduledoc """
  Pure helpers for measuring phase artifacts and producing the v1 naive
  summary text used by `Duet.PhaseFreezeMessage`.

  Spec §8.4 says implementations MAY use a fixed truncation strategy as a
  v1 simplification. This module is that strategy: take the first N words
  of the artifact (or the unified diff for CODE) and append a marker line
  noting the truncation. A future slice can replace `summarize/2` with an
  LLM-driven summarizer without changing the call site.

  Word counting splits on whitespace (`~r/\\s+/`); diff line counting is
  the raw line count of the unified diff text (including hunk headers and
  context lines). Both are deliberately simple — they are inputs to the
  §8.4 adaptive word-target calculation, not precise metrics.
  """

  @truncation_marker "\n\n[summary truncated to first %{words} words per spec §8.4 v1 strategy]"

  @type strategy :: :spec | :plan | :code

  @spec word_count(String.t()) :: non_neg_integer()
  def word_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  @spec diff_line_count(String.t()) :: non_neg_integer()
  def diff_line_count(diff) when is_binary(diff) do
    lines = String.split(diff, "\n")

    case lines do
      [""] -> 0
      _ -> if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
    end
  end

  @doc """
  Produces a naive truncation-based summary of `text` capped at `target_words`.

  - If `word_count(text) <= target_words`, returns the trimmed text as-is.
  - Otherwise returns the first `target_words` words joined by single spaces,
    followed by the truncation marker `[summary truncated to first <N> words
    per spec §8.4 v1 strategy]`.

  Empty / whitespace-only input returns an empty string with no marker.
  """
  @spec summarize(String.t(), pos_integer()) :: String.t()
  def summarize(text, target_words)
      when is_binary(text) and is_integer(target_words) and target_words > 0 do
    words = String.split(text, ~r/\s+/, trim: true)

    case words do
      [] ->
        ""

      _ ->
        if length(words) <= target_words do
          Enum.join(words, " ")
        else
          truncated = words |> Enum.take(target_words) |> Enum.join(" ")
          truncated <> truncation_marker(target_words)
        end
    end
  end

  defp truncation_marker(target_words) do
    String.replace(@truncation_marker, "%{words}", Integer.to_string(target_words))
  end
end
