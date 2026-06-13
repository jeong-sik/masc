(** Per-attempt cancellation observer for a single keeper turn runtime attempt.

    MASC must not impose a wall-clock timeout around the whole provider/tool
    run. Active tool execution belongs to the tool substrate / OAS boundary and
    may legitimately outlive provider stream progress budgets.

    Two outcomes:

    - normal completion: pass-through of [run]'s [result]
    - [Eio.Cancel.Cancelled]: invoke [on_cancelled] with a reason string for
      the terminal receipt + FSM transition, then re-raise so the outer cleanup
      handler observes the cancellation

    [on_cancelled] receives the cancellation reason:
      - ["external_cancel"] — fiber was cancelled externally

    The Cancelled re-raise path is the outer catch for cancellations
    that escape the in-band receipt builder in
    [Keeper_agent_run.run_turn]: without [on_cancelled] the FSM emits
    Streaming and then nothing — the turn silently disappears from the
    operator's timeline.

    [clock], [keeper_name], and [attempt_watchdog_s] are retained for call-site
    compatibility with the old watchdog API. They are intentionally ignored. *)
val dispatch
  :  clock:_ Eio.Time.clock
  -> keeper_name:string
  -> attempt_watchdog_s:float option
  -> on_cancelled:(string -> unit)
  -> run:(unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
