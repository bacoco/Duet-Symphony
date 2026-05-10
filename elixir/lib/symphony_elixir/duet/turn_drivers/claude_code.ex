defmodule SymphonyElixir.Duet.TurnDrivers.ClaudeCode do
  @moduledoc """
  `SymphonyElixir.Duet.TurnDriver` implementation backed by Claude Code.

  This adapter invokes Claude Code in non-interactive mode with the spec-backed
  structured stream command:

      claude --print --output-format stream-json

  The prompt is written to stdin so large phase prompts do not need shell
  quoting. The driver only returns raw assistant response text; trailer parsing,
  event logging, convergence, and retry decisions stay in the Duet pair loop.

  Required options:

  * `:workspace` — task workspace path used as the command cwd.

  Supported options:

  * `:runner` — injected `ClaudeCode.Runner` module for tests.
  * `:executable` — Claude binary name/path for the system runner.
  * `:model` — appended as `--model <model>`.
  * `:resume` — appended as `--resume <session>`.
  * `:permission_mode` — appended as `--permission-mode <mode>`.
  * `:extra_args` — additional raw Claude CLI args appended last.

  Unknown options pass through to the runner. The production runner treats
  `:cwd` as a `System.cmd/3` working directory override, but `drive_turn/2`
  always supplies it from `:workspace`.
  """

  @behaviour SymphonyElixir.Duet.TurnDriver

  alias SymphonyElixir.Duet.TurnDriver
  alias SymphonyElixir.Duet.TurnDrivers.ClaudeCode.SystemRunner

  @type decoded_event :: map()

  @impl TurnDriver
  @spec drive_turn(String.t(), keyword()) :: TurnDriver.result()
  def drive_turn(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, workspace} <- fetch_workspace(opts),
         {:ok, output} <- runner(opts).run(args(opts), prompt, runner_opts(opts, workspace)) do
      parse_stream(output)
    end
  end

  @doc """
  Parse Claude Code `stream-json` output into the raw assistant response text.
  """
  @spec parse_stream(String.t()) :: TurnDriver.result()
  def parse_stream(output) when is_binary(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> decode_lines()
    |> response_from_events()
  end

  @spec args(keyword()) :: [String.t()]
  def args(opts) when is_list(opts) do
    ["--print", "--output-format", "stream-json"]
    |> append_option("--model", Keyword.get(opts, :model))
    |> append_option("--resume", Keyword.get(opts, :resume))
    |> append_option("--permission-mode", Keyword.get(opts, :permission_mode))
    |> append_extra_args(Keyword.get(opts, :extra_args, []))
  end

  defp fetch_workspace(opts) do
    case Keyword.fetch(opts, :workspace) do
      {:ok, workspace} when is_binary(workspace) and workspace != "" -> {:ok, workspace}
      _ -> {:error, {:missing_required_opt, :workspace}}
    end
  end

  defp runner(opts), do: Keyword.get(opts, :runner, SystemRunner)

  defp runner_opts(opts, workspace) do
    opts
    |> Keyword.delete(:workspace)
    |> Keyword.put(:cwd, workspace)
  end

  defp append_option(args, _flag, nil), do: args
  defp append_option(args, _flag, ""), do: args
  defp append_option(args, flag, value) when is_binary(value), do: args ++ [flag, value]

  defp append_extra_args(args, extra_args) when is_list(extra_args), do: args ++ extra_args
  defp append_extra_args(args, _extra_args), do: args

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> {:cont, {:ok, [event | events]}}
        {:ok, _other} -> {:halt, {:error, {:invalid_stream_event, line}}}
        {:error, _reason} -> {:halt, {:error, {:invalid_stream_json, line}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp response_from_events({:error, reason}), do: {:error, reason}

  defp response_from_events({:ok, events}) do
    cond do
      response_text(events) != "" -> {:ok, response_text(events)}
      result_text(events) != "" -> {:ok, result_text(events)}
      error_event(events) != nil -> {:error, {:claude_error, error_event(events)}}
      true -> {:error, :empty_response}
    end
  end

  defp response_text(events) do
    events
    |> Enum.flat_map(&assistant_texts/1)
    |> Enum.join("")
  end

  defp result_text(events) do
    events
    |> Enum.find_value("", fn event ->
      case map_value(event, ["result", :result]) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp error_event(events) do
    Enum.find(events, fn event ->
      map_value(event, ["type", :type]) == "error"
    end)
  end

  defp assistant_texts(event) do
    case map_value(event, ["type", :type]) do
      "assistant" -> event |> map_value(["message", :message]) |> message_texts()
      "content_block_delta" -> event |> map_value(["delta", :delta]) |> content_delta_texts()
      _ -> []
    end
  end

  defp message_texts(message) when is_map(message) do
    message
    |> map_value(["content", :content])
    |> content_texts()
  end

  defp message_texts(_message), do: []

  defp content_texts(content) when is_binary(content), do: [content]

  defp content_texts(content) when is_list(content) do
    Enum.flat_map(content, fn
      block when is_map(block) -> block_texts(block)
      _other -> []
    end)
  end

  defp content_texts(_content), do: []

  defp block_texts(block) do
    case map_value(block, ["text", :text]) do
      text when is_binary(text) -> [text]
      _ -> content_delta_texts(block)
    end
  end

  defp content_delta_texts(delta) when is_map(delta) do
    case map_value(delta, ["text", :text]) do
      text when is_binary(text) -> [text]
      _ -> []
    end
  end

  defp content_delta_texts(_delta), do: []

  defp map_value(data, keys) when is_map(data) do
    Enum.find_value(keys, fn key ->
      case fetch_map_key(data, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_value(_data, _keys), do: nil

  defp fetch_map_key(data, key) do
    cond do
      Map.has_key?(data, key) ->
        {:ok, Map.fetch!(data, key)}

      is_atom(key) and Map.has_key?(data, Atom.to_string(key)) ->
        {:ok, Map.fetch!(data, Atom.to_string(key))}

      is_binary(key) ->
        atom_key = String.to_existing_atom(key)

        if Map.has_key?(data, atom_key) do
          {:ok, Map.fetch!(data, atom_key)}
        else
          :error
        end

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end
end
