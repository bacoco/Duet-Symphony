defmodule SymphonyElixir.DuetMetricsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Metrics

  describe "for_phase/2" do
    test "returns :not_observed when no phase_started event exists for the phase" do
      events = [
        %{"kind" => "task_started", "ts" => "2026-05-10T14:00:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC") == :not_observed
    end

    test "returns :not_observed when only a different phase has been observed" do
      events = [
        %{"kind" => "phase_started", "phase" => "PLAN", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC") == :not_observed
    end

    test "computes natural convergence with consensus mode" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "turn_request", "phase" => "SPEC", "cycle" => 1, "actor" => "codex", "ts" => "2026-05-10T14:00:01Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "verdict" => "APPROVE",
          "confidence" => 0.9,
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "claude",
          "verdict" => "APPROVE",
          "confidence" => 0.8,
          "ts" => "2026-05-10T14:00:20Z"
        },
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:00:30Z"}
      ]

      result = Metrics.for_phase(events, "SPEC")

      assert result.cycles_to_converge == 1
      assert result.convergence_mode == :natural
      assert_in_delta result.confidence_delta, 0.1, 1.0e-9
      assert is_float(result.mean_cycle_duration_ms)
      assert result.mean_cycle_duration_ms > 0
      assert result.verification_pass_rate == nil
    end

    test "maps phase_frozen mode=forced to :forced" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 5, "mode" => "forced", "ts" => "2026-05-10T14:05:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :forced
    end

    test "maps phase_frozen mode=tie_breaker to :forced" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 5, "mode" => "tie_breaker", "ts" => "2026-05-10T14:05:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :forced
    end

    test "maps phase_frozen mode=degraded to :degraded" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 3, "mode" => "degraded", "ts" => "2026-05-10T14:05:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :degraded
    end

    test "maps phase_frozen mode=operator_override_author to :natural" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "phase_frozen",
          "phase" => "SPEC",
          "cycle" => 5,
          "mode" => "operator_override_author",
          "ts" => "2026-05-10T14:05:00Z"
        }
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :natural
    end

    test "maps unknown mode strings to :unknown" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 1, "mode" => "mystery", "ts" => "2026-05-10T14:05:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :unknown
    end

    test "treats absent phase_frozen as :unknown" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :unknown
    end

    test "reads convergence mode from extra map when not at top level" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "phase_frozen",
          "phase" => "SPEC",
          "cycle" => 1,
          "extra" => %{"mode" => "forced"},
          "ts" => "2026-05-10T14:05:00Z"
        }
      ]

      assert Metrics.for_phase(events, "SPEC").convergence_mode == :forced
    end

    test "returns confidence_delta=nil when only one actor responded" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "verdict" => "APPROVE",
          "confidence" => 0.9,
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:00:30Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").confidence_delta == nil
    end

    test "returns confidence_delta=nil when one actor's confidence is missing" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "verdict" => "APPROVE",
          "confidence" => 0.9,
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "claude",
          "verdict" => "APPROVE",
          "ts" => "2026-05-10T14:00:20Z"
        }
      ]

      assert Metrics.for_phase(events, "SPEC").confidence_delta == nil
    end

    test "uses LAST turn_response per actor when actors respond multiple times" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "confidence" => 0.5,
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 2,
          "actor" => "codex",
          "confidence" => 0.95,
          "ts" => "2026-05-10T14:01:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 2,
          "actor" => "claude",
          "confidence" => 0.85,
          "ts" => "2026-05-10T14:01:20Z"
        },
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 2, "mode" => "consensus", "ts" => "2026-05-10T14:01:30Z"}
      ]

      assert_in_delta Metrics.for_phase(events, "SPEC").confidence_delta, 0.1, 1.0e-9
    end

    test "reports cycles_to_converge as the highest cycle observed" do
      events = [
        %{"kind" => "phase_started", "phase" => "PLAN", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "PLAN",
          "cycle" => 1,
          "actor" => "codex",
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "PLAN",
          "cycle" => 2,
          "actor" => "claude",
          "ts" => "2026-05-10T14:01:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "PLAN",
          "cycle" => 3,
          "actor" => "codex",
          "ts" => "2026-05-10T14:02:10Z"
        },
        %{"kind" => "phase_frozen", "phase" => "PLAN", "cycle" => 3, "mode" => "consensus", "ts" => "2026-05-10T14:02:30Z"}
      ]

      assert Metrics.for_phase(events, "PLAN").cycles_to_converge == 3
    end

    test "reports cycles_to_converge=0 when no turn_response events exist" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"}
      ]

      result = Metrics.for_phase(events, "SPEC")
      assert result.cycles_to_converge == 0
      assert result.mean_cycle_duration_ms == nil
    end

    test "verification_pass_rate is 2/3 ≈ 0.667 when 2 of 3 verifications passed" do
      events = [
        %{"kind" => "phase_started", "phase" => "CODE", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "verification_completed", "phase" => "CODE", "status" => "pass", "ts" => "2026-05-10T14:00:10Z"},
        %{"kind" => "verification_completed", "phase" => "CODE", "status" => "fail", "ts" => "2026-05-10T14:00:20Z"},
        %{"kind" => "verification_completed", "phase" => "CODE", "status" => "pass", "ts" => "2026-05-10T14:00:30Z"},
        %{"kind" => "phase_frozen", "phase" => "CODE", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:00:40Z"}
      ]

      assert_in_delta Metrics.for_phase(events, "CODE").verification_pass_rate, 2 / 3, 1.0e-9
    end

    test "verification_pass_rate is nil when no verification_completed events observed" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:00:30Z"}
      ]

      assert Metrics.for_phase(events, "SPEC").verification_pass_rate == nil
    end

    test "verification status read from extra when not at top level" do
      events = [
        %{"kind" => "phase_started", "phase" => "CODE", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "verification_completed",
          "phase" => "CODE",
          "extra" => %{"status" => "pass"},
          "ts" => "2026-05-10T14:00:10Z"
        }
      ]

      assert Metrics.for_phase(events, "CODE").verification_pass_rate == 1.0
    end

    test "mean_cycle_duration_ms is nil when timestamps are unparseable" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "not-a-timestamp"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "confidence" => 0.9,
          "ts" => "still-not-a-timestamp"
        }
      ]

      assert Metrics.for_phase(events, "SPEC").mean_cycle_duration_ms == nil
    end

    test "mean_cycle_duration_ms divides span by cycles" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "confidence" => 0.9,
          "ts" => "2026-05-10T14:00:30Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 2,
          "actor" => "claude",
          "confidence" => 0.85,
          "ts" => "2026-05-10T14:01:00Z"
        },
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 2, "mode" => "consensus", "ts" => "2026-05-10T14:02:00Z"}
      ]

      # Span = 14:00:00 → 14:02:00 = 120 seconds = 120_000 ms.
      # Cycles = 2 → mean = 60_000 ms per cycle.
      assert_in_delta Metrics.for_phase(events, "SPEC").mean_cycle_duration_ms, 60_000.0, 1.0e-6
    end
  end

  describe "for_task/1" do
    test "returns empty phases and zero totals when no phases observed" do
      result = Metrics.for_task([])

      assert result.total_cycles == 0
      assert result.convergence_velocity == nil
      assert result.escalation_count == 0
      assert result.degraded_phases == 0
      assert result.phases == %{}
    end

    test "aggregates SPEC and PLAN observed phases" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "codex",
          "confidence" => 0.9,
          "ts" => "2026-05-10T14:00:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "SPEC",
          "cycle" => 1,
          "actor" => "claude",
          "confidence" => 0.85,
          "ts" => "2026-05-10T14:00:20Z"
        },
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:00:30Z"},
        %{"kind" => "phase_started", "phase" => "PLAN", "cycle" => 1, "ts" => "2026-05-10T14:01:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "PLAN",
          "cycle" => 1,
          "actor" => "codex",
          "confidence" => 0.7,
          "ts" => "2026-05-10T14:01:10Z"
        },
        %{
          "kind" => "turn_response",
          "phase" => "PLAN",
          "cycle" => 2,
          "actor" => "claude",
          "confidence" => 0.8,
          "ts" => "2026-05-10T14:02:10Z"
        },
        %{"kind" => "phase_frozen", "phase" => "PLAN", "cycle" => 2, "mode" => "consensus", "ts" => "2026-05-10T14:02:30Z"}
      ]

      result = Metrics.for_task(events)

      assert Map.keys(result.phases) |> Enum.sort() == ["PLAN", "SPEC"]
      assert result.phases["SPEC"].cycles_to_converge == 1
      assert result.phases["PLAN"].cycles_to_converge == 2
      assert result.total_cycles == 3
      assert_in_delta result.convergence_velocity, 2 / 3, 1.0e-9
      assert result.escalation_count == 0
      assert result.degraded_phases == 0
    end

    test "convergence_velocity is nil when total_cycles is 0" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"}
      ]

      result = Metrics.for_task(events)
      assert result.total_cycles == 0
      assert result.convergence_velocity == nil
    end

    test "counts forced-mode phases into escalation_count" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 5, "mode" => "forced", "ts" => "2026-05-10T14:05:00Z"},
        %{"kind" => "phase_started", "phase" => "PLAN", "cycle" => 1, "ts" => "2026-05-10T14:06:00Z"},
        %{"kind" => "phase_frozen", "phase" => "PLAN", "cycle" => 1, "mode" => "consensus", "ts" => "2026-05-10T14:07:00Z"}
      ]

      assert Metrics.for_task(events).escalation_count == 1
    end

    test "counts phase_cap_escalation events into escalation_count" do
      events = [
        %{"kind" => "phase_started", "phase" => "CODE", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{
          "kind" => "turn_response",
          "phase" => "CODE",
          "cycle" => 5,
          "actor" => "codex",
          "ts" => "2026-05-10T14:05:00Z"
        },
        %{"kind" => "phase_cap_escalation", "phase" => "CODE", "cycle" => 5, "ts" => "2026-05-10T14:05:30Z"}
      ]

      result = Metrics.for_task(events)
      # phase_frozen absent → unknown mode (not :forced), but phase_cap_escalation alone counts.
      assert result.escalation_count == 1
    end

    test "deduplicates a phase that is both forced and saw a phase_cap_escalation" do
      events = [
        %{"kind" => "phase_started", "phase" => "CODE", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_cap_escalation", "phase" => "CODE", "cycle" => 5, "ts" => "2026-05-10T14:05:00Z"},
        %{"kind" => "phase_frozen", "phase" => "CODE", "cycle" => 5, "mode" => "forced", "ts" => "2026-05-10T14:06:00Z"}
      ]

      assert Metrics.for_task(events).escalation_count == 1
    end

    test "counts degraded_phases" do
      events = [
        %{"kind" => "phase_started", "phase" => "SPEC", "cycle" => 1, "ts" => "2026-05-10T14:00:00Z"},
        %{"kind" => "phase_frozen", "phase" => "SPEC", "cycle" => 3, "mode" => "degraded", "ts" => "2026-05-10T14:03:00Z"},
        %{"kind" => "phase_started", "phase" => "PLAN", "cycle" => 1, "ts" => "2026-05-10T14:04:00Z"},
        %{"kind" => "phase_frozen", "phase" => "PLAN", "cycle" => 3, "mode" => "degraded", "ts" => "2026-05-10T14:07:00Z"}
      ]

      assert Metrics.for_task(events).degraded_phases == 2
    end
  end

  describe "forced_rate/2" do
    test "returns 0.0 for an empty list" do
      assert Metrics.forced_rate([]) == 0.0
      assert Metrics.forced_rate([], 5) == 0.0
    end

    test "returns 1.0 when every entry in the window is :forced" do
      assert Metrics.forced_rate([:forced, :forced, :forced, :forced, :forced], 5) == 1.0
    end

    test "returns 0.3 for 3 forced and 7 natural in a 10-window" do
      results =
        [:natural, :natural, :forced, :natural, :natural, :forced, :natural, :forced, :natural, :natural]

      assert_in_delta Metrics.forced_rate(results, 10), 0.3, 1.0e-9
    end

    test "uses actual list length when window is larger than list" do
      assert Metrics.forced_rate([:forced, :natural], 20) == 0.5
    end

    test "trims to the last `window` entries (newest)" do
      # 5 forced, then 3 natural — window of 3 covers only the natural tail.
      results = [:forced, :forced, :forced, :forced, :forced, :natural, :natural, :natural]
      assert Metrics.forced_rate(results, 3) == 0.0
    end

    test "default window of 20 trims oldest entries" do
      # 25 entries, oldest 5 are :forced, newest 20 are :natural → forced_rate = 0.0.
      results = List.duplicate(:forced, 5) ++ List.duplicate(:natural, 20)
      assert Metrics.forced_rate(results) == 0.0
    end

    test "treats :degraded entries as not forced" do
      assert Metrics.forced_rate([:degraded, :degraded, :forced, :natural], 4) == 0.25
    end
  end
end
