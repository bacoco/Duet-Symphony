defmodule SymphonyElixir.DuetTranscriptsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, Transcripts}

  setup do
    previous_root = Application.get_env(:symphony_elixir, :duet_event_log_root)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-transcripts-#{System.unique_integer([:positive])}"
      )

    log_root = Path.join(test_root, ".duet/logs")
    EventLog.set_root(log_root)

    on_exit(fn ->
      restore_app_env(:duet_event_log_root, previous_root)
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root, log_root: log_root}
  end

  test "root/0 delegates to EventLog.root/0", %{log_root: log_root} do
    assert Transcripts.root() == log_root
    assert Transcripts.root() == EventLog.root()
  end

  test "path_for_turn/4 returns the expected path for a string task_id", %{log_root: log_root} do
    path = Transcripts.path_for_turn("TASK-123", "SPEC", 1, "claude")

    assert path ==
             Path.join([log_root, "tasks", "TASK-123", "transcripts", "SPEC-1-claude.md"])
  end

  test "path_for_turn/4 accepts a %Issue{} struct and prefers :id", %{log_root: log_root} do
    issue = %Issue{id: "uuid-abc", identifier: "MT-900"}

    path = Transcripts.path_for_turn(issue, "PLAN", 2, "codex")

    assert path ==
             Path.join([log_root, "tasks", "uuid-abc", "transcripts", "PLAN-2-codex.md"])
  end

  test "path_for_turn/4 falls back to :identifier when :id is nil", %{log_root: log_root} do
    issue = %Issue{id: nil, identifier: "MT-901"}

    path = Transcripts.path_for_turn(issue, "spec", 1, "human")

    assert path ==
             Path.join([log_root, "tasks", "MT-901", "transcripts", "spec-1-human.md"])
  end

  test "path_for_turn/4 sanitizes task IDs containing slashes or other unsafe chars",
       %{log_root: log_root} do
    path = Transcripts.path_for_turn("acme/team:Repo Name", "SPEC", 1, "claude")

    assert path ==
             Path.join([
               log_root,
               "tasks",
               "acme_team_Repo_Name",
               "transcripts",
               "SPEC-1-claude.md"
             ])
  end

  test "write/6 creates the parent directory and writes the markdown file" do
    assert {:ok, path} =
             Transcripts.write("TASK-WRITE", "SPEC", 1, "claude", "Hello prompt", "Hello response")

    assert File.exists?(path)
    assert File.exists?(Path.dirname(path))
    assert path == Transcripts.path_for_turn("TASK-WRITE", "SPEC", 1, "claude")
  end

  test "write/6 content includes prompt and response verbatim plus metadata header" do
    prompt = "First line of prompt\n\n- a bullet\n- another"
    response = "Some response body\n\n```elixir\n:ok\n```"

    assert {:ok, path} =
             Transcripts.write("TASK-CONTENT", "PLAN", 3, "codex", prompt, response)

    contents = File.read!(path)

    assert contents =~ "# Turn transcript"
    assert contents =~ "- Task: TASK-CONTENT"
    assert contents =~ "- Phase: PLAN"
    assert contents =~ "- Cycle: 3"
    assert contents =~ "- Actor: codex"
    assert contents =~ ~r/- Recorded at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
    assert contents =~ "## Prompt"
    assert contents =~ prompt
    assert contents =~ "## Response"
    assert contents =~ response
    assert String.ends_with?(contents, "\n")
  end

  test "write/6 trims trailing whitespace from prompt and response" do
    prompt = "prompt body\n\n   \n"
    response = "response body\n\n\n"

    assert {:ok, path} =
             Transcripts.write("TASK-TRIM", "SPEC", 1, "claude", prompt, response)

    contents = File.read!(path)

    refute contents =~ "prompt body\n\n   \n"
    refute contents =~ "response body\n\n\n"
    assert contents =~ "prompt body"
    assert contents =~ "response body"
  end

  test "write/6 redacts known credential patterns before persisting transcript" do
    pem = """
    -----BEGIN PRIVATE KEY-----
    abc123
    -----END PRIVATE KEY-----
    """

    prompt = "api_key: sk-test-secret\nAWS key AKIA1234567890ABCDEF"
    response = "token=ghp_secret\n#{pem}"

    assert {:ok, path} =
             Transcripts.write("TASK-REDACT", "CODE", 1, "codex", prompt, response)

    contents = File.read!(path)

    refute contents =~ "sk-test-secret"
    refute contents =~ "AKIA1234567890ABCDEF"
    refute contents =~ "ghp_secret"
    refute contents =~ "abc123"
    assert contents =~ "[REDACTED_SECRET]"
    assert contents =~ "[REDACTED_AWS_ACCESS_KEY]"
    assert contents =~ "[REDACTED_PEM_PRIVATE_KEY]"
  end

  test "write/6 overwrites a previous transcript at the same path" do
    assert {:ok, path} =
             Transcripts.write("TASK-OVER", "SPEC", 1, "claude", "first prompt", "first response")

    assert File.read!(path) =~ "first response"

    assert {:ok, ^path} =
             Transcripts.write("TASK-OVER", "SPEC", 1, "claude", "second prompt", "second response")

    contents = File.read!(path)
    assert contents =~ "second prompt"
    assert contents =~ "second response"
    refute contents =~ "first prompt"
    refute contents =~ "first response"
  end

  test "read/4 returns the file contents" do
    assert {:ok, _path} =
             Transcripts.write("TASK-READ", "SPEC", 1, "claude", "the prompt", "the response")

    assert {:ok, contents} = Transcripts.read("TASK-READ", "SPEC", 1, "claude")
    assert contents =~ "the prompt"
    assert contents =~ "the response"
    assert contents =~ "- Task: TASK-READ"
  end

  test "read/4 returns {:error, :enoent} for a missing transcript" do
    assert {:error, :enoent} = Transcripts.read("TASK-MISSING", "SPEC", 1, "claude")
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
