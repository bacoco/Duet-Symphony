defmodule SymphonyElixir.DuetNotificationHookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.NotificationHook
  alias SymphonyElixir.Duet.NotificationHook.NullRunner
  alias SymphonyElixir.Duet.NotificationHook.Runner

  defmodule MockRunner do
    @behaviour SymphonyElixir.Duet.NotificationHook.Runner

    def dispatch(event_kind, payload, opts) do
      send(self(), {:notification_dispatched, event_kind, payload, opts})
      Process.get(:notification_response, :ok)
    end
  end

  defmodule OptRunner do
    @behaviour SymphonyElixir.Duet.NotificationHook.Runner

    def dispatch(_event_kind, _payload, _opts), do: :ok
  end

  describe "hook_events/0" do
    test "returns the canonical 8-event list" do
      events = NotificationHook.hook_events()

      assert is_list(events)
      assert length(events) == 8

      assert events == [
               :phase_cap_escalation,
               :pathological_disagreement,
               :code_pr_conflict,
               :state_divergence,
               :human_checkpoint_timeout,
               :verification_timeout,
               :superpower_artifact_invalid,
               :bot_integration_missing
             ]
    end
  end

  describe "hook_event?/1" do
    test "is true for each recognized kind" do
      for kind <- NotificationHook.hook_events() do
        assert NotificationHook.hook_event?(kind), "expected #{inspect(kind)} to be a hook event"
      end
    end

    test "is false for :bogus" do
      refute NotificationHook.hook_event?(:bogus)
    end

    test "is false for an unrelated atom" do
      refute NotificationHook.hook_event?(:something_else)
    end
  end

  describe "runner/1" do
    test "defaults to NullRunner when no opt and no app env" do
      assert NotificationHook.runner() == NullRunner
      assert NotificationHook.runner([]) == NullRunner
    end

    test "honors :runner opt" do
      assert NotificationHook.runner(runner: MockRunner) == MockRunner
    end

    test "honors app env override" do
      Application.put_env(:symphony_elixir, :duet_notification_hook_runner, MockRunner)
      assert NotificationHook.runner() == MockRunner
    end

    test "opt takes precedence over app env" do
      Application.put_env(:symphony_elixir, :duet_notification_hook_runner, NullRunner)
      assert NotificationHook.runner(runner: OptRunner) == OptRunner
    end

    test "ignores non-module :runner opt and falls back to app env / default" do
      assert NotificationHook.runner(runner: nil) == NullRunner
    end
  end

  describe "dispatch/3" do
    test "calls the runner with the right args" do
      payload = %{task_id: "TASK/1", phase: "CODE", reason: "cap_reached"}
      opts = [runner: MockRunner, extra: :metadata]

      assert :ok = NotificationHook.dispatch(:phase_cap_escalation, payload, opts)
      assert_received {:notification_dispatched, :phase_cap_escalation, ^payload, ^opts}
    end

    test "returns :ok from NullRunner for any recognized kind" do
      for kind <- NotificationHook.hook_events() do
        assert :ok = NotificationHook.dispatch(kind, %{kind: kind}, runner: NullRunner)
      end
    end

    test "returns mock's canned {:error, :timeout} when configured" do
      Process.put(:notification_response, {:error, :timeout})

      assert {:error, :timeout} =
               NotificationHook.dispatch(:pathological_disagreement, %{}, runner: MockRunner)
    after
      Process.delete(:notification_response)
    end

    test "returns {:error, {:unknown_event_kind, :bogus}} without calling the runner" do
      assert {:error, {:unknown_event_kind, :bogus}} =
               NotificationHook.dispatch(:bogus, %{}, runner: MockRunner)

      refute_received {:notification_dispatched, _kind, _payload, _opts}
    end

    test "honors :runner opt" do
      payload = %{task_id: "TASK/2"}

      assert :ok = NotificationHook.dispatch(:code_pr_conflict, payload, runner: MockRunner)
      assert_received {:notification_dispatched, :code_pr_conflict, ^payload, _opts}
    end

    test "uses app env runner when no :runner opt is supplied" do
      Application.put_env(:symphony_elixir, :duet_notification_hook_runner, MockRunner)

      assert :ok = NotificationHook.dispatch(:state_divergence, %{detail: :appenv})
      assert_received {:notification_dispatched, :state_divergence, %{detail: :appenv}, []}
    end

    test "defaults to NullRunner when no opt and no app env" do
      assert :ok = NotificationHook.dispatch(:bot_integration_missing, %{any: :payload})
    end
  end

  describe "NullRunner.dispatch/3" do
    test "always returns :ok and does not crash on any payload" do
      assert :ok = NullRunner.dispatch(:phase_cap_escalation, %{}, [])
      assert :ok = NullRunner.dispatch(:pathological_disagreement, %{anything: 1}, [])
      assert :ok = NullRunner.dispatch(:bogus_event_kind, %{nested: %{deep: [1, 2, 3]}}, foo: :bar)
      assert :ok = NullRunner.dispatch(:any_atom, %{}, [])
    end
  end

  describe "behaviour conformance" do
    test "NullRunner declares the NotificationHook.Runner behaviour" do
      behaviours =
        :attributes
        |> NullRunner.module_info()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Runner in behaviours
    end

    test "NullRunner implements the dispatch/3 callback" do
      Code.ensure_loaded!(NullRunner)
      assert {:dispatch, 3} in NullRunner.__info__(:functions)

      assert {:dispatch, 3} in Runner.behaviour_info(:callbacks)
    end
  end
end
