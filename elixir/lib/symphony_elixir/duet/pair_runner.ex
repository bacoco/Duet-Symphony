defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Placeholder for the future Claude + Codex pair runner.

  The current slice can drive the SPEC Author turn when the selected routing
  profile assigns that role to Codex. It records the request, dispatches one
  Codex App Server turn through `SymphonyElixir.Duet.TurnDriver`, writes the
  transcript, parses the Duet trailer, then stops with
  `{:error, :reviewer_not_implemented}` because the counterpart turn and
  convergence loop are not wired yet.

  Profiles whose SPEC Author is not Codex still return
  `{:error, :not_implemented}` after running the shared workspace lifecycle.
  This means the workspace can be created and hooks can run before the runner
  fails. The orchestrator dispatch wrapper (`SymphonyElixir.Orchestrator`)
  raises a `RuntimeError` when a runner returns an error tuple, which causes
  the issue task to crash and trigger the standard retry policy. Initial state
  events are idempotent across retries. Do not enable `duet: enabled: true` in
  a production `WORKFLOW.md` until the full pair loop is implemented.
  """

  alias SymphonyElixir.Duet.{
    EventLog,
    PhasePrompt,
    Routing,
    RoutingSelection,
    Transcripts,
    Turn,
    TurnDrivers.CodexAppServer
  }

  alias SymphonyElixir.RunnerRuntime

  @spec run(map(), pid() | nil, keyword()) :: {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_loop/5)
  end

  defp run_pair_loop(workspace, issue, update_recipient, opts, worker_host) do
    with {:ok, profile} <- RoutingSelection.resolve(SymphonyElixir.Config.settings!().duet),
         :ok <- ensure_initial_state_events(issue, profile) do
      run_spec_author(workspace, issue, update_recipient, opts, worker_host, profile)
    else
      {:error, reason} -> {:error, {:state_event_failed, reason}}
    end
  end

  defp run_spec_author(workspace, issue, update_recipient, opts, worker_host, profile) do
    case spec_author(profile) do
      "codex" -> run_codex_spec_author(workspace, issue, update_recipient, opts, worker_host, profile)
      _other -> run_unsupported_spec_author(issue)
    end
  end

  defp run_unsupported_spec_author(issue) do
    with :ok <- ensure_failure_event(issue, "not_implemented") do
      {:error, :not_implemented}
    end
  end

  defp run_codex_spec_author(workspace, issue, update_recipient, opts, worker_host, profile) do
    if turn_response_recorded?(issue, "SPEC", 1, "codex") do
      with :ok <- ensure_failure_event(issue, "reviewer_not_implemented") do
        {:error, :reviewer_not_implemented}
      end
    else
      do_run_codex_spec_author(workspace, issue, update_recipient, opts, worker_host, profile)
    end
  end

  defp do_run_codex_spec_author(workspace, issue, update_recipient, opts, worker_host, profile) do
    prompt = build_author_prompt(issue, profile)
    driver = Keyword.get(opts, :turn_driver, CodexAppServer)
    driver_opts = turn_driver_opts(workspace, issue, update_recipient, opts, worker_host)

    with :ok <- Turn.record_request(issue, "SPEC", 1, "codex"),
         {:ok, response_text} <- driver.drive_turn(prompt, driver_opts),
         {:ok, _path} <- Transcripts.write(issue, "SPEC", 1, "codex", prompt, response_text),
         {:ok, _turn, _issues} <- Turn.record_response(issue, "SPEC", 1, "codex", response_text),
         :ok <- ensure_failure_event(issue, "reviewer_not_implemented") do
      {:error, :reviewer_not_implemented}
    else
      {:error, reason} -> {:error, {:codex_spec_author_failed, reason}}
    end
  end

  defp build_author_prompt(issue, profile) do
    PhasePrompt.build(%PhasePrompt{
      task_id: Map.get(issue, :id) || Map.get(issue, :identifier),
      issue_title: Map.get(issue, :title) || "",
      issue_description: Map.get(issue, :description) || "",
      phase: "SPEC",
      cycle: 1,
      max_cycles_per_phase: SymphonyElixir.Config.settings!().duet.max_cycles_per_phase,
      role: :author,
      actor: "codex",
      counterpart: counterpart_for(profile, "spec"),
      profile_name: profile.name,
      profile_mode: profile.mode
    })
  end

  defp counterpart_for(profile, phase) do
    profile.phases
    |> Map.get(phase, %Routing.Phase{})
    |> Map.get(:reviewers, [])
    |> case do
      [] -> "none"
      reviewers -> Enum.join(reviewers, ", ")
    end
  end

  defp turn_driver_opts(workspace, issue, update_recipient, opts, worker_host) do
    opts
    |> Keyword.get(:turn_driver_opts, [])
    |> Keyword.put_new(:workspace, workspace)
    |> Keyword.put_new(:issue, issue)
    |> Keyword.put_new(:worker_host, worker_host)
    |> Keyword.put_new(:on_message, codex_message_handler(update_recipient, issue))
  end

  defp codex_message_handler(recipient, issue) do
    fn message -> send_codex_update(recipient, issue, message) end
  end

  defp send_codex_update(recipient, %{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp ensure_initial_state_events(issue, profile) do
    with :ok <- append_once(issue, "task_started", task_attrs(issue)),
         :ok <- ensure_routing_selected(issue, Routing.to_event_attrs(profile)) do
      append_once(issue, "phase_started", %{phase: "SPEC", cycle: 1}, %{"phase" => "SPEC", "cycle" => 1})
    end
  end

  defp ensure_failure_event(issue, reason) do
    append_once(issue, "task_failed", %{reason: reason}, %{"reason" => reason})
  end

  defp turn_response_recorded?(issue, phase, cycle, actor) do
    case EventLog.read(issue) do
      {:ok, events} ->
        Enum.any?(events, &event_matches?(&1, "turn_response", %{"phase" => phase, "cycle" => cycle, "actor" => actor}))

      {:error, _reason} ->
        false
    end
  end

  defp spec_author(profile) do
    profile.phases
    |> Map.get("spec", %Routing.Phase{})
    |> Map.get(:author)
  end

  defp append_once(issue, kind, attrs, match_attrs \\ %{}) do
    with {:ok, events} <- EventLog.read(issue) do
      if Enum.any?(events, &event_matches?(&1, kind, match_attrs)) do
        :ok
      else
        append_event(issue, kind, attrs)
      end
    end
  end

  defp ensure_routing_selected(issue, attrs) do
    current = stringify_keys(attrs)

    case EventLog.read(issue) do
      {:ok, events} ->
        events
        |> Enum.find(&(Map.get(&1, "kind") == "agent_routing_selected"))
        |> ensure_routing_event(issue, attrs, current)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_routing_event(nil, issue, attrs, _current) do
    append_event(issue, "agent_routing_selected", attrs)
  end

  defp ensure_routing_event(recorded, _issue, _attrs, current) do
    recorded_routing = Map.take(recorded, ["profile_name", "mode", "degraded", "phases"])

    if recorded_routing == current do
      :ok
    else
      {:error, {:routing_divergence, recorded_routing, current}}
    end
  end

  defp append_event(issue, kind, attrs) do
    case EventLog.append(issue, kind, attrs) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_matches?(event, kind, match_attrs) do
    Map.get(event, "kind") == kind and Enum.all?(match_attrs, fn {key, value} -> Map.get(event, key) == value end)
  end

  defp task_attrs(issue) do
    %{
      identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title)
    }
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
