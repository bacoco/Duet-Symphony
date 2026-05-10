defmodule SymphonyElixir.DuetSuperPowerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.SuperPower

  describe "enabled?/1" do
    test "empty map returns false" do
      refute SuperPower.enabled?(%{})
    end

    test "returns true when enabled is the boolean true" do
      assert SuperPower.enabled?(%{"enabled" => true})
    end

    test "non-boolean values resolve to false" do
      refute SuperPower.enabled?(%{"enabled" => "yes"})
      refute SuperPower.enabled?(%{"enabled" => 1})
      refute SuperPower.enabled?(%{"enabled" => "true"})
    end

    test "accepts atom keys" do
      assert SuperPower.enabled?(%{enabled: true})
    end

    test "non-map input is false" do
      refute SuperPower.enabled?(nil)
      refute SuperPower.enabled?("enabled")
    end
  end

  describe "mode/1" do
    test "empty map defaults to :mirror" do
      assert SuperPower.mode(%{}) == :mirror
    end

    test "returns :enforce when mode is \"enforce\"" do
      assert SuperPower.mode(%{"mode" => "enforce"}) == :enforce
    end

    test "case-insensitive value comparison" do
      assert SuperPower.mode(%{"mode" => "MIRROR"}) == :mirror
      assert SuperPower.mode(%{"mode" => "Enforce"}) == :enforce
    end

    test "unknown values fall back to :mirror" do
      assert SuperPower.mode(%{"mode" => "bogus"}) == :mirror
      assert SuperPower.mode(%{"mode" => 42}) == :mirror
      assert SuperPower.mode(%{"mode" => nil}) == :mirror
    end

    test "accepts atom keys" do
      assert SuperPower.mode(%{mode: "enforce"}) == :enforce
    end
  end

  describe "root/1" do
    test "empty map returns default \"docs/superpowers\"" do
      assert SuperPower.root(%{}) == "docs/superpowers"
    end

    test "returns custom path when configured" do
      assert SuperPower.root(%{"root" => "custom/path"}) == "custom/path"
    end

    test "whitespace-only values fall back to default" do
      assert SuperPower.root(%{"root" => " "}) == "docs/superpowers"
      assert SuperPower.root(%{"root" => "\t\n"}) == "docs/superpowers"
    end

    test "empty string falls back to default" do
      assert SuperPower.root(%{"root" => ""}) == "docs/superpowers"
    end

    test "trims surrounding whitespace from a real path" do
      assert SuperPower.root(%{"root" => "  custom/path  "}) == "custom/path"
    end

    test "accepts atom keys" do
      assert SuperPower.root(%{root: "alt/dir"}) == "alt/dir"
    end
  end

  describe "phase_enabled?/2" do
    test "feature disabled returns false for any phase" do
      config = %{
        "enabled" => false,
        "phases" => %{"spec" => true, "plan" => true, "code" => true, "review" => true}
      }

      refute SuperPower.phase_enabled?(config, "SPEC")
      refute SuperPower.phase_enabled?(config, "PLAN")
      refute SuperPower.phase_enabled?(config, "CODE")
      refute SuperPower.phase_enabled?(config, "REVIEW")
    end

    test "feature enabled but phases missing returns false" do
      config = %{"enabled" => true}
      refute SuperPower.phase_enabled?(config, "SPEC")
      refute SuperPower.phase_enabled?(config, "PLAN")
    end

    test "feature enabled with spec=true returns true for SPEC" do
      config = %{"enabled" => true, "phases" => %{"spec" => true}}
      assert SuperPower.phase_enabled?(config, "SPEC")
    end

    test "feature enabled with spec=true returns false for PLAN" do
      config = %{"enabled" => true, "phases" => %{"spec" => true}}
      refute SuperPower.phase_enabled?(config, "PLAN")
    end

    test "unknown phase name returns false" do
      config = %{"enabled" => true, "phases" => %{"spec" => true}}
      refute SuperPower.phase_enabled?(config, "BOGUS")
    end

    test "phase explicitly disabled returns false" do
      config = %{"enabled" => true, "phases" => %{"code" => false}}
      refute SuperPower.phase_enabled?(config, "CODE")
    end

    test "non-boolean per-phase values resolve to false" do
      config = %{"enabled" => true, "phases" => %{"spec" => "yes", "plan" => 1}}
      refute SuperPower.phase_enabled?(config, "SPEC")
      refute SuperPower.phase_enabled?(config, "PLAN")
    end

    test "accepts atom keys for phases map" do
      config = %{"enabled" => true, "phases" => %{spec: true}}
      assert SuperPower.phase_enabled?(config, "SPEC")
    end

    test "accepts fully atom-keyed config" do
      config = %{enabled: true, phases: %{spec: true, plan: false}}
      assert SuperPower.phase_enabled?(config, "SPEC")
      refute SuperPower.phase_enabled?(config, "PLAN")
    end

    test "phase comparison is case-insensitive" do
      config = %{"enabled" => true, "phases" => %{"review" => true}}
      assert SuperPower.phase_enabled?(config, "REVIEW")
      assert SuperPower.phase_enabled?(config, "review")
      assert SuperPower.phase_enabled?(config, "Review")
    end
  end

  describe "artifact_path/3" do
    test "SPEC with default root → docs/superpowers/specs/<id>.md" do
      assert SuperPower.artifact_path(%{}, "SPEC", "auth-refactor") ==
               {:ok, "docs/superpowers/specs/auth-refactor.md"}
    end

    test "PLAN maps to plans/" do
      assert SuperPower.artifact_path(%{}, "PLAN", "task-1") ==
               {:ok, "docs/superpowers/plans/task-1.md"}
    end

    test "REVIEW maps to reviews/" do
      assert SuperPower.artifact_path(%{}, "REVIEW", "task-1") ==
               {:ok, "docs/superpowers/reviews/task-1.md"}
    end

    test "CODE maps to code/" do
      assert SuperPower.artifact_path(%{}, "CODE", "task-1") ==
               {:ok, "docs/superpowers/code/task-1.md"}
    end

    test "uses custom root when configured" do
      config = %{"root" => "artifacts/sp"}

      assert SuperPower.artifact_path(config, "SPEC", "feature") ==
               {:ok, "artifacts/sp/specs/feature.md"}
    end

    test "sanitizes task IDs containing slashes" do
      assert SuperPower.artifact_path(%{}, "SPEC", "owner/repo#42") ==
               {:ok, "docs/superpowers/specs/owner_repo_42.md"}
    end

    test "preserves allowed punctuation in task IDs" do
      assert SuperPower.artifact_path(%{}, "SPEC", "v1.0_release-final") ==
               {:ok, "docs/superpowers/specs/v1.0_release-final.md"}
    end

    test "phase comparison is case-insensitive" do
      assert SuperPower.artifact_path(%{}, "spec", "task") ==
               {:ok, "docs/superpowers/specs/task.md"}

      assert SuperPower.artifact_path(%{}, "Plan", "task") ==
               {:ok, "docs/superpowers/plans/task.md"}
    end

    test "unknown phase returns {:error, :invalid_phase}" do
      assert SuperPower.artifact_path(%{}, "BOGUS", "task") == {:error, :invalid_phase}
    end
  end

  describe "template_check/2" do
    test "always returns :ok for any inputs (v1 stub)" do
      assert SuperPower.template_check("any artifact text", "SPEC") == :ok
      assert SuperPower.template_check("", "PLAN") == :ok
      assert SuperPower.template_check("# Heading\n", "REVIEW") == :ok
      assert SuperPower.template_check("whatever", "CODE") == :ok
      assert SuperPower.template_check("text", "BOGUS") == :ok
    end
  end

  describe "validate_config/1" do
    test "empty map is :ok (all defaults)" do
      assert SuperPower.validate_config(%{}) == :ok
    end

    test "non-map input is :error" do
      assert {:error, msg} = SuperPower.validate_config("not a map")
      assert msg =~ "superpower"
    end

    test "the §12 reference example validates" do
      config = %{
        "enabled" => false,
        "root" => "docs/superpowers",
        "mode" => "mirror",
        "phases" => %{
          "spec" => true,
          "plan" => true,
          "code" => false,
          "review" => true
        },
        "require_plan_checkboxes" => true
      }

      assert SuperPower.validate_config(config) == :ok
    end

    test "enabled non-boolean → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"enabled" => "yes"})
      assert msg =~ "enabled"
    end

    test "mode not in [mirror, enforce] → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"mode" => "weird"})
      assert msg =~ "mode"
    end

    test "root non-binary → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"root" => 42})
      assert msg =~ "root"
    end

    test "root empty string → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"root" => ""})
      assert msg =~ "root"
    end

    test "root whitespace-only → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"root" => "   "})
      assert msg =~ "root"
    end

    test "phases not a map → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"phases" => ["spec", "plan"]})
      assert msg =~ "phases"
    end

    test "phases with unknown phase key → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"phases" => %{"bogus" => true}})
      assert msg =~ "phases"
      assert msg =~ "bogus"
    end

    test "phases with non-boolean value → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"phases" => %{"spec" => "yes"}})
      assert msg =~ "phases.spec"
    end

    test "require_plan_checkboxes non-boolean → error" do
      assert {:error, msg} = SuperPower.validate_config(%{"require_plan_checkboxes" => "yes"})
      assert msg =~ "require_plan_checkboxes"
    end

    test "accepts atom keys via normalization" do
      config = %{
        enabled: false,
        root: "docs/superpowers",
        mode: "mirror",
        phases: %{spec: true, plan: true, code: false, review: true},
        require_plan_checkboxes: true
      }

      assert SuperPower.validate_config(config) == :ok
    end
  end
end
