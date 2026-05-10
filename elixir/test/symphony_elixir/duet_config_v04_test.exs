defmodule SymphonyElixir.DuetConfigV04Test do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.SuperPower
  alias SymphonyElixir.Duet.ToolProfile
  alias SymphonyElixir.Duet.VerificationGate

  describe "default duet config exposes the v0.4 fields" do
    test "tool_profiles default mirrors the spec §12 reference config" do
      settings = Config.settings!()

      assert settings.duet.tool_profiles == %{
               "enabled" => false,
               "default_profile" => "default",
               "profiles" => %{
                 "default" => %{
                   "spec" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
                   "plan" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
                   "code" => %{"author" => "all", "reviewers" => %{"default" => "all"}},
                   "review" => %{"coder_ack" => "all", "reviewer" => "all"}
                 }
               }
             }

      assert :ok = ToolProfile.validate_config(settings.duet.tool_profiles)
    end

    test "verification_gate default mirrors the spec §12 reference config" do
      settings = Config.settings!()

      assert settings.duet.verification_gate == %{
               "enabled" => false,
               "phases" => ["code"],
               "mode" => "github_checks",
               "github_checks" => %{"required_contexts" => [], "timeout_ms" => 300_000},
               "local_command" => %{"run" => nil, "timeout_ms" => 300_000},
               "inject_into" => "reviewer",
               "on_timeout" => "warn"
             }

      assert :ok = VerificationGate.validate_config(settings.duet.verification_gate)
    end

    test "superpower default mirrors the spec §12 reference config" do
      settings = Config.settings!()

      assert settings.duet.superpower == %{
               "enabled" => false,
               "root" => "docs/superpowers",
               "mode" => "mirror",
               "phases" => %{"spec" => true, "plan" => true, "code" => false, "review" => true},
               "require_plan_checkboxes" => true
             }

      assert :ok = SuperPower.validate_config(settings.duet.superpower)
    end

    test "default settings validate cleanly" do
      assert :ok = Config.validate!()
    end
  end

  describe "tool_profiles config wiring" do
    test "valid override parses and validates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          tool_profiles:
            enabled: true
            default_profile: strict_review
            profiles:
              default:
                spec:   { author: all, reviewers: { default: all } }
                plan:   { author: all, reviewers: { default: all } }
                code:   { author: all, reviewers: { default: all } }
                review: { coder_ack: all, reviewer: all }
              strict_review:
                spec:   { author: all, reviewers: { default: all } }
                plan:   { author: all, reviewers: { default: all } }
                code:
                  author: [file_write, git_push, shell]
                  reviewers:
                    default: [file_read, git_diff, shell_readonly]
                review: { coder_ack: [file_read, git_diff], reviewer: [file_read, git_diff] }
        """
      )

      assert :ok = Config.validate!()
      settings = Config.settings!()
      assert settings.duet.tool_profiles["enabled"] == true
      assert settings.duet.tool_profiles["default_profile"] == "strict_review"
      assert Map.has_key?(settings.duet.tool_profiles["profiles"], "strict_review")
    end

    test "default_profile not in profiles is rejected when enabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          tool_profiles:
            enabled: true
            default_profile: missing_profile
            profiles:
              default:
                spec:   { author: all, reviewers: { default: all } }
                plan:   { author: all, reviewers: { default: all } }
                code:   { author: all, reviewers: { default: all } }
                review: { coder_ack: all, reviewer: all }
        """
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "tool_profiles.default_profile"
      assert message =~ "missing_profile"
    end
  end

  describe "verification_gate config wiring" do
    test "valid github_checks override parses and validates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          verification_gate:
            enabled: true
            phases: [code]
            mode: github_checks
            github_checks:
              required_contexts: ["ci/tests", "ci/lint"]
              timeout_ms: 600000
            inject_into: reviewer
            on_timeout: warn
        """
      )

      assert :ok = Config.validate!()
      settings = Config.settings!()
      assert settings.duet.verification_gate["enabled"] == true
      assert settings.duet.verification_gate["mode"] == "github_checks"
      assert settings.duet.verification_gate["phases"] == ["code"]
      assert settings.duet.verification_gate["github_checks"]["required_contexts"] == ["ci/tests", "ci/lint"]
      assert settings.duet.verification_gate["github_checks"]["timeout_ms"] == 600_000
    end

    test "unknown mode is rejected" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          verification_gate:
            enabled: true
            mode: bogus
        """
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "verification_gate.mode"
      assert message =~ "bogus"
    end
  end

  describe "superpower config wiring" do
    test "valid enforce override parses and validates" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          superpower:
            enabled: true
            root: docs/superpowers
            mode: enforce
            phases:
              spec: true
              plan: true
              code: false
              review: true
            require_plan_checkboxes: true
        """
      )

      assert :ok = Config.validate!()
      settings = Config.settings!()
      assert settings.duet.superpower["enabled"] == true
      assert settings.duet.superpower["mode"] == "enforce"
      assert settings.duet.superpower["root"] == "docs/superpowers"
    end

    test "unknown mode is rejected" do
      write_workflow_file!(Workflow.workflow_file_path(),
        duet_yaml: """
        duet:
          enabled: true
          superpower:
            enabled: true
            mode: bogus
        """
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "superpower.mode"
      assert message =~ "bogus"
    end
  end
end
