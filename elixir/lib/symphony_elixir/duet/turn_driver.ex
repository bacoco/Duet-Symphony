defmodule SymphonyElixir.Duet.TurnDriver do
  @moduledoc """
  Behaviour describing how a single Duet agent turn is driven.

  The Duet pair-loop alternates prompts between two agents (Codex
  and Claude in production). Each side of the loop is responsible
  for one mechanical step: take a fully-rendered prompt, hand it
  to a concrete agent runtime, wait for the agent to finish, and
  return the raw response text back to the orchestrator.

  This module captures that single step as a behaviour so the
  orchestrator can stay agnostic of the underlying runtime. The
  same pair-loop code can drive a Codex `app-server` session, a
  Claude turn over the SDK, or — in tests — a deterministic
  in-process mock (`SymphonyElixir.Duet.TurnDrivers.Mock`).

  Implementations are expected to be pure with respect to Duet
  state: they MUST NOT touch the event log, parse trailers, or
  apply routing decisions. Trailer parsing belongs to
  `SymphonyElixir.Duet.Trailer`, event logging to
  `SymphonyElixir.Duet.Turn`, and routing to
  `SymphonyElixir.Duet.Routing`. A `TurnDriver` only converts a
  prompt into response text (or an error).

  Per-turn options (timeouts, working directory, model overrides,
  canned mock responses) flow through the `opts` keyword list.
  Concrete drivers document the keys they consume; unknown keys
  must be ignored so callers can pass a single shared option list
  to heterogeneous drivers without coupling.
  """

  @typedoc """
  Successful response text from the agent, or a driver-specific
  error term. The error term is opaque to the orchestrator: it is
  surfaced verbatim into the event log and bubbled up to the
  caller for retry/escalation decisions.
  """
  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Drive a single agent turn for the given prompt.

  Returns `{:ok, response_text}` when the agent produced a
  response (the trailer is parsed downstream by
  `SymphonyElixir.Duet.Trailer`), or `{:error, reason}` when the
  underlying runtime failed before any response could be observed.
  """
  @callback drive_turn(prompt :: String.t(), opts :: keyword()) :: result()
end
