defmodule SymphonyElixir.Duet.Trailer do
  @moduledoc """
  Parses Duet structured response trailers per spec §10.1.

  An agent response ends with a fenced trailer block:

      ---DUET-TRAILER---
      verdict: APPROVE | REQUEST_CHANGES
      confidence: 0.0..1.0
      summary: <one-line summary of position>
      unresolved: [<list of unresolved concerns; empty if APPROVE>]
      ---END-DUET-TRAILER---

  Parsing rules:

  * When several trailer blocks appear in the response, only the **last
    syntactically valid** block is considered. Earlier blocks (or a
    malformed final block followed by a valid earlier one) are ignored.
  * The selected block's start marker MUST appear within the final 50
    lines of the response (§10.1.2). Otherwise the parser returns
    `{:error, :position_invalid}`.
  * `tree_hash` is intentionally not part of the trailer schema. The
    orchestrator binds the trailer to the commit tree-hash observed at
    dispatch time (§10.1.2); this module never trusts an agent-provided
    hash.

  The semantic checks from §10.1.1 are surfaced as a list of issues the
  caller can act on:

  * `:low_confidence_approve` — APPROVE with `confidence < 0.3`. The
    verdict is accepted; the orchestrator should emit a
    `low_confidence_approve` event.
  * `:synthesized_no_details` — REQUEST_CHANGES with an empty unresolved
    list. The trailer's `unresolved` field is set to
    `["no_details_provided"]` before being returned.
  * `{:approve_with_unresolved, original}` — APPROVE with a non-empty
    unresolved list. The orchestrator should re-prompt once; if the
    second response still contradicts, treat as REQUEST_CHANGES with the
    original unresolved list preserved.
  """

  @start_marker "---DUET-TRAILER---"
  @end_marker "---END-DUET-TRAILER---"
  @max_lines_from_end 50
  @low_confidence_threshold 0.3

  defstruct [:verdict, :confidence, :summary, :unresolved]

  @type verdict :: :approve | :request_changes
  @type t :: %__MODULE__{
          verdict: verdict(),
          confidence: float() | nil,
          summary: String.t(),
          unresolved: [String.t()]
        }

  @type issue ::
          :low_confidence_approve
          | :synthesized_no_details
          | {:approve_with_unresolved, [String.t()]}

  @type result ::
          {:ok, t(), [issue()]}
          | {:error, :missing | :malformed | :position_invalid}

  @spec parse(String.t()) :: result()
  def parse(text) when is_binary(text) do
    lines = String.split(text, "\n", trim: false)
    blocks = locate_blocks(lines)

    case last_valid_block(blocks, lines) do
      nil ->
        if blocks == [], do: {:error, :missing}, else: {:error, :malformed}

      {trailer, start_index} ->
        if start_index_in_tail?(start_index, length(lines)) do
          classify(trailer)
        else
          {:error, :position_invalid}
        end
    end
  end

  defp locate_blocks(lines) do
    {blocks, _open} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {line, index}, {blocks, current_start} ->
        trimmed = String.trim(line)

        cond do
          trimmed == @start_marker ->
            {blocks, index}

          trimmed == @end_marker and is_integer(current_start) ->
            {[{current_start, index} | blocks], nil}

          true ->
            {blocks, current_start}
        end
      end)

    Enum.reverse(blocks)
  end

  defp last_valid_block(blocks, lines) do
    blocks
    |> Enum.reverse()
    |> Enum.find_value(fn {start_index, end_index} ->
      body = Enum.slice(lines, (start_index + 1)..(end_index - 1))

      case parse_body(body) do
        {:ok, trailer} -> {trailer, start_index}
        {:error, _reason} -> nil
      end
    end)
  end

  defp parse_body(body_lines) do
    fields =
      body_lines
      |> Enum.map(&parse_line/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    with {:ok, verdict} <- extract_verdict(fields),
         {:ok, summary} <- extract_summary(fields),
         {:ok, unresolved} <- extract_unresolved(fields),
         {:ok, confidence} <- extract_confidence(fields) do
      {:ok,
       %__MODULE__{
         verdict: verdict,
         confidence: confidence,
         summary: summary,
         unresolved: unresolved
       }}
    end
  end

  defp parse_line(line) do
    case String.split(String.trim(line), ":", parts: 2) do
      [key, value] -> {String.trim(key), String.trim(value)}
      _ -> nil
    end
  end

  defp extract_verdict(%{"verdict" => "APPROVE"}), do: {:ok, :approve}
  defp extract_verdict(%{"verdict" => "REQUEST_CHANGES"}), do: {:ok, :request_changes}
  defp extract_verdict(_fields), do: {:error, :invalid_verdict}

  defp extract_summary(%{"summary" => summary}) when is_binary(summary) and summary != "",
    do: {:ok, summary}

  defp extract_summary(_fields), do: {:error, :missing_summary}

  defp extract_unresolved(%{"unresolved" => raw}) when is_binary(raw), do: {:ok, parse_list(raw)}
  defp extract_unresolved(_fields), do: {:ok, []}

  defp extract_confidence(%{"confidence" => raw}) when is_binary(raw) do
    case Float.parse(raw) do
      {value, _rest} when value >= 0.0 and value <= 1.0 -> {:ok, value}
      _ -> {:error, :invalid_confidence}
    end
  end

  defp extract_confidence(_fields), do: {:ok, nil}

  defp parse_list(raw) do
    raw
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&strip_quotes/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_quotes(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp start_index_in_tail?(start_index, total_lines) do
    total_lines - start_index <= @max_lines_from_end
  end

  defp classify(%__MODULE__{} = trailer) do
    {final_trailer, issues} =
      {trailer, []}
      |> apply_check(&approve_with_unresolved/1)
      |> apply_check(&request_changes_without_details/1)
      |> apply_check(&low_confidence_approve/1)

    {:ok, final_trailer, Enum.reverse(issues)}
  end

  defp apply_check({trailer, issues}, check) do
    case check.(trailer) do
      {:keep, issue} -> {trailer, [issue | issues]}
      {:replace, new_trailer, issue} -> {new_trailer, [issue | issues]}
      :pass -> {trailer, issues}
    end
  end

  defp approve_with_unresolved(%__MODULE__{verdict: :approve, unresolved: unresolved})
       when unresolved != [] do
    {:keep, {:approve_with_unresolved, unresolved}}
  end

  defp approve_with_unresolved(_trailer), do: :pass

  defp request_changes_without_details(%__MODULE__{verdict: :request_changes, unresolved: []} = trailer) do
    {:replace, %__MODULE__{trailer | unresolved: ["no_details_provided"]}, :synthesized_no_details}
  end

  defp request_changes_without_details(_trailer), do: :pass

  defp low_confidence_approve(%__MODULE__{verdict: :approve, confidence: confidence})
       when is_float(confidence) and confidence < @low_confidence_threshold do
    {:keep, :low_confidence_approve}
  end

  defp low_confidence_approve(_trailer), do: :pass
end
