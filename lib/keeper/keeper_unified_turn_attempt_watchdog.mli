(** RFC-0136 PR-4-c: wrap [Eio.Time.with_timeout_exn] + the
    [Eio.Cancel.Cancelled] / [Eio.Time.Timeout] handling for a single
    keeper turn cascade attempt.  Extracted from
    [keeper_unified_turn.ml] do_run closure (L490-L577).

    Three outcomes:

    - normal completion: pass-through of [run]'s [result]
    - [Eio.Cancel.Cancelled]: invoke [on_cancelled] for the terminal
      receipt + FSM transition, then re-raise so the outer cleanup
      handler observes the cancellation
    - [Eio.Time.Timeout]: return [Error (Api (Timeout {message}))]
      with the budget / watchdog values inlined for operator
      diagnostics

    The Cancelled re-raise path is the outer catch for cancellations
    that escape the in-band receipt builder in
    [Keeper_agent_run.run_turn]: the 14 inner Cancel handlers all
    re-raise, so without [on_cancelled] the FSM emits Streaming and
    then nothing — the turn silently disappears from the operator's
    timeline.  Cycle 1b-iv. *)
val dispatch
  :  clock:_ Eio.Time.clock
  -> attempt_watchdog_s:float
  -> oas_timeout_s:float
  -> on_cancelled:(unit -> unit)
  -> run:(unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
