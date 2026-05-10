defmodule SymphonyElixir.Duet.PairRunner do
  @moduledoc """
  Claude + Codex pair runner for Duet mode.

  This runner wires the sequential Duet phase pipeline across SPEC, PLAN,
  CODE, and REVIEW. Each dispatch advances at most one phase to a frozen
  state; Symphony's existing active-state continuation retry then dispatches
  the task again and the runner resumes from the append-only event log.

  ## Side effects

  When `side_effects: true` is passed in opts, the runner orchestrates
  real Git branch operations (via `BranchHarness`) and GitHub PR
  operations (via `PRLifecycle`) at phase boundaries. Without this opt,
  only event-log state is recorded.

  Injectable runners: `:branch_runner` (for `BranchHarness`),
  `:gh_runner` (for `PRLifecycle` / `GhCli`).
  """

  alias SymphonyElixir.Duet.{
    AwaitingOperator,
    BranchHarness,
    Convergence,
    ConvergenceOrchestrator,
    EventLog,
    HumanCheckpoint,
    Identity,
    PhasePrompt,
    PhaseTransition,
    PRConflict,
    PRLifecycle,
    Routing,
    RoutingSelection,
    SuperPower,
    ToolProfile,
    Transcripts,
    Turn,
    TurnDrivers.ClaudeCode,
    TurnDrivers.CodexAppServer,
    VerificationGate
  }

  alias SymphonyElixir.RunnerRuntime

  require Logger

  @phases ~w(SPEC PLAN CODE REVIEW)
  @phase_keys %{"SPEC" => "spec", "PLAN" => "plan", "CODE" => "code", "REVIEW" => "review"}
  @awaiting_reasons AwaitingOperator.reasons()

  @spec run(map(), pid() | nil, keyword()) :: :ok | {:error, term()}
  def run(issue, update_recipient \\ nil, opts \\ []) do
    RunnerRuntime.run("duet pair", issue, update_recipient, opts, &run_pair_loop/5)
  end

  defp run_pair_loop(workspace, issue, update_recipient, opts, worker_host) do
    settings = SymphonyElixir.Config.settings!()

    with {:ok, profile} <- RoutingSelection.resolve(settings.duet),
         :ok <- ensure_initial_state_events(issue, profile) do
      warn_if_identity_invalid()
      ctx = context(settings, workspace, issue, update_recipient, opts, worker_host, profile)

      with :ok <- maybe_ensure_base_branch(ctx) do
        run_next_phase(ctx)
      end
    else
      {:error, reason} -> {:error, {:state_event_failed, reason}}
    end
  end

  defp warn_if_identity_invalid do
    case Identity.validate_distinct_machine_identities() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Duet identity validation: #{inspect(reason)}")
    end
  end

  defp context(settings, workspace, issue, update_recipient, opts, worker_host, profile) do
    %{
      settings: settings,
      workspace: workspace,
      issue: issue,
      update_recipient: update_recipient,
      opts: opts,
      worker_host: worker_host,
      profile: profile,
      max_cycles: settings.duet.max_cycles_per_phase,
      code_phase_cap_policy: String.to_atom(settings.duet.code_phase_cap_policy),
      side_effects: Keyword.get(opts, :side_effects, false)
    }
  end

  defp run_next_phase(ctx) do
    case EventLog.read(ctx.issue) do
      {:ok, events} ->
        ctx = Map.put(ctx, :events, events)

        case current_phase_from_events(events) do
          {:ok, :completed} ->
            :ok

          {:ok, phase} ->
            ctx
            |> Map.put(:phase, phase)
            |> Map.put(:phase_key, Map.fetch!(@phase_keys, phase))
            |> run_phase()

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_phase(ctx) do
    case phase_actors(ctx.profile, ctx.phase) do
      {:ok, author, reviewer, author_role, reviewer_role} ->
        ctx =
          Map.merge(ctx, %{
            author: author,
            reviewer: reviewer,
            author_role: author_role,
            reviewer_role: reviewer_role
          })

        with :ok <- maybe_ensure_phase_branch(ctx),
             {:ok, ctx} <- maybe_open_phase_pr(ctx),
             {:ok, ctx} <- maybe_setup_phase_workspace(ctx) do
          run_cycle(ctx, 1, [], %{author_last: nil, reviewer_last_authored: nil}, nil)
        end

      {:error, reason} ->
        with :ok <- ensure_failure_event(ctx.issue, Atom.to_string(reason)) do
          {:error, reason}
        end
    end
  end

  defp run_cycle(ctx, cycle, unresolved_history, revision_history, reviewer_feedback) do
    with :ok <- ensure_phase_started(ctx.issue, ctx.phase, cycle),
         {:ok, author_turn, author_response} <- ensure_turn(ctx, cycle, ctx.author_role, ctx.author, reviewer_feedback),
         {:ok, reviewer_turn, reviewer_response} <- ensure_reviewer_turn(ctx, cycle, author_response) do
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

  defp ensure_reviewer_turn(ctx, cycle, author_response) do
    result = existing_turn_from_events(ctx[:events], ctx.issue, ctx.phase, cycle, ctx.reviewer)

    case result do
      {:ok, %Turn{} = turn} ->
        {:ok, turn, transcript_response(ctx.issue, ctx.phase, cycle, ctx.reviewer, turn.summary)}

      :missing ->
        with {:ok, reviewer_context} <- maybe_run_verification_gate(ctx, cycle, author_response) do
          run_turn(ctx, cycle, ctx.reviewer_role, ctx.reviewer, reviewer_context)
        end
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
        phase: ctx.phase,
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
    with :ok <- maybe_request_human_checkpoint(ctx, cycle, tree_hash),
         :ok <- maybe_check_review_code_pr_mergeability(ctx, cycle),
         :ok <- append_phase_frozen(ctx, cycle, freeze_mode(mode), tree_hash),
         :ok <- maybe_execute_freeze_side_effects(ctx),
         :ok <- maybe_write_superpower_artifact(ctx, cycle),
         :ok <- maybe_append_task_completed(ctx, cycle) do
      maybe_pause_on_freeze(ctx, cycle)
    end
  end

  defp apply_decision(ctx, cycle, {:continue, _reason}, unresolved_history, revision_history, feedback) do
    run_cycle(ctx, cycle + 1, unresolved_history, revision_history, feedback)
  end

  defp apply_decision(ctx, _cycle, {:fail, :pathological_disagreement, unresolved}, _history, _revisions, _feedback) do
    with {:ok, _event} <-
           EventLog.append(ctx.issue, "pathological_disagreement", %{
             phase: ctx.phase,
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
           append_once_event(ctx.issue, "phase_cap_escalation", %{
             phase: ctx.phase,
             cycle: cycle,
             reason: awaiting_reason(reason)
           }) do
      {:error, reason}
    end
  end

  defp ensure_turn(ctx, cycle, role, actor, context_text) do
    case existing_turn(ctx.issue, ctx.phase, cycle, actor) do
      {:ok, %Turn{} = turn} ->
        {:ok, turn, transcript_response(ctx.issue, ctx.phase, cycle, actor, turn.summary)}

      :missing ->
        run_turn(ctx, cycle, role, actor, context_text)
    end
  end

  defp run_turn(ctx, cycle, role, actor, context_text) do
    prompt = build_prompt(ctx, cycle, role, actor, context_text)
    tree_hash = tree_hash_for(ctx, cycle, actor)

    with {:ok, driver} <- driver_for_actor(ctx.opts, actor),
         :ok <- ensure_turn_request(ctx.issue, ctx.phase, cycle, actor, tree_hash),
         {:ok, response_text} <- driver.drive_turn(prompt, driver_opts(ctx, actor)),
         {:ok, _path} <- Transcripts.write(ctx.issue, ctx.phase, cycle, actor, prompt, response_text),
         {:ok, turn, _issues} <-
           Turn.record_response(ctx.issue, ctx.phase, cycle, actor, response_text, tree_hash: tree_hash),
         :ok <- maybe_post_turn_to_pr(ctx, role, turn, response_text) do
      {:ok, turn, response_text}
    else
      {:error, reason} -> {:error, {:turn_failed, ctx.phase, actor, cycle, reason}}
    end
  end

  defp build_prompt(ctx, cycle, role, actor, context_text) when role in [:author, :coder_ack] do
    prompt_context(ctx, cycle, role, actor, ctx.reviewer)
    |> Map.put(:prior_phase_summaries, prior_phase_summaries(ctx))
    |> Map.put(:reviewer_feedback, context_text)
    |> PhasePrompt.build()
    |> append_tool_constraints(ctx, role, actor)
  end

  defp build_prompt(ctx, cycle, role, actor, context_text) do
    prompt_context(ctx, cycle, role, actor, ctx.author)
    |> Map.put(:prior_phase_summaries, prior_phase_summaries(ctx))
    |> Map.put(:current_artifact, context_text)
    |> PhasePrompt.build()
    |> append_tool_constraints(ctx, role, actor)
  end

  defp append_tool_constraints(prompt, ctx, role, actor) do
    case tool_constraints(ctx, role, actor) do
      {:ok, :all} ->
        prompt

      {:ok, tools} when is_list(tools) ->
        prompt <>
          "\n\n## Tool constraints\nAllowed tools for this turn: " <>
          Enum.join(tools, ", ") <> ". Do not request or use tools outside this list."

      {:error, reason} ->
        prompt <>
          "\n\n## Tool constraints\nTool-profile resolution failed: " <>
          inspect(reason) <> ". Proceed without external tool use unless the operator resolves the configuration."
    end
  end

  defp tool_constraints(ctx, role, actor) do
    config = ctx.settings.duet.tool_profiles

    if is_map(config) do
      profile_name = ToolProfile.default_profile_name(config)
      ToolProfile.resolve(config, profile_name, ctx.phase_key, tool_role(role), actor)
    else
      {:ok, :all}
    end
  end

  defp tool_role(:coder_ack), do: "coder_ack"
  defp tool_role(:review_reviewer), do: "reviewer"
  defp tool_role(:author), do: "author"
  defp tool_role(:reviewer), do: "reviewer"

  defp prompt_context(ctx, cycle, role, actor, counterpart) do
    %PhasePrompt{
      task_id: task_id(ctx.issue),
      issue_title: Map.get(ctx.issue, :title) || "",
      issue_description: Map.get(ctx.issue, :description) || "",
      phase: ctx.phase,
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

  defp phase_actors(profile, phase) when phase in ["SPEC", "PLAN", "CODE"] do
    routing = Map.get(profile.phases, Map.fetch!(@phase_keys, phase), %Routing.Phase{})
    author = routing.author
    reviewer = List.first(routing.reviewers)

    cond do
      not supported_actor?(author) -> {:error, :unsupported_author}
      is_nil(reviewer) -> {:error, :reviewer_not_configured}
      not supported_actor?(reviewer) -> {:error, :unsupported_reviewer}
      author == reviewer -> {:error, :self_review_not_supported}
      true -> {:ok, author, reviewer, :author, :reviewer}
    end
  end

  defp phase_actors(profile, "REVIEW") do
    review = Map.get(profile.phases, "review", %Routing.Phase{})

    with {:ok, coder_ack} <- resolve_review_actor(profile, review.coder_ack),
         {:ok, reviewer} <- resolve_review_actor(profile, review.reviewer) do
      if coder_ack == reviewer do
        {:error, :self_review_not_supported}
      else
        {:ok, coder_ack, reviewer, :coder_ack, :review_reviewer}
      end
    end
  end

  defp resolve_review_actor(profile, "code_author") do
    code = Map.get(profile.phases, "code", %Routing.Phase{})

    if supported_actor?(code.author), do: {:ok, code.author}, else: {:error, :unsupported_author}
  end

  defp resolve_review_actor(profile, "non_coder") do
    code = Map.get(profile.phases, "code", %Routing.Phase{})
    reviewer = Enum.find(code.reviewers, &supported_actor?/1)

    if is_binary(reviewer), do: {:ok, reviewer}, else: {:error, :reviewer_not_configured}
  end

  defp resolve_review_actor(_profile, actor) do
    if supported_actor?(actor), do: {:ok, actor}, else: {:error, :unsupported_reviewer}
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
    |> Keyword.put_new(:workspace, effective_workspace(ctx))
    |> Keyword.put_new(:issue, ctx.issue)
    |> Keyword.put_new(:worker_host, ctx.worker_host)
    |> Keyword.put_new(:on_message, codex_message_handler(ctx.update_recipient, ctx.issue))
  end

  defp driver_opts(ctx, "claude") do
    ctx.opts
    |> Keyword.get(:turn_driver_opts, [])
    |> Keyword.put_new(:workspace, effective_workspace(ctx))
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
    case append_once(issue, "task_started", task_attrs(issue)) do
      :ok -> ensure_routing_selected(issue, Routing.to_event_attrs(profile))
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_phase_started(issue, phase, cycle) do
    append_once(issue, "phase_started", %{phase: phase, cycle: cycle}, %{
      "phase" => phase,
      "cycle" => cycle
    })
  end

  defp ensure_turn_request(issue, phase, cycle, actor, tree_hash) do
    if event_recorded?(issue, "turn_request", %{"phase" => phase, "cycle" => cycle, "actor" => actor}) do
      :ok
    else
      Turn.record_request(issue, phase, cycle, actor, tree_hash: tree_hash)
    end
  end

  defp ensure_failure_event(issue, reason) do
    append_once(issue, "task_failed", %{reason: reason}, %{"reason" => reason})
  end

  defp append_phase_frozen(ctx, cycle, mode, tree_hash) do
    append_once(
      ctx.issue,
      "phase_frozen",
      phase_frozen_attrs(ctx, cycle, mode, tree_hash),
      %{"phase" => ctx.phase}
    )
  end

  defp phase_frozen_attrs(ctx, cycle, mode, tree_hash) do
    attrs =
      %{
        phase: ctx.phase,
        cycle: cycle,
        mode: mode,
        tree_hash: tree_hash,
        next_phase: PhaseTransition.next_phase(ctx.phase),
        freeze_actions: Enum.map(PhaseTransition.freeze_actions(ctx.phase), &Atom.to_string/1)
      }

    if pause_on_freeze?(ctx) do
      Map.put(attrs, :awaiting_operator_reason, "pause_on_freeze")
    else
      attrs
    end
  end

  defp maybe_append_task_completed(ctx, cycle) do
    if ctx.phase == "REVIEW" do
      append_once(ctx.issue, "task_completed", %{phase: "REVIEW", cycle: cycle}, %{})
    else
      :ok
    end
  end

  defp maybe_request_human_checkpoint(ctx, cycle, tree_hash) do
    if HumanCheckpoint.blocking?(ctx.settings.duet, ctx.phase) do
      append_once(ctx.issue, "human_checkpoint_requested", human_checkpoint_attrs(ctx, cycle, tree_hash), %{
        "phase" => ctx.phase
      })
      |> case do
        :ok -> {:error, :human_checkpoint}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_check_review_code_pr_mergeability(%{phase: "REVIEW"} = ctx, cycle) do
    case code_pr_mergeability(ctx) do
      :not_configured ->
        :ok

      :mergeable ->
        :ok

      {:conflict, %{paths: paths, base_head: base_head, pr_permalink: pr_permalink}} ->
        attrs =
          pr_permalink
          |> PRConflict.event_attrs(paths, base_head)
          |> Map.merge(%{phase: "REVIEW", cycle: cycle, reason: "code_pr_conflict"})

        with {:ok, _event} <-
               append_once_event(ctx.issue, "code_pr_conflict", attrs) do
          {:error, :code_pr_conflict}
        end

      {:retry_later, state} ->
        {:error, {:code_pr_mergeability_pending, state}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_check_review_code_pr_mergeability(_ctx, _cycle), do: :ok

  defp code_pr_mergeability(ctx) do
    case Keyword.get(ctx.opts, :code_pr_mergeability_provider) do
      provider when is_function(provider, 1) ->
        normalize_code_pr_mergeability(provider.(ctx))

      provider when is_function(provider, 2) ->
        normalize_code_pr_mergeability(provider.(ctx.phase, ctx))

      _other ->
        :not_configured
    end
  end

  defp normalize_code_pr_mergeability({:ok, result}), do: normalize_code_pr_mergeability(result)
  defp normalize_code_pr_mergeability(:mergeable), do: :mergeable
  defp normalize_code_pr_mergeability({:retry_later, state}), do: {:retry_later, state}

  defp normalize_code_pr_mergeability({:conflict, attrs}) when is_map(attrs) do
    {:conflict,
     %{
       paths:
         Map.get(attrs, :paths) || Map.get(attrs, "paths") || Map.get(attrs, :conflicting_paths) ||
           Map.get(attrs, "conflicting_paths") || [],
       base_head: Map.get(attrs, :base_head) || Map.get(attrs, "base_head"),
       pr_permalink: Map.get(attrs, :pr_permalink) || Map.get(attrs, "pr_permalink")
     }}
  end

  defp normalize_code_pr_mergeability(input) when is_map(input) do
    case PRConflict.evaluate(input) do
      :mergeable ->
        :mergeable

      {:retry_later, state} ->
        {:retry_later, state}

      {:conflict, %{paths: paths, base_head: base_head}} ->
        {:conflict,
         %{
           paths: paths,
           base_head: base_head,
           pr_permalink: Map.get(input, :pr_permalink) || Map.get(input, "pr_permalink")
         }}
    end
  end

  defp normalize_code_pr_mergeability({:error, reason}), do: {:error, reason}
  defp normalize_code_pr_mergeability(other), do: {:error, {:invalid_code_pr_mergeability, other}}

  defp maybe_run_verification_gate(ctx, cycle, author_response) do
    verification_gate = ctx.settings.duet.verification_gate

    if verification_gate_enabled_for_phase?(verification_gate, ctx.phase) do
      run_verification_gate(ctx, cycle, author_response, verification_gate)
    else
      {:ok, author_response}
    end
  end

  defp run_verification_gate(ctx, cycle, author_response, verification_gate) do
    checks = verification_checks(ctx, cycle)
    status = checks |> Enum.map(&Map.get(&1, :status)) |> VerificationGate.aggregate_status()
    block = VerificationGate.build_block(checks, status)

    with {:ok, _event} <- append_verification_completed(ctx.issue, ctx.phase, cycle, status, checks) do
      verification_gate_result(status, verification_gate, author_response, block)
    end
  end

  defp verification_gate_result(:timeout, verification_gate, author_response, block) do
    if verification_on_timeout(verification_gate) == "block" do
      {:error, :verification_timeout}
    else
      {:ok, author_response <> "\n\n" <> block}
    end
  end

  defp verification_gate_result(_status, _verification_gate, author_response, block) do
    {:ok, author_response <> "\n\n" <> block}
  end

  defp verification_gate_enabled_for_phase?(verification_gate, phase) when is_map(verification_gate) do
    phase_key = String.downcase(phase)

    Map.get(verification_gate, "enabled", false) == true and
      phase_key in Map.get(verification_gate, "phases", [])
  end

  defp verification_gate_enabled_for_phase?(_verification_gate, _phase), do: false

  defp verification_checks(ctx, cycle) do
    case Keyword.get(ctx.opts, :verification_checks_provider) do
      provider when is_function(provider, 3) ->
        provider.(ctx.phase, cycle, ctx)

      provider when is_function(provider, 2) ->
        provider.(ctx.phase, cycle)

      _other ->
        Keyword.get(ctx.opts, :verification_checks, [
          %{name: "duet/verification_not_configured", status: :partial, summary: "No verification runner configured"}
        ])
    end
    |> normalize_verification_checks()
  end

  defp normalize_verification_checks({:ok, checks}), do: normalize_verification_checks(checks)
  defp normalize_verification_checks(:timeout), do: [%{name: "verification_timeout", status: :timeout}]

  defp normalize_verification_checks(checks) when is_list(checks) do
    Enum.map(checks, fn check ->
      %{
        name: Map.get(check, :name) || Map.get(check, "name") || "verification",
        status: normalize_verification_status(Map.get(check, :status) || Map.get(check, "status")),
        summary: Map.get(check, :summary) || Map.get(check, "summary")
      }
    end)
  end

  defp normalize_verification_checks(_other), do: [%{name: "verification", status: :partial}]

  defp normalize_verification_status(status) when status in [:pass, :fail, :partial, :timeout], do: status
  defp normalize_verification_status("pass"), do: :pass
  defp normalize_verification_status("fail"), do: :fail
  defp normalize_verification_status("partial"), do: :partial
  defp normalize_verification_status("timeout"), do: :timeout
  defp normalize_verification_status(_other), do: :partial

  defp append_verification_completed(issue, phase, cycle, status, checks) do
    attrs = %{
      phase: phase,
      cycle: cycle,
      status: Atom.to_string(status),
      checks: stringify_keys(checks)
    }

    attrs =
      if status == :timeout do
        Map.put(attrs, :reason, "verification_timeout")
      else
        attrs
      end

    append_once_event(issue, "verification_completed", attrs)
  end

  defp verification_on_timeout(verification_gate) do
    Map.get(verification_gate, "on_timeout", "warn")
  end

  defp human_checkpoint_attrs(ctx, cycle, tree_hash) do
    %{
      phase: ctx.phase,
      cycle: cycle,
      tree_hash: tree_hash,
      reason: "human_checkpoint"
    }
  end

  # -- Side effects (branch + PR operations, gated by `side_effects: true`) --

  defp maybe_ensure_base_branch(%{side_effects: true} = ctx) do
    BranchHarness.ensure_base_branch(task_id(ctx.issue), branch_harness_opts(ctx))
  end

  defp maybe_ensure_base_branch(_ctx), do: :ok

  defp maybe_ensure_phase_branch(%{side_effects: true} = ctx) do
    BranchHarness.ensure_phase_branch(task_id(ctx.issue), ctx.phase, branch_harness_opts(ctx))
  end

  defp maybe_ensure_phase_branch(_ctx), do: :ok

  defp maybe_open_phase_pr(%{side_effects: true} = ctx) do
    case resolve_phase_pr_number(ctx) do
      n when is_integer(n) ->
        {:ok, Map.put(ctx, :pr_number, n)}

      nil ->
        pr_ctx =
          %{
            task_id: task_id(ctx.issue),
            phase: ctx.phase,
            issue_title: Map.get(ctx.issue, :title) || "",
            issue_description: Map.get(ctx.issue, :description) || "",
            workspace: ctx.workspace,
            cycle: 1
          }
          |> maybe_put_gh_runner(ctx)

        case PRLifecycle.open_phase_pr(pr_ctx) do
          {:ok, number} -> {:ok, Map.put(ctx, :pr_number, number)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_open_phase_pr(ctx), do: {:ok, ctx}

  defp maybe_setup_phase_workspace(%{side_effects: true, phase: "REVIEW"} = ctx) do
    case BranchHarness.phase_workspace(task_id(ctx.issue), "CODE", branch_harness_opts(ctx)) do
      {:ok, path} -> {:ok, Map.put(ctx, :phase_workspace, path)}
      {:error, _} -> {:ok, ctx}
    end
  end

  defp maybe_setup_phase_workspace(%{side_effects: true} = ctx) do
    case BranchHarness.phase_workspace(task_id(ctx.issue), ctx.phase, branch_harness_opts(ctx)) do
      {:ok, path} -> {:ok, Map.put(ctx, :phase_workspace, path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_setup_phase_workspace(ctx), do: {:ok, ctx}

  defp maybe_post_turn_to_pr(ctx, role, turn, response_text) do
    if ctx.side_effects and is_integer(ctx[:pr_number]) do
      post_turn_to_pr(ctx, role, turn, response_text)
    else
      :ok
    end
  end

  defp post_turn_to_pr(ctx, role, _turn, response_text) when role in [:author, :coder_ack] do
    PRLifecycle.post_author_trailer(ctx.pr_number, response_text, pr_lifecycle_opts(ctx))
  end

  defp post_turn_to_pr(ctx, role, turn, response_text) when role in [:reviewer, :review_reviewer] do
    verdict = if turn.verdict == :approve, do: :approve, else: :request_changes
    PRLifecycle.submit_reviewer_verdict(ctx.pr_number, verdict, response_text, pr_lifecycle_opts(ctx))
  end

  defp post_turn_to_pr(_ctx, _role, _turn, _response_text), do: :ok

  defp effective_workspace(ctx), do: Map.get(ctx, :phase_workspace) || ctx.workspace

  defp pr_lifecycle_opts(ctx) do
    opts = [cwd: effective_workspace(ctx)]

    case Keyword.get(ctx.opts, :gh_runner) do
      runner when is_atom(runner) and not is_nil(runner) -> Keyword.put(opts, :runner, runner)
      _ -> opts
    end
  end

  defp maybe_put_gh_runner(pr_ctx, ctx) do
    case Keyword.get(ctx.opts, :gh_runner) do
      runner when is_atom(runner) and not is_nil(runner) -> Map.put(pr_ctx, :runner, runner)
      _ -> pr_ctx
    end
  end

  defp maybe_execute_freeze_side_effects(%{side_effects: true} = ctx) do
    task_id = task_id(ctx.issue)
    pr_number = resolve_phase_pr_number(ctx)

    PRLifecycle.execute_freeze_actions(ctx.phase, pr_number, freeze_action_opts(ctx, task_id))
  end

  defp maybe_execute_freeze_side_effects(_ctx), do: :ok

  defp resolve_phase_pr_number(%{pr_number: n}) when is_integer(n), do: n

  defp resolve_phase_pr_number(%{phase: "REVIEW"} = ctx) do
    case PRLifecycle.resolve_code_pr_number(%{task_id: task_id(ctx.issue)}) do
      {:ok, number} -> number
      {:error, _} -> nil
    end
  end

  defp resolve_phase_pr_number(ctx) do
    case EventLog.read(ctx.issue) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1["kind"] == "pr_opened" && &1["phase"] == ctx.phase))
        |> List.last()
        |> case do
          %{"pr_number" => n} when is_integer(n) -> n
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp branch_harness_opts(ctx) do
    opts = [cwd: ctx.workspace]

    case Keyword.get(ctx.opts, :branch_runner) do
      runner when is_atom(runner) and not is_nil(runner) -> Keyword.put(opts, :runner, runner)
      _ -> opts
    end
  end

  defp freeze_action_opts(ctx, task_id) do
    opts = [task_id: task_id, cwd: ctx.workspace]

    opts =
      case Keyword.get(ctx.opts, :gh_runner) do
        runner when is_atom(runner) and not is_nil(runner) -> Keyword.put(opts, :runner, runner)
        _ -> opts
      end

    case Keyword.get(ctx.opts, :branch_runner) do
      runner when is_atom(runner) and not is_nil(runner) -> Keyword.put(opts, :branch_runner, runner)
      _ -> opts
    end
  end

  defp maybe_pause_on_freeze(ctx) do
    if pause_on_freeze?(ctx) do
      {:error, :pause_on_freeze}
    else
      :ok
    end
  end

  defp maybe_pause_on_freeze(ctx, _cycle), do: maybe_pause_on_freeze(ctx)

  defp pause_on_freeze?(%{phase: "REVIEW"}), do: false
  defp pause_on_freeze?(ctx), do: ctx.settings.duet.pause_on_freeze

  defp maybe_write_superpower_artifact(ctx, cycle) do
    superpower = ctx.settings.duet.superpower

    if SuperPower.phase_enabled?(superpower, ctx.phase) do
      with {:ok, path} <- SuperPower.artifact_path(superpower, ctx.phase, task_id(ctx.issue)),
           :ok <- write_superpower_file(ctx.workspace, path, superpower_artifact_text(ctx, cycle)),
           {:ok, _event} <-
             append_once_event(ctx.issue, "superpower_artifact_written", %{
               phase: ctx.phase,
               path: path,
               mode: SuperPower.mode(superpower) |> Atom.to_string()
             }) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp write_superpower_file(workspace, path, contents) do
    destination = if Path.type(path) == :relative, do: Path.join(workspace, path), else: path

    with :ok <- File.mkdir_p(Path.dirname(destination)) do
      File.write(destination, contents)
    end
  end

  defp superpower_artifact_text(ctx, cycle) do
    """
    # #{ctx.phase} artifact

    Task: #{task_id(ctx.issue)}
    Title: #{Map.get(ctx.issue, :title) || ""}
    Cycle: #{cycle}

    This artifact mirrors the frozen Duet #{ctx.phase} state. The append-only
    event log remains the machine source of truth.
    """
  end

  defp existing_turn(issue, phase, cycle, actor) do
    case EventLog.read(issue) do
      {:ok, events} ->
        find_turn_in_events(events, phase, cycle, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_turn_from_events(nil, issue, phase, cycle, actor) do
    existing_turn(issue, phase, cycle, actor)
  end

  defp existing_turn_from_events(events, _issue, phase, cycle, actor) do
    find_turn_in_events(events, phase, cycle, actor)
  end

  defp find_turn_in_events(events, phase, cycle, actor) do
    events
    |> Enum.find(&event_matches?(&1, "turn_response", %{"phase" => phase, "cycle" => cycle, "actor" => actor}))
    |> turn_from_event()
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

  defp transcript_response(issue, phase, cycle, actor, fallback) do
    case Transcripts.read(issue, phase, cycle, actor) do
      {:ok, transcript} -> transcript |> String.split("## Response\n\n", parts: 2) |> List.last()
      {:error, _reason} -> fallback
    end
  end

  defp current_phase_from_events(events) do
    frozen = frozen_phases(events)

    cond do
      reason = pending_awaiting_operator_reason(events) -> {:error, awaiting_error(reason)}
      Enum.any?(events, &(Map.get(&1, "kind") == "task_completed")) -> {:ok, :completed}
      true -> {:ok, Enum.find(@phases, &(!MapSet.member?(frozen, &1))) || :completed}
    end
  end

  defp pending_awaiting_operator_reason(events) do
    events
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn event, _acc ->
      cond do
        Map.get(event, "kind") in ["task_completed", "task_failed", "human_checkpoint_resolved", "operator_resolution"] ->
          {:halt, nil}

        reason = awaiting_reason_from_event(event) ->
          {:halt, reason}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp awaiting_reason_from_event(%{"kind" => "human_checkpoint_requested"}), do: "human_checkpoint"
  defp awaiting_reason_from_event(%{"kind" => "phase_cap_escalation"}), do: "phase_cap_escalation"
  defp awaiting_reason_from_event(%{"kind" => "code_pr_conflict"}), do: "code_pr_conflict"
  defp awaiting_reason_from_event(%{"kind" => "superpower_artifact_rejected"}), do: "superpower_artifact_invalid"
  defp awaiting_reason_from_event(%{"kind" => "phase_frozen", "awaiting_operator_reason" => reason}), do: reason

  defp awaiting_reason_from_event(%{
         "kind" => "verification_completed",
         "status" => "timeout",
         "reason" => "verification_timeout"
       }),
       do: "verification_timeout"

  defp awaiting_reason_from_event(_event), do: nil

  defp frozen_phases(events) do
    events
    |> Enum.filter(&(Map.get(&1, "kind") == "phase_frozen"))
    |> Enum.map(&Map.get(&1, "phase"))
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp prior_phase_summaries(%{events: events}) when is_list(events) do
    prior_phase_summaries_from_events(events)
  end

  defp prior_phase_summaries(%{issue: issue}) do
    prior_phase_summaries(issue)
  end

  defp prior_phase_summaries(issue) do
    case EventLog.read(issue) do
      {:ok, events} -> prior_phase_summaries_from_events(events)
      {:error, _reason} -> %{}
    end
  end

  defp prior_phase_summaries_from_events(events) do
    events
    |> Enum.filter(&(Map.get(&1, "kind") == "phase_frozen"))
    |> Map.new(fn event ->
      phase = Map.get(event, "phase")
      summary = Map.get(event, "summary") || "#{phase} frozen with mode #{Map.get(event, "mode", "unknown")}"
      {phase, summary}
    end)
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

  defp append_once_event(issue, kind, attrs) do
    case append_once(issue, kind, attrs, Map.take(stringify_keys(attrs), ["phase", "cycle", "reason"])) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
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
        call_tree_hash_provider(provider, ctx.workspace, ctx.phase, cycle, actor)

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

  defp awaiting_reason(reason) when reason in @awaiting_reasons, do: Atom.to_string(reason)
  defp awaiting_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp awaiting_reason(reason) when is_binary(reason), do: reason

  defp awaiting_error(reason) do
    case reason do
      "pause_on_freeze" -> :pause_on_freeze
      "code_pr_conflict" -> :code_pr_conflict
      "human_checkpoint" -> :human_checkpoint
      "verification_timeout" -> :verification_timeout
      "superpower_artifact_invalid" -> :superpower_artifact_invalid
      "phase_cap_escalation" -> :phase_cap_escalation
      "state_divergence" -> :state_divergence
      other -> {:awaiting_operator, other}
    end
  end
end
