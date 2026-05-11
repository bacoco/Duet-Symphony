defmodule SymphonyElixir.DuetTestHelpers do
  defmodule SequenceDriver do
    @behaviour SymphonyElixir.Duet.TurnDriver

    @impl SymphonyElixir.Duet.TurnDriver
    def drive_turn(prompt, opts) do
      agent = Keyword.fetch!(opts, :sequence_agent)
      test_pid = Keyword.get(opts, :test_pid)

      response =
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {"(no more responses)", []}
        end)

      if test_pid, do: send(test_pid, {:duet_prompt, prompt})
      {:ok, response}
    end
  end

  def approve_response(label) do
    """
    #{label}

    ---DUET-TRAILER---
    verdict: APPROVE
    confidence: 0.9
    summary: #{label} ready
    unresolved: []
    ---END-DUET-TRAILER---
    """
  end
end
