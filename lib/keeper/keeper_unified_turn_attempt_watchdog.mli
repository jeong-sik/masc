(** Per-attempt cancel handler for a single keeper turn runtime attempt.

    RFC-XXXX: the per-attempt wall-clock watchdog was removed.
    Provider-attempt liveness is progress-based:
      - [stream_idle_timeout_s] catches inter-line stalls
      - tool-level timeouts and OAS max-turn limits bound tool work and
        finite turn loops

    Two outcomes:

    - normal completion: pass-through of [run]'s [result]
    - [Eio.Cancel.Cancelled]: invoke [on_cancelled] for the terminal
      receipt + FSM transition, then re-raise so the outer cleanup
      handler observes the cancellation

    [attempt_watchdog_s] and [oas_timeout_s] are retained in the call shape for
    compatibility with the runtime-budget plumbing, but this module no longer
    starts an [Eio.Time.with_timeout_exn] attempt watchdog.

    The Cancelled re-raise path is the outer catch for cancellations
    that escape the in-band receipt builder in
    [Keeper_agent_run.run_turn]: the inner Cancel handlers all
    re-raise, so without [on_cancelled] the FSM emits Streaming and
    then nothing — the turn silently disappears from the operator's
    timeline. *)
val dispatch
  :  clock:_ Eio.Time.clock
  -> attempt_watchdog_s:float option
  -> oas_timeout_s:float
  -> on_cancelled:(unit -> unit)
  -> run:(unit -> ('a, Agent_sdk.Error.sdk_error) result)
  -> ('a, Agent_sdk.Error.sdk_error) result
