defmodule SymphonyElixir.DuetVerificationGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.VerificationGate

  describe "aggregate_status/1" do
    test "empty list aggregates to :partial" do
      assert VerificationGate.aggregate_status([]) == :partial
    end

    test "all :pass aggregates to :pass" do
      assert VerificationGate.aggregate_status([:pass, :pass]) == :pass
    end

    test "all :fail aggregates to :fail" do
      assert VerificationGate.aggregate_status([:fail, :fail]) == :fail
    end

    test "mixed :pass and :fail aggregates to :partial" do
      assert VerificationGate.aggregate_status([:pass, :fail]) == :partial
    end

    test ":timeout mixed with completed checks aggregates to :partial" do
      assert VerificationGate.aggregate_status([:pass, :timeout]) == :partial
      assert VerificationGate.aggregate_status([:fail, :timeout]) == :partial
    end

    test "all :timeout aggregates to :timeout" do
      assert VerificationGate.aggregate_status([:timeout, :timeout]) == :timeout
    end

    test "single :partial aggregates to :partial" do
      assert VerificationGate.aggregate_status([:partial]) == :partial
    end

    test "invalid status falls back to :partial" do
      assert VerificationGate.aggregate_status([:pass, :bogus]) == :partial
    end

    test "single :pass aggregates to :pass" do
      assert VerificationGate.aggregate_status([:pass]) == :pass
    end
  end

  describe "build_block/2" do
    test "renders the spec §8.7 example shape with two checks" do
      checks = [
        %{name: "ci/tests", status: :pass, summary: "247 tests passed, 0 failed"},
        %{name: "ci/lint", status: :fail, summary: "3 ESLint errors in src/auth.ts"}
      ]

      expected =
        """
        ---DUET-VERIFICATION---
        status: partial
        checks:
          - name: "ci/tests"
            status: pass
            summary: "247 tests passed, 0 failed"
          - name: "ci/lint"
            status: fail
            summary: "3 ESLint errors in src/auth.ts"
        ---END-DUET-VERIFICATION---
        """
        |> String.trim_trailing()

      assert VerificationGate.build_block(checks, :partial) == expected
    end

    test "omits summary line for a check with no :summary key" do
      checks = [%{name: "ci/tests", status: :pass}]

      expected =
        String.trim_trailing("""
        ---DUET-VERIFICATION---
        status: pass
        checks:
          - name: "ci/tests"
            status: pass
        ---END-DUET-VERIFICATION---
        """)

      output = VerificationGate.build_block(checks, :pass)

      assert output == expected
      refute output =~ "summary:"
    end

    test "omits summary line when :summary is nil" do
      checks = [%{name: "ci/tests", status: :pass, summary: nil}]

      output = VerificationGate.build_block(checks, :pass)

      refute output =~ "summary:"
      assert output =~ ~s(  - name: "ci/tests")
      assert output =~ "    status: pass"
    end

    test "emits checks: [] for empty checks list" do
      output = VerificationGate.build_block([], :pass)

      assert output ==
               String.trim_trailing("""
               ---DUET-VERIFICATION---
               status: pass
               checks: []
               ---END-DUET-VERIFICATION---
               """)
    end

    test "output contains start_marker/0 and end_marker/0" do
      checks = [%{name: "ci/tests", status: :pass, summary: "ok"}]
      output = VerificationGate.build_block(checks, :pass)

      assert String.starts_with?(output, VerificationGate.start_marker())
      assert String.ends_with?(output, VerificationGate.end_marker())
    end

    test "renders all four status atoms as bare lowercase strings" do
      checks = [
        %{name: "a", status: :pass},
        %{name: "b", status: :fail},
        %{name: "c", status: :partial},
        %{name: "d", status: :timeout}
      ]

      output = VerificationGate.build_block(checks, :timeout)

      assert output =~ "status: timeout\n"
      assert output =~ "    status: pass"
      assert output =~ "    status: fail"
      assert output =~ "    status: partial"
      assert output =~ "    status: timeout"
    end

    test "escapes quotes, backslashes, newlines, and Duet markers in text fields" do
      checks = [
        %{
          name: "ci/\"tests\"",
          status: :fail,
          summary: "line one\nline two \\ #{VerificationGate.end_marker()}"
        }
      ]

      output = VerificationGate.build_block(checks, :fail)

      assert output =~ ~s(  - name: "ci/\\"tests\\"")
      assert output =~ ~s(summary: "line one\\nline two \\\\ [DUET_VERIFICATION_MARKER_REDACTED]")
      refute output =~ VerificationGate.end_marker() <> "\""
    end
  end

  describe "timeout_block/1" do
    test "uses the supplied check name" do
      output = VerificationGate.timeout_block("ci/tests")

      assert output =~ ~s(  - name: "ci/tests")
      assert output =~ "    status: timeout"
    end

    test "falls back to verification_timeout for an empty string" do
      output = VerificationGate.timeout_block("")

      assert output =~ ~s(  - name: "verification_timeout")
      assert output =~ "    status: timeout"
    end

    test "aggregate status in the block is timeout" do
      output = VerificationGate.timeout_block("ci/tests")

      assert output =~ "status: timeout\n"
    end

    test "uses fallback name when input is whitespace-only" do
      output = VerificationGate.timeout_block("   ")

      assert output =~ ~s(  - name: "verification_timeout")
    end

    test "includes the canonical timeout summary" do
      output = VerificationGate.timeout_block("ci/tests")

      assert output =~ ~s(    summary: "Verification check timed out")
    end
  end

  describe "marker constants" do
    test "start_marker/0 returns the literal start marker" do
      assert VerificationGate.start_marker() == "---DUET-VERIFICATION---"
    end

    test "end_marker/0 returns the literal end marker" do
      assert VerificationGate.end_marker() == "---END-DUET-VERIFICATION---"
    end
  end

  describe "validate_config/1" do
    test "empty map is :ok" do
      assert :ok = VerificationGate.validate_config(%{})
    end

    test "non-map input is :error" do
      assert {:error, message} = VerificationGate.validate_config(:not_a_map)
      assert message =~ "verification_gate must be a map"
    end

    test "spec §12 default config is :ok" do
      default_config = %{
        "enabled" => false,
        "phases" => ["code"],
        "mode" => "github_checks",
        "github_checks" => %{"required_contexts" => [], "timeout_ms" => 300_000},
        "local_command" => %{"run" => nil, "timeout_ms" => 300_000},
        "inject_into" => "reviewer",
        "on_timeout" => "warn"
      }

      assert :ok = VerificationGate.validate_config(default_config)
    end

    test "non-boolean enabled is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"enabled" => "yes"})
      assert message =~ "verification_gate.enabled"
    end

    test "phases not a list is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"phases" => "code"})
      assert message =~ "verification_gate.phases"
    end

    test "phases containing an unknown phase is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"phases" => ["code", "deploy"]})
      assert message =~ "verification_gate.phases"
      assert message =~ "deploy"
    end

    test "mode not in allowed values is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"mode" => "bogus"})
      assert message =~ "verification_gate.mode"
      assert message =~ "bogus"
    end

    test "inject_into not in allowed values is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"inject_into" => "author"})
      assert message =~ "verification_gate.inject_into"
      assert message =~ "author"
    end

    test "on_timeout not in allowed values is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"on_timeout" => "ignore"})
      assert message =~ "verification_gate.on_timeout"
      assert message =~ "ignore"
    end

    test "github_checks.required_contexts not a list is :error" do
      config = %{"github_checks" => %{"required_contexts" => "ci/tests"}}
      assert {:error, message} = VerificationGate.validate_config(config)
      assert message =~ "verification_gate.github_checks.required_contexts"
    end

    test "github_checks.timeout_ms non-positive is :error" do
      config = %{"github_checks" => %{"timeout_ms" => 0}}
      assert {:error, message} = VerificationGate.validate_config(config)
      assert message =~ "verification_gate.github_checks.timeout_ms"
    end

    test "local_command.run non-nil-non-binary is :error" do
      config = %{"local_command" => %{"run" => 123}}
      assert {:error, message} = VerificationGate.validate_config(config)
      assert message =~ "verification_gate.local_command.run"
    end

    test "local_command.run nil is :ok" do
      config = %{"local_command" => %{"run" => nil}}
      assert :ok = VerificationGate.validate_config(config)
    end

    test "local_command.timeout_ms non-positive is :error" do
      config = %{"local_command" => %{"timeout_ms" => -1}}
      assert {:error, message} = VerificationGate.validate_config(config)
      assert message =~ "verification_gate.local_command.timeout_ms"
    end

    test "github_checks not a map is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"github_checks" => "ci"})
      assert message =~ "verification_gate.github_checks"
    end

    test "local_command not a map is :error" do
      assert {:error, message} = VerificationGate.validate_config(%{"local_command" => "npm test"})
      assert message =~ "verification_gate.local_command"
    end
  end
end
