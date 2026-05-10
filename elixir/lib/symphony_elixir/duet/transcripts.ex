defmodule SymphonyElixir.Duet.Transcripts do
  @moduledoc """
  Per-turn transcript audit per spec §13.2.

  Each call to `write/6` records the full prompt + response for a turn at
  `<log_dir>/tasks/<task_id>/transcripts/<phase>-<cycle>-<actor>.md`.

  The log root is shared with `SymphonyElixir.Duet.EventLog`; relocating
  via `EventLog.set_root/1` (e.g. through `--logs-root`) moves transcripts
  too.

  Re-prompts within the same `(phase, cycle, actor)` triple overwrite the
  prior transcript file. The intent is "the latest agent response captured
  for this turn"; multi-attempt audit lives in the event log via
  `trailer_rejected` events plus subsequent `turn_response` entries.
  """

  alias SymphonyElixir.Duet.EventLog
  alias SymphonyElixir.Linear.Issue

  @aws_access_key_pattern ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/
  @pem_private_key_pattern ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----/s
  @generic_secret_pattern ~r/(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|token)\b\s*[:=]\s*["']?[^"'\s]+["']?/

  @type write_result :: {:ok, Path.t()} | {:error, term()}

  @spec root() :: Path.t()
  def root, do: EventLog.root()

  @spec path_for_turn(String.t() | Issue.t() | map(), String.t(), pos_integer(), String.t()) :: Path.t()
  def path_for_turn(task_or_issue, phase, cycle, actor)
      when is_binary(phase) and is_integer(cycle) and cycle > 0 and is_binary(actor) do
    task_id = task_id(task_or_issue)
    filename = "#{phase}-#{cycle}-#{actor}.md"

    root()
    |> Path.join("tasks")
    |> Path.join(safe_task_id(task_id))
    |> Path.join("transcripts")
    |> Path.join(filename)
  end

  @spec write(
          String.t() | Issue.t() | map(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: write_result()
  def write(task_or_issue, phase, cycle, actor, prompt, response)
      when is_binary(phase) and is_integer(cycle) and cycle > 0 and is_binary(actor) and
             is_binary(prompt) and is_binary(response) do
    task_id = task_id(task_or_issue)
    path = path_for_turn(task_id, phase, cycle, actor)
    contents = render(task_id, phase, cycle, actor, prompt, response)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents) do
      {:ok, path}
    end
  end

  @spec read(String.t() | Issue.t() | map(), String.t(), pos_integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def read(task_or_issue, phase, cycle, actor) do
    task_or_issue
    |> path_for_turn(phase, cycle, actor)
    |> File.read()
  end

  @doc """
  Redacts known credential patterns before prompt/response text is persisted
  to transcript audit files.
  """
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text) do
    text
    |> redact_pattern(@pem_private_key_pattern, "[REDACTED_PEM_PRIVATE_KEY]")
    |> redact_pattern(@aws_access_key_pattern, "[REDACTED_AWS_ACCESS_KEY]")
    |> redact_pattern(@generic_secret_pattern, "[REDACTED_SECRET]")
  end

  defp redact_pattern(text, pattern, replacement), do: Regex.replace(pattern, text, replacement)

  defp render(task_id, phase, cycle, actor, prompt, response) do
    redacted_prompt = redact(prompt)
    redacted_response = redact(response)

    recorded_at =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    """
    # Turn transcript

    - Task: #{task_id}
    - Phase: #{phase}
    - Cycle: #{cycle}
    - Actor: #{actor}
    - Recorded at: #{recorded_at}

    ## Prompt

    #{String.trim_trailing(redacted_prompt)}

    ## Response

    #{String.trim_trailing(redacted_response)}
    """
  end

  defp task_id(%Issue{id: id, identifier: identifier}), do: id || identifier
  defp task_id(%{"id" => id, "identifier" => identifier}), do: id || identifier
  defp task_id(%{id: id, identifier: identifier}), do: id || identifier
  defp task_id(task_id) when is_binary(task_id), do: task_id

  defp safe_task_id(task_id) do
    String.replace(task_id, ~r/[^a-zA-Z0-9._-]/, "_")
  end
end
