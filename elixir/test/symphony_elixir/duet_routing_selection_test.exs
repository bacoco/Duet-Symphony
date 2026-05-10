defmodule SymphonyElixir.DuetRoutingSelectionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.RoutingSelection

  test "payload exposes available profiles and default effective routing" do
    assert {:ok, payload} = RoutingSelection.payload(Config.settings!().duet)

    assert payload.enabled == false
    assert payload.menu_enabled == true
    assert payload.require_selection_before_dispatch == false
    assert payload.default_profile == "duet_balanced"
    assert payload.selected_profile == "duet_balanced"
    assert payload.selection_source == "default"
    assert payload.effective_profile.mode == "full_duet"
    assert Enum.map(payload.profiles, & &1.name) == ["claude_only_dev", "codex_only_dev", "duet_balanced"]
    assert Enum.find(payload.effective_profile.phases, &(&1.phase == "SPEC")).author == "claude"
  end

  test "select stores an operator routing profile for runtime use" do
    settings = Config.settings!().duet

    assert {:ok, payload} = RoutingSelection.select(settings, "codex_only_dev")
    assert payload.selected_profile == "codex_only_dev"
    assert payload.selection_source == "operator"
    assert payload.effective_profile.mode == "degraded_single_agent"

    assert RoutingSelection.selected_profile_name(settings) == "codex_only_dev"
    assert {:ok, profile} = RoutingSelection.resolve(settings)
    assert profile.name == "codex_only_dev"
    assert profile.degraded? == true
  end

  test "select rejects unknown profiles" do
    assert {:error, {:unknown_profile, "missing"}} = RoutingSelection.select(Config.settings!().duet, "missing")
    assert RoutingSelection.selected_profile_name(Config.settings!().duet) == "duet_balanced"
  end
end
