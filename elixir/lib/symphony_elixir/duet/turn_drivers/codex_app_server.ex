defmodule SymphonyElixir.Duet.TurnDrivers.CodexAppServer do
  @moduledoc """
  `SymphonyElixir.Duet.TurnDriver` implementation backed by Codex App Server.

  The upstream `SymphonyElixir.Codex.AppServer` client owns JSON-RPC
  session startup, turn dispatch, tool handling, remote-worker support, and
  runtime update forwarding. This adapter keeps that behavior and adds the one
  Duet-specific responsibility required by `TurnDriver`: collect streamed
  agent message deltas into the raw response text that the pair loop will hand
  to `SymphonyElixir.Duet.Turn.record_response/6`.

  Required options:

  * `:workspace` — workspace path created by `SymphonyElixir.RunnerRuntime`.
  * `:issue` — issue map/struct used by App Server for turn metadata.

  Supported pass-through options:

  * `:worker_host` — remote worker host selected by `RunnerRuntime`.
  * `:tool_executor` — optional dynamic tool executor for tests/adapters.
  * `:on_message` — optional callback that still receives every App Server
    update after the driver has inspected it for response text.

  Unknown options are ignored so the pair loop can pass a shared option list to
  heterogeneous drivers.
  """

  @behaviour SymphonyElixir.Duet.TurnDriver

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Duet.TurnDriver

  @agent_message_methods ~w(
    codex/event/agent_message
    codex/event/agent_message_delta
    codex/event/agent_message_content_delta
  )

  @impl TurnDriver
  @spec drive_turn(String.t(), keyword()) :: TurnDriver.result()
  def drive_turn(prompt, opts) when is_binary(prompt) and is_list(opts) do
    with {:ok, workspace} <- fetch_required(opts, :workspace),
         {:ok, issue} <- fetch_required(opts, :issue),
         {:ok, collector} <- Agent.start_link(fn -> [] end) do
      try do
        do_drive_turn(prompt, workspace, issue, opts, collector)
      after
        Agent.stop(collector)
      end
    end
  end

  defp do_drive_turn(prompt, workspace, issue, opts, collector) do
    app_server_opts = app_server_opts(opts, collector)

    case AppServer.run(workspace, prompt, issue, app_server_opts) do
      {:ok, _result} ->
        response_text = collected_response(collector)

        if response_text == "" do
          {:error, :empty_response}
        else
          {:ok, response_text}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} when key == :issue -> {:ok, value}
      _ -> {:error, {:missing_required_opt, key}}
    end
  end

  defp app_server_opts(opts, collector) do
    forward = Keyword.get(opts, :on_message, fn _message -> :ok end)

    opts
    |> Keyword.take([:worker_host, :tool_executor])
    |> Keyword.put(:on_message, fn message ->
      collect_message_delta(collector, message)
      forward.(message)
    end)
  end

  defp collect_message_delta(collector, message) do
    case response_delta(message) do
      nil -> :ok
      delta -> Agent.update(collector, &[delta | &1])
    end
  end

  defp response_delta(message) when is_map(message) do
    payload = map_value(message, ["payload", :payload])
    method = map_value(payload || %{}, ["method", :method])

    if method in @agent_message_methods do
      payload
      |> extract_first_path(delta_paths())
      |> normalize_delta()
    end
  end

  defp response_delta(_message), do: nil

  defp normalize_delta(delta) when is_binary(delta), do: delta
  defp normalize_delta(_delta), do: nil

  defp collected_response(collector) do
    collector
    |> Agent.get(&Enum.reverse/1)
    |> Enum.join("")
  end

  defp delta_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "content"],
      [:params, :content],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "msg", "outputDelta"],
      [:params, :msg, :outputDelta],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "outputDelta"],
      [:params, :msg, :payload, :outputDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, &map_path(payload, &1))
  end

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

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
