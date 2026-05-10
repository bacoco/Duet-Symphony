defmodule SymphonyElixir.DuetGhCliTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.GhCli

  defmodule MockRunner do
    @moduledoc false
    @behaviour SymphonyElixir.Duet.GhCli.Runner

    @impl SymphonyElixir.Duet.GhCli.Runner
    def run(args, opts) do
      send(self(), {:gh_cli_invoked, args, opts})

      case Process.get(:gh_cli_response) do
        {:ok, _stdout} = ok -> ok
        {:error, _reason} = err -> err
        nil -> {:ok, ""}
      end
    end
  end

  defp put_response(response), do: Process.put(:gh_cli_response, response)

  defp assert_invoked(expected_args, opts_check \\ &default_opts_check/1) do
    assert_received {:gh_cli_invoked, ^expected_args, opts}
    opts_check.(opts)
  end

  defp default_opts_check(_opts), do: :ok

  describe "open_pr/1" do
    setup do
      put_response({:ok, "https://github.com/owner/repo/pull/42\n"})

      :ok
    end

    test "builds the canonical argv and parses the PR number from the URL" do
      assert {:ok, %{number: 42, url: "https://github.com/owner/repo/pull/42"}} =
               GhCli.open_pr(
                 base: "duet-base/task-1",
                 head: "duet-base/task-1/spec",
                 title: "[duet:task-1] SPEC: Title",
                 body: "Body text",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked(
        [
          "pr",
          "create",
          "--base",
          "duet-base/task-1",
          "--head",
          "duet-base/task-1/spec",
          "--title",
          "[duet:task-1] SPEC: Title",
          "--body",
          "Body text"
        ],
        fn opts -> assert opts[:cwd] == "/tmp/ws" end
      )
    end

    test "adds --draft when draft: true" do
      {:ok, _} =
        GhCli.open_pr(
          base: "main",
          head: "feature",
          title: "T",
          body: "B",
          cwd: "/tmp/ws",
          draft: true,
          runner: MockRunner
        )

      assert_invoked(["pr", "create", "--base", "main", "--head", "feature", "--title", "T", "--body", "B", "--draft"])
    end

    test "adds --repo owner/repo when :repo is provided" do
      {:ok, _} =
        GhCli.open_pr(
          base: "main",
          head: "feature",
          title: "T",
          body: "B",
          cwd: "/tmp/ws",
          repo: "owner/repo",
          runner: MockRunner
        )

      assert_invoked([
        "pr",
        "create",
        "--repo",
        "owner/repo",
        "--base",
        "main",
        "--head",
        "feature",
        "--title",
        "T",
        "--body",
        "B"
      ])
    end

    test "returns {:error, {:missing_opt, :title}} when title is missing" do
      assert {:error, {:missing_opt, :title}} =
               GhCli.open_pr(base: "main", head: "feature", body: "B", cwd: "/tmp/ws", runner: MockRunner)
    end

    test "returns {:error, {:pr_url_not_found, _}} when stdout has no /pull/ line" do
      put_response({:ok, "no url here\n"})

      assert {:error, {:pr_url_not_found, "no url here\n"}} =
               GhCli.open_pr(
                 base: "main",
                 head: "feature",
                 title: "T",
                 body: "B",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end

    test "propagates {:error, {:exit_status, ...}} from the runner" do
      put_response({:error, {:exit_status, 1, "boom"}})

      assert {:error, {:exit_status, 1, "boom"}} =
               GhCli.open_pr(
                 base: "main",
                 head: "feature",
                 title: "T",
                 body: "B",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end

    test "propagates {:error, :gh_not_found} from the runner" do
      put_response({:error, :gh_not_found})

      assert {:error, :gh_not_found} =
               GhCli.open_pr(
                 base: "main",
                 head: "feature",
                 title: "T",
                 body: "B",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end
  end

  describe "mark_ready/1" do
    test "calls gh pr ready <number> and returns :ok" do
      put_response({:ok, ""})

      assert :ok = GhCli.mark_ready(number: 7, cwd: "/tmp/ws", runner: MockRunner)

      assert_invoked(["pr", "ready", "7"])
    end

    test "adds --repo when :repo is provided" do
      put_response({:ok, ""})

      assert :ok = GhCli.mark_ready(number: 7, cwd: "/tmp/ws", repo: "owner/repo", runner: MockRunner)

      assert_invoked(["pr", "ready", "7", "--repo", "owner/repo"])
    end

    test "propagates runner failure" do
      put_response({:error, {:exit_status, 1, "nope"}})

      assert {:error, {:exit_status, 1, "nope"}} =
               GhCli.mark_ready(number: 7, cwd: "/tmp/ws", runner: MockRunner)
    end
  end

  describe "merge_pr/1" do
    test "defaults to --merge" do
      put_response({:ok, ""})

      assert :ok = GhCli.merge_pr(number: 9, cwd: "/tmp/ws", runner: MockRunner)

      assert_invoked(["pr", "merge", "9", "--merge"])
    end

    test "uses --squash when method: squash" do
      put_response({:ok, ""})

      assert :ok = GhCli.merge_pr(number: 9, cwd: "/tmp/ws", method: "squash", runner: MockRunner)

      assert_invoked(["pr", "merge", "9", "--squash"])
    end

    test "uses --rebase when method: rebase" do
      put_response({:ok, ""})

      assert :ok = GhCli.merge_pr(number: 9, cwd: "/tmp/ws", method: "rebase", runner: MockRunner)

      assert_invoked(["pr", "merge", "9", "--rebase"])
    end

    test "rejects unknown methods" do
      assert {:error, {:invalid_merge_method, "ff-only"}} =
               GhCli.merge_pr(number: 9, cwd: "/tmp/ws", method: "ff-only", runner: MockRunner)
    end

    test "adds --delete-branch when delete_branch: true" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.merge_pr(
                 number: 9,
                 cwd: "/tmp/ws",
                 delete_branch: true,
                 runner: MockRunner
               )

      assert_invoked(["pr", "merge", "9", "--merge", "--delete-branch"])
    end

    test "supports --repo + --squash + --delete-branch together" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.merge_pr(
                 number: 9,
                 cwd: "/tmp/ws",
                 method: "squash",
                 delete_branch: true,
                 repo: "owner/repo",
                 runner: MockRunner
               )

      assert_invoked(["pr", "merge", "9", "--repo", "owner/repo", "--squash", "--delete-branch"])
    end
  end

  describe "post_comment/1" do
    test "calls gh pr comment <number> --body <body>" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.post_comment(
                 number: 11,
                 body: "trailer body",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked(["pr", "comment", "11", "--body", "trailer body"])
    end

    test "missing :body returns {:error, {:missing_opt, :body}}" do
      assert {:error, {:missing_opt, :body}} =
               GhCli.post_comment(number: 11, cwd: "/tmp/ws", runner: MockRunner)
    end
  end

  describe "submit_review/1" do
    test "uses --approve for event APPROVE" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.submit_review(
                 number: 13,
                 event: "APPROVE",
                 body: "lgtm",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked(["pr", "review", "13", "--approve", "--body", "lgtm"])
    end

    test "uses --request-changes for REQUEST_CHANGES" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.submit_review(
                 number: 13,
                 event: "REQUEST_CHANGES",
                 body: "fix this",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked(["pr", "review", "13", "--request-changes", "--body", "fix this"])
    end

    test "uses --comment for COMMENT" do
      put_response({:ok, ""})

      assert :ok =
               GhCli.submit_review(
                 number: 13,
                 event: "COMMENT",
                 body: "fyi",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )

      assert_invoked(["pr", "review", "13", "--comment", "--body", "fyi"])
    end

    test "rejects unknown events" do
      assert {:error, {:invalid_review_event, "DISMISS"}} =
               GhCli.submit_review(
                 number: 13,
                 event: "DISMISS",
                 body: "x",
                 cwd: "/tmp/ws",
                 runner: MockRunner
               )
    end
  end

  describe "list_reviews/1" do
    test "calls gh api repos/{owner}/{repo}/pulls/<n>/reviews and decodes JSON" do
      payload = [
        %{
          "id" => 1,
          "state" => "APPROVED",
          "user" => %{"login" => "claude-bot"}
        }
      ]

      put_response({:ok, Jason.encode!(payload)})

      assert {:ok, [review]} =
               GhCli.list_reviews(
                 number: 17,
                 cwd: "/tmp/ws",
                 repo: "owner/repo",
                 runner: MockRunner
               )

      assert review["id"] == 1
      assert review["state"] == "APPROVED"
      assert review["user"]["login"] == "claude-bot"

      assert_invoked(["api", "repos/owner/repo/pulls/17/reviews"])
    end

    test "uses {owner}/{repo} placeholder when :repo is omitted" do
      put_response({:ok, "[]"})

      assert {:ok, []} = GhCli.list_reviews(number: 17, cwd: "/tmp/ws", runner: MockRunner)

      assert_invoked(["api", "repos/{owner}/{repo}/pulls/17/reviews"])
    end

    test "returns {:error, {:invalid_json, _}} on undecodable stdout" do
      put_response({:ok, "<html>not json</html>"})

      assert {:error, {:invalid_json, %Jason.DecodeError{}}} =
               GhCli.list_reviews(number: 17, cwd: "/tmp/ws", runner: MockRunner)
    end

    test "returns {:error, {:unexpected_json_shape, _}} when JSON is not a list" do
      put_response({:ok, ~s({"message":"Not Found"})})

      assert {:error, {:unexpected_json_shape, %{"message" => "Not Found"}}} =
               GhCli.list_reviews(number: 17, cwd: "/tmp/ws", runner: MockRunner)
    end

    test "propagates runner failure" do
      put_response({:error, {:exit_status, 1, "boom"}})

      assert {:error, {:exit_status, 1, "boom"}} =
               GhCli.list_reviews(number: 17, cwd: "/tmp/ws", runner: MockRunner)
    end
  end

  describe "mergeability/1" do
    test "decodes camelCase keys to atom keys with lowercase mergeable_state" do
      put_response({:ok, ~s({"mergeable":true,"mergeStateStatus":"CLEAN"})})

      assert {:ok, %{mergeable: true, mergeable_state: :clean}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)

      assert_invoked(["pr", "view", "21", "--json", "mergeable,mergeStateStatus"])
    end

    test "maps mergeable: false and DIRTY status" do
      put_response({:ok, ~s({"mergeable":false,"mergeStateStatus":"DIRTY"})})

      assert {:ok, %{mergeable: false, mergeable_state: :dirty}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)
    end

    test "maps GraphQL-style MERGEABLE/CONFLICTING strings to booleans" do
      put_response({:ok, ~s({"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"})})

      assert {:ok, %{mergeable: true, mergeable_state: :clean}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)

      put_response({:ok, ~s({"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"})})

      assert {:ok, %{mergeable: false, mergeable_state: :dirty}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)
    end

    test "falls back to nil mergeable / :unknown state when fields are absent" do
      put_response({:ok, "{}"})

      assert {:ok, %{mergeable: nil, mergeable_state: :unknown}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)
    end

    test "returns {:error, {:invalid_json, _}} on undecodable stdout" do
      put_response({:ok, "not json"})

      assert {:error, {:invalid_json, %Jason.DecodeError{}}} =
               GhCli.mergeability(number: 21, cwd: "/tmp/ws", runner: MockRunner)
    end
  end

  describe "runner/1" do
    test "defaults to SystemRunner when nothing is configured" do
      assert GhCli.runner([]) == SymphonyElixir.Duet.GhCli.SystemRunner
      assert GhCli.runner() == SymphonyElixir.Duet.GhCli.SystemRunner
    end

    test "honors :runner opt as the highest-priority override" do
      Application.put_env(:symphony_elixir, :duet_gh_cli_runner, SymphonyElixir.Duet.GhCli.SystemRunner)
      assert GhCli.runner(runner: MockRunner) == MockRunner
    end

    test "honors :duet_gh_cli_runner application env when no opt is supplied" do
      Application.put_env(:symphony_elixir, :duet_gh_cli_runner, MockRunner)
      assert GhCli.runner([]) == MockRunner
    end

    test "ignores non-module :runner values and falls back to default" do
      assert GhCli.runner(runner: "not-a-module") == SymphonyElixir.Duet.GhCli.SystemRunner
    end
  end

  describe "runner injection via Application env" do
    test "open_pr/1 uses the env-configured runner when :runner opt is absent" do
      Application.put_env(:symphony_elixir, :duet_gh_cli_runner, MockRunner)
      put_response({:ok, "https://github.com/o/r/pull/77\n"})

      assert {:ok, %{number: 77, url: "https://github.com/o/r/pull/77"}} =
               GhCli.open_pr(
                 base: "main",
                 head: "feature",
                 title: "T",
                 body: "B",
                 cwd: "/tmp/ws"
               )

      assert_received {:gh_cli_invoked, _args, _opts}
    end
  end

  describe "runner opts plumbing" do
    test ":cwd is forwarded to the runner via :cwd" do
      put_response({:ok, ""})

      :ok = GhCli.mark_ready(number: 1, cwd: "/some/workspace", runner: MockRunner)

      assert_received {:gh_cli_invoked, _args, opts}
      assert opts[:cwd] == "/some/workspace"
    end

    test "extra runner_opts are merged into the runner-side opts" do
      put_response({:ok, ""})

      :ok =
        GhCli.mark_ready(
          number: 1,
          cwd: "/some/workspace",
          runner: MockRunner,
          runner_opts: [env: [{"GH_TOKEN", "x"}]]
        )

      assert_received {:gh_cli_invoked, _args, opts}
      assert opts[:cwd] == "/some/workspace"
      assert opts[:env] == [{"GH_TOKEN", "x"}]
    end
  end
end
