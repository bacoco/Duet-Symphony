defmodule SymphonyElixir.DuetTurnDriverClaudeCodeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.TurnDrivers.ClaudeCode

  defmodule Runner do
    @behaviour SymphonyElixir.Duet.TurnDrivers.ClaudeCode.Runner

    @impl SymphonyElixir.Duet.TurnDrivers.ClaudeCode.Runner
    def run(args, input, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:claude_run, args, input, opts})
      Keyword.fetch!(opts, :result)
    end
  end

  describe "drive_turn/2" do
    test "invokes Claude Code print stream-json with prompt on stdin" do
      stream = """
      {"type":"system","subtype":"init"}
      {"type":"assistant","message":{"content":[{"type":"text","text":"Drafted SPEC\\n"}]}}
      {"type":"assistant","message":{"content":[{"type":"text","text":"---DUET-TRAILER---\\nverdict: APPROVE\\nconfidence: 0.9\\nsummary: Ready\\nunresolved: []\\n---END-DUET-TRAILER---"}]}}
      """

      assert {:ok, response} =
               ClaudeCode.drive_turn("Prompt body",
                 workspace: "/tmp/duet-workspace",
                 runner: Runner,
                 test_pid: self(),
                 result: {:ok, stream},
                 model: "claude-sonnet-4-5",
                 resume: "session-123",
                 permission_mode: "acceptEdits",
                 extra_args: ["--allowedTools", "Read,Grep"]
               )

      assert response =~ "Drafted SPEC"
      assert response =~ "---DUET-TRAILER---"
      assert response =~ "summary: Ready"

      assert_receive {:claude_run, args, "Prompt body", opts}

      assert args == [
               "--print",
               "--output-format",
               "stream-json",
               "--model",
               "claude-sonnet-4-5",
               "--resume",
               "session-123",
               "--permission-mode",
               "acceptEdits",
               "--allowedTools",
               "Read,Grep"
             ]

      assert Keyword.fetch!(opts, :cwd) == "/tmp/duet-workspace"
    end

    test "returns a clear error when workspace is missing" do
      assert {:error, {:missing_required_opt, :workspace}} = ClaudeCode.drive_turn("prompt", [])
    end

    test "propagates runner errors" do
      assert {:error, :claude_not_found} =
               ClaudeCode.drive_turn("prompt",
                 workspace: "/tmp/workspace",
                 runner: Runner,
                 test_pid: self(),
                 result: {:error, :claude_not_found}
               )
    end
  end

  describe "parse_stream/1" do
    test "uses assistant content chunks before result summaries" do
      stream = """
      {"type":"assistant","message":{"content":[{"type":"text","text":"chunk one "},{"type":"text","text":"chunk two"}]}}
      {"type":"result","subtype":"success","result":"duplicated full result"}
      """

      assert ClaudeCode.parse_stream(stream) == {:ok, "chunk one chunk two"}
    end

    test "falls back to result text when no assistant chunks are present" do
      stream = ~s({"type":"result","subtype":"success","result":"final result text"})

      assert ClaudeCode.parse_stream(stream) == {:ok, "final result text"}
    end

    test "supports content block delta events" do
      stream = """
      {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello "}}
      {"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}
      """

      assert ClaudeCode.parse_stream(stream) == {:ok, "hello world"}
    end

    test "returns invalid JSON as data" do
      assert {:error, {:invalid_stream_json, "not-json"}} = ClaudeCode.parse_stream("not-json")
    end

    test "returns Claude error events when no response text exists" do
      stream = ~s({"type":"error","error":{"message":"rate limited"}})

      assert {:error, {:claude_error, %{"error" => %{"message" => "rate limited"}}}} =
               ClaudeCode.parse_stream(stream)
    end

    test "rejects empty response streams" do
      assert {:error, :empty_response} = ClaudeCode.parse_stream(~s({"type":"system"}))
    end
  end

  describe "args/1" do
    test "returns the minimum required command shape by default" do
      assert ClaudeCode.args([]) == ["--print", "--output-format", "stream-json"]
    end

    test "ignores malformed extra args" do
      assert ClaudeCode.args(extra_args: "--debug") == ["--print", "--output-format", "stream-json"]
    end
  end
end
