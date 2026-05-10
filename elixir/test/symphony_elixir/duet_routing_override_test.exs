defmodule SymphonyElixir.DuetRoutingOverrideTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.{EventLog, Routing, RoutingOverride, RoutingSelection}

  setup do
    previous_root = Application.get_env(:symphony_elixir, :duet_event_log_root)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-duet-routing-override-#{System.unique_integer([:positive])}"
      )

    EventLog.set_root(Path.join(test_root, ".duet/logs"))

    on_exit(fn ->
      restore_app_env(:duet_event_log_root, previous_root)
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root}
  end

  describe "selected_profile_name_for_task/2" do
    test "returns nil when no override is set" do
      settings = Config.settings!().duet

      assert RoutingOverride.selected_profile_name_for_task("TASK-NONE", settings) == nil
    end

    test "returns the stored profile name when set" do
      settings = Config.settings!().duet

      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-A" => "codex_only_dev"}
      )

      assert RoutingOverride.selected_profile_name_for_task("TASK-A", settings) == "codex_only_dev"
    end

    test "clears and returns nil when the stored profile no longer exists" do
      settings = Config.settings!().duet

      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-STALE" => "vanished_profile", "TASK-OK" => "codex_only_dev"}
      )

      log =
        capture_log(fn ->
          assert RoutingOverride.selected_profile_name_for_task("TASK-STALE", settings) == nil
        end)

      assert log =~ "vanished_profile"
      assert log =~ "TASK-STALE"

      stored = Application.get_env(:symphony_elixir, :duet_per_task_routing_profile)
      assert stored == %{"TASK-OK" => "codex_only_dev"}
    end
  end

  describe "resolve_for_task/2" do
    test "falls back to RoutingSelection.resolve when no override" do
      settings = Config.settings!().duet

      assert {:ok, profile} = RoutingOverride.resolve_for_task("TASK-NONE", settings)
      assert profile.name == "duet_balanced"
    end

    test "honors the runtime-global RoutingSelection when no per-task override" do
      settings = Config.settings!().duet

      assert {:ok, _payload} = RoutingSelection.select(settings, "codex_only_dev")

      assert {:ok, profile} = RoutingOverride.resolve_for_task("TASK-NONE", settings)
      assert profile.name == "codex_only_dev"
    end

    test "returns the override-resolved profile when set" do
      settings = Config.settings!().duet

      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-A" => "claude_only_dev"}
      )

      assert {:ok, profile} = RoutingOverride.resolve_for_task("TASK-A", settings)
      assert profile.name == "claude_only_dev"
      assert profile.degraded? == true
    end

    test "override takes precedence over global RoutingSelection" do
      settings = Config.settings!().duet

      assert {:ok, _payload} = RoutingSelection.select(settings, "codex_only_dev")

      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-A" => "claude_only_dev"}
      )

      assert {:ok, profile} = RoutingOverride.resolve_for_task("TASK-A", settings)
      assert profile.name == "claude_only_dev"
    end

    test "falls back to global RoutingSelection profile when override is stale" do
      settings = Config.settings!().duet

      assert {:ok, _payload} = RoutingSelection.select(settings, "codex_only_dev")

      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-STALE" => "vanished_profile"}
      )

      log =
        capture_log(fn ->
          assert {:ok, profile} = RoutingOverride.resolve_for_task("TASK-STALE", settings)
          assert profile.name == "codex_only_dev"
        end)

      assert log =~ "vanished_profile"
    end
  end

  describe "apply_override/4" do
    test "stores the override in app env" do
      settings = Config.settings!().duet

      assert {:ok, profile} = RoutingOverride.apply_override("TASK-APPLY", "codex_only_dev", :operator_ui, settings)
      assert profile.name == "codex_only_dev"

      stored = Application.get_env(:symphony_elixir, :duet_per_task_routing_profile)
      assert stored == %{"TASK-APPLY" => "codex_only_dev"}
    end

    test "emits a routing_override_applied event with the right shape" do
      settings = Config.settings!().duet

      assert {:ok, _profile} =
               RoutingOverride.apply_override("TASK-EVENT", "codex_only_dev", :operator_ui, settings)

      assert {:ok, events} = EventLog.read("TASK-EVENT")
      assert [event] = events
      assert event["kind"] == "routing_override_applied"
      assert event["task_id"] == "TASK-EVENT"
      assert event["profile_name"] == "codex_only_dev"
      assert event["mode"] == "degraded_single_agent"
      assert event["degraded"] == true
      assert event["source"] == "operator_ui"
      assert event["previous_profile_name"] == nil

      phases = event["phases"]
      assert is_map(phases)
      assert phases["spec"]["author"] == "codex"
      assert phases["plan"]["author"] == "codex"
      assert phases["code"]["author"] == "codex"
      assert phases["review"]["coder_ack"] == "code_author"
      assert phases["review"]["reviewer"] == "human"
    end

    test "returns {:error, {:invalid_source, ...}} for unknown source" do
      settings = Config.settings!().duet

      assert {:error, {:invalid_source, :hacker}} =
               RoutingOverride.apply_override("TASK-BAD-SRC", "codex_only_dev", :hacker, settings)

      assert Application.get_env(:symphony_elixir, :duet_per_task_routing_profile) == nil
      assert {:ok, []} = EventLog.read("TASK-BAD-SRC")
    end

    test "returns {:error, {:unknown_profile, ...}} for an unknown profile" do
      settings = Config.settings!().duet

      assert {:error, {:unknown_profile, "missing_profile"}} =
               RoutingOverride.apply_override("TASK-BAD-PROF", "missing_profile", :operator_ui, settings)

      assert Application.get_env(:symphony_elixir, :duet_per_task_routing_profile) == nil
      assert {:ok, []} = EventLog.read("TASK-BAD-PROF")
    end

    test "includes previous_profile_name when an override already existed" do
      settings = Config.settings!().duet

      assert {:ok, _profile} =
               RoutingOverride.apply_override("TASK-PREV", "codex_only_dev", :operator_ui, settings)

      assert {:ok, _profile} =
               RoutingOverride.apply_override("TASK-PREV", "claude_only_dev", :operator_api, settings)

      assert {:ok, events} = EventLog.read("TASK-PREV")
      assert length(events) == 2

      [_first, second] = events
      assert second["kind"] == "routing_override_applied"
      assert second["profile_name"] == "claude_only_dev"
      assert second["previous_profile_name"] == "codex_only_dev"
      assert second["source"] == "operator_api"

      stored = Application.get_env(:symphony_elixir, :duet_per_task_routing_profile)
      assert stored == %{"TASK-PREV" => "claude_only_dev"}
    end

    test "supports Issue structs as task identifier" do
      settings = Config.settings!().duet
      issue = %Issue{id: "linear-id-1", identifier: "MT-100"}

      assert {:ok, _profile} =
               RoutingOverride.apply_override(issue, "codex_only_dev", :operator_ui, settings)

      stored = Application.get_env(:symphony_elixir, :duet_per_task_routing_profile)
      assert stored == %{"linear-id-1" => "codex_only_dev"}

      assert {:ok, events} = EventLog.read(issue)
      assert [event] = events
      assert event["task_id"] == "linear-id-1"
    end

    test "rolls back the app env change if EventLog.append fails", %{test_root: test_root} do
      settings = Config.settings!().duet

      # Pre-seed an existing override so we can verify rollback restores it.
      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"OTHER-TASK" => "codex_only_dev"}
      )

      # Force EventLog.append to fail by making the task's parent directory
      # path collide with a regular file.
      task_id = "TASK-ROLLBACK"
      task_dir = Path.dirname(EventLog.path_for_task(task_id))
      File.mkdir_p!(Path.dirname(task_dir))
      File.write!(task_dir, "blocker file")

      try do
        assert {:error, {:event_log_failed, _reason}} =
                 RoutingOverride.apply_override(task_id, "codex_only_dev", :operator_ui, settings)

        # App env should be restored to the previous value.
        stored = Application.get_env(:symphony_elixir, :duet_per_task_routing_profile)
        assert stored == %{"OTHER-TASK" => "codex_only_dev"}
        refute Map.has_key?(stored, task_id)
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts every documented source atom" do
      settings = Config.settings!().duet

      for {source, idx} <- Enum.with_index(RoutingOverride.valid_sources()) do
        task_id = "TASK-SRC-#{idx}"

        assert {:ok, _profile} =
                 RoutingOverride.apply_override(task_id, "codex_only_dev", source, settings)

        assert {:ok, [event]} = EventLog.read(task_id)
        assert event["source"] == Atom.to_string(source)
      end
    end
  end

  describe "clear_for_task/1" do
    test "is idempotent" do
      assert RoutingOverride.clear_for_task("TASK-EMPTY") == :ok
      assert RoutingOverride.clear_for_task("TASK-EMPTY") == :ok
      assert Application.get_env(:symphony_elixir, :duet_per_task_routing_profile) == nil
    end

    test "removes the entry from active_overrides/0" do
      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-A" => "codex_only_dev", "TASK-B" => "claude_only_dev"}
      )

      assert RoutingOverride.clear_for_task("TASK-A") == :ok
      assert RoutingOverride.active_overrides() == ["TASK-B"]

      assert RoutingOverride.clear_for_task("TASK-B") == :ok
      assert RoutingOverride.active_overrides() == []
      assert Application.get_env(:symphony_elixir, :duet_per_task_routing_profile) == nil
    end
  end

  describe "active_overrides/0" do
    test "is empty when no overrides" do
      assert RoutingOverride.active_overrides() == []
    end

    test "lists task_ids with overrides, sorted" do
      Application.put_env(
        :symphony_elixir,
        :duet_per_task_routing_profile,
        %{"TASK-Z" => "codex_only_dev", "TASK-A" => "claude_only_dev", "TASK-M" => "duet_balanced"}
      )

      assert RoutingOverride.active_overrides() == ["TASK-A", "TASK-M", "TASK-Z"]
    end
  end

  describe "event_attrs/3" do
    test "matches the spec-defined shape" do
      settings = Config.settings!().duet
      {:ok, profile} = Routing.resolve(settings, "codex_only_dev")

      attrs = RoutingOverride.event_attrs(profile, :operator_ui, "duet_balanced")

      assert attrs.profile_name == "codex_only_dev"
      assert attrs.mode == "degraded_single_agent"
      assert attrs.degraded == true
      assert attrs.source == "operator_ui"
      assert attrs.previous_profile_name == "duet_balanced"

      phases = attrs.phases
      assert is_map(phases)
      assert phases["spec"].author == "codex"
      assert phases["plan"].author == "codex"
      assert phases["code"].author == "codex"
      assert phases["review"].coder_ack == "code_author"
      assert phases["review"].reviewer == "human"
    end

    test "defaults previous_profile_name to nil" do
      settings = Config.settings!().duet
      {:ok, profile} = Routing.resolve(settings, "duet_balanced")

      attrs = RoutingOverride.event_attrs(profile, :routing_menu)

      assert attrs.previous_profile_name == nil
      assert attrs.source == "routing_menu"
    end
  end

  describe "valid_sources/0" do
    test "returns the canonical list" do
      assert RoutingOverride.valid_sources() == [:operator_ui, :operator_api, :operator_cli, :routing_menu]
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
