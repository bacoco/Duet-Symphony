defmodule SymphonyElixir.Duet.EventLog do
  @moduledoc """
  Append-only JSONL event log for Duet task state.
  """

  alias SymphonyElixir.Linear.Issue

  @default_root ".duet/logs"

  @type event :: map()

  @spec default_root() :: Path.t()
  def default_root do
    default_root(File.cwd!())
  end

  @spec default_root(Path.t()) :: Path.t()
  def default_root(logs_root) when is_binary(logs_root) do
    Path.join(logs_root, @default_root)
  end

  @spec root() :: Path.t()
  def root do
    Application.get_env(:symphony_elixir, :duet_event_log_root, default_root())
  end

  @spec set_root(Path.t()) :: :ok
  def set_root(root) when is_binary(root) do
    Application.put_env(:symphony_elixir, :duet_event_log_root, root)
    :ok
  end

  @spec path_for_task(String.t()) :: Path.t()
  def path_for_task(task_id) when is_binary(task_id) do
    root()
    |> Path.join("tasks")
    |> Path.join(safe_task_id(task_id))
    |> Path.join("events.jsonl")
  end

  @spec append(String.t() | Issue.t() | map(), String.t(), map()) :: {:ok, event()} | {:error, term()}
  def append(task_or_issue, kind, attrs \\ %{}) when is_binary(kind) and is_map(attrs) do
    task_id = task_id(task_or_issue)

    event =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "ts" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "task_id" => task_id,
        "kind" => kind
      })

    path = path_for_task(task_id)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(event) <> "\n", [:append]) do
      {:ok, event}
    end
  end

  @spec read(String.t() | Issue.t() | map()) :: {:ok, [event()]} | {:error, term()}
  def read(task_or_issue) do
    path =
      task_or_issue
      |> task_id()
      |> path_for_task()

    case File.read(path) do
      {:ok, contents} ->
        events =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        {:ok, events}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp task_id(%Issue{id: id, identifier: identifier}), do: id || identifier
  defp task_id(%{"id" => id, "identifier" => identifier}), do: id || identifier
  defp task_id(%{id: id, identifier: identifier}), do: id || identifier
  defp task_id(task_id) when is_binary(task_id), do: task_id

  defp safe_task_id(task_id) do
    String.replace(task_id, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
