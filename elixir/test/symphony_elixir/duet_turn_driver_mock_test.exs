defmodule SymphonyElixir.DuetTurnDriverMockTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Duet.TurnDriver
  alias SymphonyElixir.Duet.TurnDrivers.Mock

  describe "drive_turn/2" do
    test "returns {:ok, response} when :response is provided" do
      assert {:ok, "canned response"} = Mock.drive_turn("prompt", response: "canned response")
    end

    test "returns {:ok, response} for an empty binary response" do
      assert {:ok, ""} = Mock.drive_turn("prompt", response: "")
    end

    test "prefers :response over :error when both are provided" do
      assert {:ok, "winner"} = Mock.drive_turn("prompt", response: "winner", error: :ignored)
    end

    test "returns {:error, reason} when :error is provided" do
      assert {:error, :boom} = Mock.drive_turn("prompt", error: :boom)
    end

    test "passes through arbitrary error terms" do
      assert {:error, {:timeout, 5_000}} = Mock.drive_turn("prompt", error: {:timeout, 5_000})
    end

    test "ignores :response when it is not a binary and falls through to :error" do
      assert {:error, :fallback} = Mock.drive_turn("prompt", response: nil, error: :fallback)
    end

    test "ignores :response when it is not a binary and falls through to :no_canned_response" do
      assert {:error, :no_canned_response} = Mock.drive_turn("prompt", response: 42)
    end

    test "returns {:error, :no_canned_response} when neither :response nor :error is provided" do
      assert {:error, :no_canned_response} = Mock.drive_turn("prompt", [])
    end

    test "ignores unrelated opts" do
      assert {:ok, "ok"} = Mock.drive_turn("prompt", response: "ok", timeout_ms: 1_000, model: "gpt-x")
    end
  end

  describe "behaviour conformance" do
    test "Mock declares the SymphonyElixir.Duet.TurnDriver behaviour" do
      behaviours =
        :attributes
        |> Mock.module_info()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert TurnDriver in behaviours
    end

    test "Mock implements the drive_turn/2 callback" do
      Code.ensure_loaded!(Mock)
      assert {:drive_turn, 2} in Mock.__info__(:functions)
      assert {:drive_turn, 2} in TurnDriver.behaviour_info(:callbacks)
    end
  end
end
