defmodule SymphonyElixir.DuetTurnDriverCodexAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.TurnDrivers.CodexAppServer

  test "collects Codex App Server agent message deltas into response text" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-codex-driver-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "DUET-CODEX")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-driver.trace")
      test_pid = self()

      File.mkdir_p!(workspace)
      System.put_env("DUET_CODEX_DRIVER_TRACE", trace_file)

      on_exit(fn ->
        System.delete_env("DUET_CODEX_DRIVER_TRACE")
      end)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${DUET_CODEX_DRIVER_TRACE:-/tmp/duet-codex-driver.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-duet"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-duet"}}}'
            printf '%s\\n' '{"method":"codex/event/agent_message_delta","params":{"msg":{"payload":{"delta":"Drafted SPEC body\\n\\n"}}}}'
            printf '%s\\n' '{"method":"codex/event/agent_message_content_delta","params":{"msg":{"content":"---DUET-TRAILER---\\nverdict: APPROVE\\nconfidence: 0.8\\nsummary: Ready\\nunresolved: []\\n---END-DUET-TRAILER---"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-duet-codex-driver",
        identifier: "DUET-CODEX",
        title: "Drive Codex",
        description: "Collect streamed text",
        state: "In Progress",
        url: "https://example.org/issues/DUET-CODEX"
      }

      assert {:ok, response} =
               CodexAppServer.drive_turn("Prompt body",
                 workspace: workspace,
                 issue: issue,
                 on_message: fn message -> send(test_pid, {:codex_message, message}) end
               )

      assert response =~ "Drafted SPEC body"
      assert response =~ "---DUET-TRAILER---"
      assert response =~ "summary: Ready"

      assert_receive {:codex_message, %{event: :session_started, session_id: "thread-duet-turn-duet"}}, 500
      assert_receive {:codex_message, %{event: :notification, payload: %{"method" => "codex/event/agent_message_delta"}}}, 500

      trace = File.read!(trace_file)
      assert trace =~ ~s("method":"turn/start")
      assert trace =~ "Prompt body"
    after
      File.rm_rf(test_root)
    end
  end

  test "returns a clear error when required options are missing" do
    assert {:error, {:missing_required_opt, :workspace}} = CodexAppServer.drive_turn("prompt", [])
    assert {:error, {:missing_required_opt, :issue}} = CodexAppServer.drive_turn("prompt", workspace: "/tmp/workspace")
  end
end
