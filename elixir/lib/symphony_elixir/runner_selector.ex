defmodule SymphonyElixir.RunnerSelector do
  @moduledoc """
  Selects the worker runner for the current workflow configuration.
  """

  alias SymphonyElixir.{AgentRunner, Config}
  alias SymphonyElixir.Duet.PairRunner

  @type runner :: module()

  @spec choose(Config.Schema.t()) :: runner()
  def choose(%Config.Schema{duet: %{enabled: true}}), do: PairRunner
  def choose(%Config.Schema{}), do: AgentRunner
end
