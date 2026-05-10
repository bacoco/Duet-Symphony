defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Claude + Codex pair runner for Duet mode.

  The current implementation wires the SPEC phase loop end to end:
  Author turn, Reviewer turn, trailer recording, transcript persistence,
  convergence evaluation, cycle continuation, and SPEC freeze. Later
  slices will reuse this phase driver for PLAN/CODE/REVIEW and attach
  the GitHub PR side effects returned by the pure helper modules.

  A frozen SPEC currently stops with `{:error, :plan_not_implemented}` on
  the next continuation dispatch because PLAN is not wired yet. This is
  deliberate for the first wave-8 slice: it proves real pair convergence
  without pretending the full task pipeline exists.
  """

  alias SymphonyElixir.Duet.{
    Convergence,
    ConvergenceOrchestrator,
    EventLog,
    PhasePrompt,
    Routing,
    RoutingSelection,
    Transcripts,
    Turn,
    TurnDrivers.ClaudeCode,
    TurnDrivers.CodexAppServer
  }

  alias SymphonyElixir.RunnerRuntime

  @phase "SPEC"
  @phase_key "spec"

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_loop/5)
  end

  defp run_pair_loop(workspace, issue, update_recipient, opts, worker_host) do
    with {:ok, profile} <- RoutingSelection.resolve(SymphonyElixir.Config.settings!().duet),
         :ok <- ensure_initial_state_events(issue, profile) do
      if phase_frozen?(issue, @phase) do
        {:error, :plan_not_implemented}
      else
        run_spec_phase(context(workspace, issue, update_recipient, opts, worker_host, profile))
      end
    else
      {:error, reason} -> {:error, {:state_event_failed, reason}}
    end
  end

  defp context(workspace, issue, update_recipient, opts, worker_host, profile) do
    %{
      workspace: workspace,
      issue: issue,
      update_recipient: update_recipient,
      opts: opts,
      worker_host: worker_host,
      profile: profile,
      max_cycles: SymphonyElixir.Config.settings!().duet.max_cycles_per_phase,
      code_phase_cap_policy: SymphonyElixir.Config.settings!().duet.code_phase_cap_policy
    }
  end

  defp run_spec_phase(ctx) do
    case spec_phase_actors(ctx.profile) do
      {:ok, author, reviewer} ->
        ctx
        |> Map.merge(%{author: author, reviewer: reviewer})
        |> run_cycle(1, [], %{author_last: nil, reviewer_last_authored: nil}, nil)

      {:error, reason} ->
        with :ok <- ensure_failure_event(ctx.issue, Atom.to_string(reason)) do
          {:error, reason}
        end
    end
  end

  defp run_cycle(ctx, cycle, unresolved_history, revision_history, reviewer_feedback) do
    with :ok <- ensure_phase_started(ctx.issue, cycle),
         {:ok, author_turn, author_response} <- ensure_turn(ctx, cycle, :author, ctx.author, reviewer_feedback),
         {:ok, reviewer_turn, reviewer_response} <- ensure_turn(ctx, cycle, :reviewer, ctx.reviewer, author_response) do
      decide_after_cycle(
        ctx,
        cycle,
        author_turn,
        reviewer_turn,
        reviewer_response,
        unresolved_history,
        revision_history
      )
    end
  end

  defp decide_after_cycle(ctx, cycle, author_turn, reviewer_turn, reviewer_response, unresolved_history, revision_history) do
    unresolved_history = unresolved_history ++ [reviewer_turn.unresolved]

    revision_history = %{
      author_last: author_turn.tree_hash || revision_history.author_last,
      reviewer_last_authored: reviewer_turn.tree_hash || revision_history.reviewer_last_authored
    }

    decision =
      ConvergenceOrchestrator.decide(
        phase: @phase,
        cycle: cycle,
        max_cycles: ctx.max_cycles,
        code_phase_cap_policy: ctx.code_phase_cap_policy,
        signals: convergence_signals(author_turn, reviewer_turn),
        unresolved_history: unresolved_history,
        revision_history: revision_history
      )

    feedback = reviewer_feedback(reviewer_turn, reviewer_response)

    apply_decision(ctx, cycle, decision, unresolved_history, revision_history, feedback)
  end

  defp apply_decision(ctx, cycle, {:freeze, mode, tree_hash}, _unresolved_history, _revision_history, _feedback) do
    append_phase_frozen(ctx.issue, cycle, freeze_mode(mode), tree_hash)
  end

  defp apply_decision(ctx, cycle, {:continue, _reason}, unresolved_history, revision_history, feedback) do
    run_cycle(ctx, cycle + 1, unresolved_history, revision_history, feedback)
  end

  defp apply_decision(ctx, _cycle, {:fail, :pathological_disagreement, unresolved}, _history, _revisions, _feedback) do
    with {:ok, _event} <-
           EventLog.append(ctx.issue, "pathological_disagreement", %{
             phase: @phase,
             unresolved: unresolved
           }),
         :ok <- ensure_failure_event(ctx.issue, "pathological_disagreement") do
      {:error, :pathological_disagreement}
    end
  end

  defp apply_decision(ctx, _cycle, {:fail, reason}, _history, _revisions, _feedback) do
    with :ok <- ensure_failure_event(ctx.issue, Atom.to_string(reason)) do
      {:error, reason}
    end
  end

  defp apply_decision(ctx, cycle, {:awaiting_operator, reason}, _history, _revisions, _feedback) do
    with {:ok, _event} <-
           EventLog.append(ctx.issue, "phase_cap_escalation", %{
             phase: @phase,
             cycle: cycle,
             reason: Atom.to_string(reason)
           }) do
      {:error, reason}
    end
  end

  defp ensure_turn(ctx, cycle, role, actor, context_text) do
    case existing_turn(ctx.issue, cycle, actor) do
      {:ok, %Turn{} = turn} ->
        {:ok, turn, transcript_response(ctx.issue, cycle, actor, turn.summary)}

      :missing ->
        run_turn(ctx, cycle, role, actor, context_text)
    end
  end

  defp run_turn(ctx, cycle, role, actor, context_text) do
    prompt = build_prompt(ctx, cycle, role, actor, context_text)
    tree_hash = tree_hash_for(ctx, cycle, actor)

    with {:ok, driver} <- driver_for_actor(ctx.opts, actor),
         :ok <- ensure_turn_request(ctx.issue, cycle, actor, tree_hash),
         {:ok, response_text} <- driver.drive_turn(prompt, driver_opts(ctx, actor)),
         {:ok, _path} <- Transcripts.write(ctx.issue, @phase, cycle, actor, prompt, response_text),
         {:ok, turn, _issues} <- Turn.record_response(ctx.issue, @phase, cycle, actor, response_text, tree_hash: tree_hash) do
      {:ok, turn, response_text}
    else
      {:error, reason} -> {:error, {:turn_failed, actor, cycle, reason}}
    end
  end

  defp build_prompt(ctx, cycle, :author, actor, reviewer_feedback) do
    prompt_context(ctx, cycle, :author, actor, ctx.reviewer)
    |> Map.put(:reviewer_feedback, reviewer_feedback)
    |> PhasePrompt.build()
  end

  defp build_prompt(ctx, cycle, :reviewer, actor, current_artifact) do
    prompt_context(ctx, cycle, :reviewer, actor, ctx.author)
    |> Map.put(:current_artifact, current_artifact)
    |> PhasePrompt.build()
  end

  defp prompt_context(ctx, cycle, role, actor, counterpart) do
    %PhasePrompt{
      task_id: task_id(ctx.issue),
      issue_title: Map.get(ctx.issue, :title) || "",
      issue_description: Map.get(ctx.issue, :description) || "",
      phase: @phase,
      cycle: cycle,
      max_cycles_per_phase: ctx.max_cycles,
      role: role,
      actor: actor,
      counterpart: counterpart,
      profile_name: ctx.profile.name,
      profile_mode: ctx.profile.mode
    }
  end

  defp convergence_signals(author_turn, reviewer_turn) do
    %Convergence{
      author_verdict: author_turn.verdict,
      author_tree_hash: author_turn.tree_hash,
      reviewer_verdict: reviewer_turn.verdict,
      reviewer_tree_hash: reviewer_turn.tree_hash
    }
  end

  defp reviewer_feedback(%Turn{} = turn, response_text) do
    unresolved =
      turn.unresolved
      |> Enum.map_join("\n", &("- " <> &1))

    """
    Previous reviewer verdict: #{turn.verdict}
    Summary: #{turn.summary}
    Unresolved:
    #{if unresolved == "", do: "- none", else: unresolved}

    Full reviewer response:
    #{String.trim_trailing(response_text)}
    """
    |> String.trim_trailing()
  end

  defp spec_phase_actors(profile) do
    phase = Map.get(profile.phases, @phase_key, %Routing.Phase{})
    author = phase.author
    reviewers = phase.reviewers

    cond do
      not supported_actor?(author) ->
        {:error, :unsupported_author}

      reviewers == [] ->
        {:error, :reviewer_not_configured}

      not supported_actor?(List.first(reviewers)) ->
        {:error, :unsupported_reviewer}

      true ->
        {:ok, author, List.first(reviewers)}
    end
  end

  defp supported_actor?(actor), do: actor in ["claude", "codex"]

  defp driver_for_actor(opts, actor) do
    cond do
      Keyword.has_key?(opts, :turn_driver) ->
        {:ok, Keyword.fetch!(opts, :turn_driver)}

      driver = actor_driver(opts, actor) ->
        {:ok, driver}

      actor == "codex" ->
        {:ok, CodexAppServer}

      actor == "claude" ->
        {:ok, ClaudeCode}

      true ->
        {:error, {:unsupported_actor, actor}}
    end
  end

  defp actor_driver(opts, actor) do
    drivers = Keyword.get(opts, :turn_drivers, %{})
    Map.get(drivers, actor) || Map.get(drivers, String.to_atom(actor))
  end

  defp driver_opts(ctx, "codex") do
    ctx.opts
    |> Keyword.get(:turn_driver_opts, [])
    |> Keyword.put_new(:workspace, ctx.workspace)
    |> Keyword.put_new(:issue, ctx.issue)
    |> Keyword.put_new(:worker_host, ctx.worker_host)
    |> Keyword.put_new(:on_message, codex_message_handler(ctx.update_recipient, ctx.issue))
  end

  defp driver_opts(ctx, "claude") do
    ctx.opts
    |> Keyword.get(:turn_driver_opts, [])
    |> Keyword.put_new(:workspace, ctx.workspace)
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
      ensure_phase_started(issue, 1)
    end
  end

  defp ensure_phase_started(issue, cycle) do
    append_once(issue, "phase_started", %{phase: @phase, cycle: cycle}, %{"phase" => @phase, "cycle" => cycle})
  end

  defp ensure_turn_request(issue, cycle, actor, tree_hash) do
    if event_recorded?(issue, "turn_request", %{"phase" => @phase, "cycle" => cycle, "actor" => actor}) do
      :ok
    else
      Turn.record_request(issue, @phase, cycle, actor, tree_hash: tree_hash)
    end
  end

  defp ensure_failure_event(issue, reason) do
    append_once(issue, "task_failed", %{reason: reason}, %{"reason" => reason})
  end

  defp append_phase_frozen(issue, cycle, mode, tree_hash) do
    append_once(
      issue,
      "phase_frozen",
      %{phase: @phase, cycle: cycle, mode: mode, tree_hash: tree_hash, next_phase: "PLAN"},
      %{"phase" => @phase}
    )
  end

  defp existing_turn(issue, cycle, actor) do
    case EventLog.read(issue) do
      {:ok, events} ->
        events
        |> Enum.find(&event_matches?(&1, "turn_response", %{"phase" => @phase, "cycle" => cycle, "actor" => actor}))
        |> turn_from_event()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp turn_from_event(nil), do: :missing

  defp turn_from_event(event) do
    {:ok,
     %Turn{
       phase: Map.get(event, "phase"),
       cycle: Map.get(event, "cycle"),
       actor: Map.get(event, "actor"),
       verdict: parse_verdict(Map.get(event, "verdict")),
       confidence: Map.get(event, "confidence"),
       summary: Map.get(event, "summary") || "",
       unresolved: Map.get(event, "unresolved") || [],
       tree_hash: Map.get(event, "tree_hash")
     }}
  end

  defp parse_verdict("APPROVE"), do: :approve
  defp parse_verdict("REQUEST_CHANGES"), do: :request_changes
  defp parse_verdict(_other), do: nil

  defp transcript_response(issue, cycle, actor, fallback) do
    case Transcripts.read(issue, @phase, cycle, actor) do
      {:ok, transcript} -> transcript |> String.split("## Response\n\n", parts: 2) |> List.last()
      {:error, _reason} -> fallback
    end
  end

  defp phase_frozen?(issue, phase) do
    event_recorded?(issue, "phase_frozen", %{"phase" => phase})
  end

  defp event_recorded?(issue, kind, match_attrs) do
    case EventLog.read(issue) do
      {:ok, events} -> Enum.any?(events, &event_matches?(&1, kind, match_attrs))
      {:error, _reason} -> false
    end
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

  defp tree_hash_for(ctx, cycle, actor) do
    cond do
      is_binary(Keyword.get(ctx.opts, :tree_hash)) ->
        Keyword.get(ctx.opts, :tree_hash)

      provider = Keyword.get(ctx.opts, :tree_hash_provider) ->
        call_tree_hash_provider(provider, ctx.workspace, @phase, cycle, actor)

      true ->
        git_tree_hash(ctx.workspace)
    end
  end

  defp call_tree_hash_provider(provider, workspace, phase, cycle, actor) when is_function(provider, 4) do
    provider.(workspace, phase, cycle, actor)
  end

  defp call_tree_hash_provider(provider, workspace, phase, cycle, _actor) when is_function(provider, 3) do
    provider.(workspace, phase, cycle)
  end

  defp call_tree_hash_provider(_provider, _workspace, _phase, _cycle, _actor), do: nil

  defp git_tree_hash(workspace) do
    case System.cmd("git", ["rev-parse", "HEAD^{tree}"], cd: workspace, stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      {_output, _status} -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp freeze_mode(:converged), do: "consensus"
  defp freeze_mode(mode), do: Atom.to_string(mode)

  defp task_attrs(issue) do
    %{
      identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title)
    }
  end

  defp task_id(issue) do
    Map.get(issue, :id) || Map.get(issue, :identifier)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
