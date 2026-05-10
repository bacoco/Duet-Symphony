defmodule SymphonyElixir.DuetHumanCheckpointTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.HumanCheckpoint

  describe "feature_enabled?/1" do
    test "returns false by default in the schema-provided settings" do
      refute HumanCheckpoint.feature_enabled?(Config.settings!().duet)
    end

    test "reads the enabled flag from a struct with :human_checkpoints" do
      settings = %{human_checkpoints: %{"enabled" => true}}
      assert HumanCheckpoint.feature_enabled?(settings)
    end

    test "reads the enabled flag from a raw map" do
      assert HumanCheckpoint.feature_enabled?(%{"enabled" => true})
    end

    test "accepts atom keys" do
      assert HumanCheckpoint.feature_enabled?(%{enabled: true})
    end

    test "defaults to false when missing" do
      refute HumanCheckpoint.feature_enabled?(%{})
      refute HumanCheckpoint.feature_enabled?(%{human_checkpoints: %{}})
    end

    test "non-boolean values are treated as false" do
      refute HumanCheckpoint.feature_enabled?(%{"enabled" => "yes"})
    end
  end

  describe "mode_for_phase/2" do
    test "returns :disabled for any phase when feature is globally disabled" do
      settings = %{
        "enabled" => false,
        "default_mode" => "blocking",
        "phases" => %{"spec" => true, "plan" => true, "code" => true, "review" => true}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :disabled
      assert HumanCheckpoint.mode_for_phase(settings, "PLAN") == :disabled
      assert HumanCheckpoint.mode_for_phase(settings, "CODE") == :disabled
      assert HumanCheckpoint.mode_for_phase(settings, "REVIEW") == :disabled
    end

    test "returns :disabled when feature is enabled but the phase is missing" do
      settings = %{"enabled" => true, "default_mode" => "blocking", "phases" => %{}}
      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :disabled
    end

    test "returns :disabled when feature is enabled but the phase value is false" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"spec" => false}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :disabled
    end

    test "returns :blocking when phase is true and default_mode is blocking" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"spec" => true}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :blocking
    end

    test "returns :advisory when phase is true and default_mode is advisory" do
      settings = %{
        "enabled" => true,
        "default_mode" => "advisory",
        "phases" => %{"plan" => true}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "PLAN") == :advisory
    end

    test "explicit per-phase 'blocking' string overrides default_mode" do
      settings = %{
        "enabled" => true,
        "default_mode" => "advisory",
        "phases" => %{"code" => "blocking"}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "CODE") == :blocking
    end

    test "explicit per-phase 'advisory' string overrides default_mode" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"review" => "advisory"}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "REVIEW") == :advisory
    end

    test "invalid per-phase values fall back to :disabled" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"spec" => "bogus", "plan" => 42}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :disabled
      assert HumanCheckpoint.mode_for_phase(settings, "PLAN") == :disabled
    end

    test "invalid default_mode falls back to blocking" do
      settings = %{
        "enabled" => true,
        "default_mode" => "weird",
        "phases" => %{"spec" => true}
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :blocking
    end

    test "accepts a struct with :human_checkpoints field" do
      settings = %{
        human_checkpoints: %{
          "enabled" => true,
          "default_mode" => "blocking",
          "phases" => %{"spec" => true}
        }
      }

      assert HumanCheckpoint.mode_for_phase(settings, "SPEC") == :blocking
    end
  end

  describe "blocking?/2" do
    test "matches mode_for_phase == :blocking" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"spec" => true, "plan" => "advisory", "code" => false}
      }

      assert HumanCheckpoint.blocking?(settings, "SPEC")
      refute HumanCheckpoint.blocking?(settings, "PLAN")
      refute HumanCheckpoint.blocking?(settings, "CODE")
      refute HumanCheckpoint.blocking?(settings, "REVIEW")
    end
  end

  describe "timeout_ms/1" do
    test "returns nil when missing" do
      assert HumanCheckpoint.timeout_ms(%{}) == nil
    end

    test "returns nil when explicitly nil" do
      assert HumanCheckpoint.timeout_ms(%{"timeout_ms" => nil}) == nil
    end

    test "returns positive integer when set" do
      assert HumanCheckpoint.timeout_ms(%{"timeout_ms" => 30_000}) == 30_000
    end

    test "returns nil for non-positive integers" do
      assert HumanCheckpoint.timeout_ms(%{"timeout_ms" => 0}) == nil
      assert HumanCheckpoint.timeout_ms(%{"timeout_ms" => -100}) == nil
    end

    test "returns nil for non-integer values" do
      assert HumanCheckpoint.timeout_ms(%{"timeout_ms" => "30s"}) == nil
    end

    test "reads from a struct with :human_checkpoints" do
      assert HumanCheckpoint.timeout_ms(%{human_checkpoints: %{"timeout_ms" => 5_000}}) == 5_000
    end
  end

  describe "resolve_decision/2" do
    test ":approve returns :continue_freeze for any phase" do
      assert HumanCheckpoint.resolve_decision(:approve, "SPEC") == :continue_freeze
      assert HumanCheckpoint.resolve_decision(:approve, "REVIEW") == :continue_freeze
    end

    test ":request_changes for REVIEW returns to CODE" do
      assert HumanCheckpoint.resolve_decision(:request_changes, "REVIEW") == {:return_to_phase, "CODE"}
    end

    test ":request_changes for SPEC returns to SPEC" do
      assert HumanCheckpoint.resolve_decision(:request_changes, "SPEC") == {:return_to_phase, "SPEC"}
    end

    test ":request_changes for PLAN returns to PLAN" do
      assert HumanCheckpoint.resolve_decision(:request_changes, "PLAN") == {:return_to_phase, "PLAN"}
    end

    test ":request_changes for CODE returns to CODE" do
      assert HumanCheckpoint.resolve_decision(:request_changes, "CODE") == {:return_to_phase, "CODE"}
    end

    test ":fail returns the human_rejected failure tuple" do
      assert HumanCheckpoint.resolve_decision(:fail, "SPEC") == {:fail, :human_rejected}
      assert HumanCheckpoint.resolve_decision(:fail, "REVIEW") == {:fail, :human_rejected}
    end

    test "an invalid decision returns {:error, :invalid_decision}" do
      assert HumanCheckpoint.resolve_decision(:bogus, "SPEC") == {:error, :invalid_decision}
      assert HumanCheckpoint.resolve_decision("approve", "SPEC") == {:error, :invalid_decision}
    end
  end

  describe "blocking_phases/1" do
    test "returns blocking phases in canonical order" do
      settings = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{
          "review" => true,
          "spec" => true,
          "plan" => "advisory",
          "code" => true
        }
      }

      assert HumanCheckpoint.blocking_phases(settings) == ["SPEC", "CODE", "REVIEW"]
    end

    test "returns an empty list when feature is disabled" do
      settings = %{
        "enabled" => false,
        "phases" => %{"spec" => true, "plan" => true, "code" => true, "review" => true}
      }

      assert HumanCheckpoint.blocking_phases(settings) == []
    end

    test "returns only explicitly blocking phases when default_mode is advisory" do
      settings = %{
        "enabled" => true,
        "default_mode" => "advisory",
        "phases" => %{"spec" => true, "plan" => "blocking", "code" => "blocking", "review" => true}
      }

      assert HumanCheckpoint.blocking_phases(settings) == ["PLAN", "CODE"]
    end
  end

  describe "validate_config/1" do
    test "empty map is :ok (all defaults)" do
      assert HumanCheckpoint.validate_config(%{}) == :ok
    end

    test "all valid → :ok" do
      config = %{
        "enabled" => true,
        "default_mode" => "blocking",
        "phases" => %{"spec" => true, "plan" => false, "code" => "blocking", "review" => "advisory"},
        "timeout_ms" => 30_000
      }

      assert HumanCheckpoint.validate_config(config) == :ok
    end

    test "schema default config validates" do
      assert HumanCheckpoint.validate_config(%{
               "enabled" => false,
               "default_mode" => "blocking",
               "phases" => %{"spec" => false, "plan" => false, "code" => false, "review" => false},
               "timeout_ms" => nil
             }) == :ok
    end

    test "enabled not boolean → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"enabled" => "yes"})
      assert msg =~ "enabled"
    end

    test "default_mode not in [blocking, advisory] → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"default_mode" => "weird"})
      assert msg =~ "default_mode"
    end

    test "phases not a map → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"phases" => ["spec", "plan"]})
      assert msg =~ "phases"
    end

    test "per-phase invalid value → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"phases" => %{"spec" => "bogus"}})
      assert msg =~ "phases.spec"
    end

    test "per-phase non-boolean non-string value → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"phases" => %{"spec" => 42}})
      assert msg =~ "phases.spec"
    end

    test "timeout_ms negative → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"timeout_ms" => -5_000})
      assert msg =~ "timeout_ms"
    end

    test "timeout_ms zero → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"timeout_ms" => 0})
      assert msg =~ "timeout_ms"
    end

    test "timeout_ms non-integer → error" do
      assert {:error, msg} = HumanCheckpoint.validate_config(%{"timeout_ms" => "30s"})
      assert msg =~ "timeout_ms"
    end

    test "non-map input → error" do
      assert {:error, _msg} = HumanCheckpoint.validate_config("not a map")
    end

    test "accepts atom keys via normalization" do
      config = %{
        enabled: true,
        default_mode: "blocking",
        phases: %{spec: true, plan: false, code: false, review: false},
        timeout_ms: 60_000
      }

      assert HumanCheckpoint.validate_config(config) == :ok
    end
  end
end
