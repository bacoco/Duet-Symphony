defmodule SymphonyElixir.DuetIdentityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Identity

  setup do
    prior_claude_env = System.get_env("DUET_CLAUDE_GITHUB_IDENTITY")
    prior_codex_env = System.get_env("DUET_CODEX_GITHUB_IDENTITY")

    System.delete_env("DUET_CLAUDE_GITHUB_IDENTITY")
    System.delete_env("DUET_CODEX_GITHUB_IDENTITY")

    on_exit(fn ->
      restore_env("DUET_CLAUDE_GITHUB_IDENTITY", prior_claude_env)
      restore_env("DUET_CODEX_GITHUB_IDENTITY", prior_codex_env)
    end)

    :ok
  end

  describe "for_actor/1" do
    test "returns {:ok, identity} after set_for_actor for claude" do
      :ok = Identity.set_for_actor("claude", "claude-bot")

      assert Identity.for_actor("claude") == {:ok, "claude-bot"}
    end

    test "returns {:error, :missing} when neither app env nor system env has a value" do
      assert Identity.for_actor("claude") == {:error, :missing}
      assert Identity.for_actor("codex") == {:error, :missing}
    end

    test "prefers app env override over system env" do
      System.put_env("DUET_CLAUDE_GITHUB_IDENTITY", "from-system-env")
      :ok = Identity.set_for_actor("claude", "from-app-env")

      assert Identity.for_actor("claude") == {:ok, "from-app-env"}
    end

    test "falls back to system env when app env override is unset" do
      System.put_env("DUET_CODEX_GITHUB_IDENTITY", "codex-svc")

      assert Identity.for_actor("codex") == {:ok, "codex-svc"}
    end

    test "treats whitespace-only values as missing and trims real values" do
      System.put_env("DUET_CLAUDE_GITHUB_IDENTITY", "   ")
      assert Identity.for_actor("claude") == {:error, :missing}

      :ok = Identity.set_for_actor("claude", "  claude-bot  ")
      assert Identity.for_actor("claude") == {:ok, "claude-bot"}
    end

    test "returns {:error, :missing} for an unknown actor" do
      assert Identity.for_actor("human") == {:error, :missing}
      assert Identity.for_actor("none") == {:error, :missing}
    end
  end

  describe "set_for_actor/2" do
    test "storing a binary then resolving returns {:ok, binary}" do
      :ok = Identity.set_for_actor("codex", "codex-bot")

      assert Identity.for_actor("codex") == {:ok, "codex-bot"}
    end

    test "storing nil clears the override and resolution returns {:error, :missing}" do
      :ok = Identity.set_for_actor("claude", "claude-bot")
      assert Identity.for_actor("claude") == {:ok, "claude-bot"}

      :ok = Identity.set_for_actor("claude", nil)
      assert Identity.for_actor("claude") == {:error, :missing}
    end

    test "unknown actor is a no-op and does not pollute app env" do
      assert Identity.set_for_actor("human", "someone") == :ok
      assert Identity.for_actor("human") == {:error, :missing}
    end
  end

  describe "validate_distinct_machine_identities/0" do
    test "returns missing for both machine actors when neither is configured" do
      assert Identity.validate_distinct_machine_identities() ==
               {:error, {:missing_identity, ["claude", "codex"]}}
    end

    test "returns missing for codex when only claude is set" do
      :ok = Identity.set_for_actor("claude", "claude-bot")

      assert Identity.validate_distinct_machine_identities() ==
               {:error, {:missing_identity, ["codex"]}}
    end

    test "returns missing for claude when only codex is set" do
      :ok = Identity.set_for_actor("codex", "codex-bot")

      assert Identity.validate_distinct_machine_identities() ==
               {:error, {:missing_identity, ["claude"]}}
    end

    test "returns shared_identity when both machine actors resolve to the same value" do
      :ok = Identity.set_for_actor("claude", "shared-bot")
      :ok = Identity.set_for_actor("codex", "shared-bot")

      assert Identity.validate_distinct_machine_identities() ==
               {:error, {:shared_identity, "shared-bot"}}
    end

    test "treats case-only GitHub identity differences as shared" do
      :ok = Identity.set_for_actor("claude", "Shared-Bot")
      :ok = Identity.set_for_actor("codex", "shared-bot")

      assert Identity.validate_distinct_machine_identities() ==
               {:error, {:shared_identity, "Shared-Bot"}}
    end

    test "returns :ok when both machine actors have distinct identities" do
      :ok = Identity.set_for_actor("claude", "claude-bot")
      :ok = Identity.set_for_actor("codex", "codex-bot")

      assert Identity.validate_distinct_machine_identities() == :ok
    end
  end

  describe "machine_actors/0" do
    test "returns the list of machine actors covered by the distinct-identity rule" do
      assert Identity.machine_actors() == ["claude", "codex"]
    end
  end
end
