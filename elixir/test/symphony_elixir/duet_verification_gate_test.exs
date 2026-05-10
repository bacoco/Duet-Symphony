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

    test ":timeout dominates over :pass" do
      assert VerificationGate.aggregate_status([:pass, :timeout]) == :timeout
    end

    test ":timeout dominates over :fail" do
      assert VerificationGate.aggregate_status([:fail, :timeout]) == :timeout
    end

    test "single :partial aggregates to :partial" do
      assert VerificationGate.aggregate_status([:partial]) == :partial
    end

    test "invalid status falls back to :partial" do
      assert VerificationGate.aggregate_status([:pass, :bogus]) == :partial
    end

    test "all :timeout aggregates to :timeout" do
      assert VerificationGate.aggregate_status([:timeout, :timeout]) == :timeout
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
end
