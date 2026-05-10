defmodule SymphonyElixir.DuetRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.Routing

  test "duet config exposes default routing state" do
    settings = Config.settings!()

    assert settings.duet.enabled == false
    assert settings.duet.max_cycles_per_phase == 5
    assert settings.duet.phase_turn_timeout_ms == 600_000
    assert settings.duet.phase_total_timeout_ms == 7_200_000
    assert settings.duet.code_phase_cap_policy == "escalate"
    assert settings.duet.pause_on_freeze == false

    assert {:ok, profile} = Routing.resolve(settings.duet)
    assert profile.name == "duet_balanced"
    assert profile.mode == "full_duet"
    assert profile.degraded? == false
    assert profile.phases["spec"].author == "claude"
    assert profile.phases["spec"].reviewers == ["codex"]
    assert profile.phases["review"].coder_ack == "code_author"
    assert profile.phases["review"].reviewer == "non_coder"
  end

  test "duet routing can select an inherited degraded profile" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        max_cycles_per_phase: 3
        pause_on_freeze: true
        code_phase_cap_policy: fail
        agent_routing:
          default_profile: codex_only_dev
      """
    )

    settings = Config.settings!()

    assert settings.duet.enabled == true
    assert settings.duet.max_cycles_per_phase == 3
    assert settings.duet.pause_on_freeze == true
    assert settings.duet.code_phase_cap_policy == "fail"

    assert {:ok, profile} = Routing.resolve(settings.duet)
    assert profile.name == "codex_only_dev"
    assert profile.mode == "degraded_single_agent"
    assert profile.degraded? == true
    assert profile.phases["plan"].author == "codex"
    assert profile.phases["plan"].reviewers == []
    assert profile.phases["review"].reviewer == "human"
  end

  test "duet routing accepts a valid custom full duet profile" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: claude_plan
          profiles:
            claude_plan:
              mode: full_duet
              phases:
                spec:   { author: claude, reviewers: [codex] }
                plan:   { author: claude, reviewers: [codex] }
                code:   { author: codex, reviewers: [claude] }
                review: { coder_ack: code_author, reviewer: non_coder }
      """
    )

    assert :ok = Config.validate!()
    assert {:ok, profile} = Routing.resolve(Config.settings!().duet)
    assert profile.name == "claude_plan"
    assert profile.mode == "full_duet"
    assert profile.phases["plan"].author == "claude"
    assert profile.phases["plan"].reviewers == ["codex"]
  end

  test "duet routing rejects full duet profiles without a machine reviewer" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: bad_full
          profiles:
            bad_full:
              mode: full_duet
              phases:
                spec:   { author: codex, reviewers: [] }
                plan:   { author: codex, reviewers: [claude] }
                code:   { author: codex, reviewers: [claude] }
                review: { coder_ack: code_author, reviewer: non_coder }
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "full_duet_missing_machine_reviewer"
    assert message =~ "bad_full"
    assert message =~ "spec"
  end

  test "duet routing rejects full duet profiles with a non-machine author" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: human_full
          profiles:
            human_full:
              mode: full_duet
              phases:
                spec:   { author: human, reviewers: [codex] }
                plan:   { author: codex, reviewers: [claude] }
                code:   { author: codex, reviewers: [claude] }
                review: { coder_ack: code_author, reviewer: non_coder }
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "full_duet_author_not_machine"
    assert message =~ "human_full"
    assert message =~ "spec"
  end

  test "duet routing rejects full duet profiles that include the author as reviewer" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: self_review
          profiles:
            self_review:
              mode: full_duet
              phases:
                spec:   { author: codex, reviewers: [codex, claude] }
                plan:   { author: codex, reviewers: [claude] }
                code:   { author: codex, reviewers: [claude] }
                review: { coder_ack: code_author, reviewer: non_coder }
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "full_duet_self_review"
    assert message =~ "self_review"
    assert message =~ "spec"
  end

  test "duet routing rejects unknown default profiles" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        agent_routing:
          default_profile: missing_profile
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "unknown_default_profile"
    assert message =~ "missing_profile"
  end

  test "duet config rejects invalid phase controls" do
    write_workflow_file!(Workflow.workflow_file_path(),
      duet_yaml: """
      duet:
        enabled: true
        max_cycles_per_phase: 0
        phase_turn_timeout_ms: -1
        code_phase_cap_policy: auto_merge
      """
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "max_cycles_per_phase"
    assert message =~ "phase_turn_timeout_ms"
    assert message =~ "code_phase_cap_policy"
  end
end
