(** Per-attempt cancel handler for a single keeper turn runtime attempt.

    A wall-clock safety deadline wraps every attempt:
      - When [attempt_watchdog_s] is [Some deadline], that deadline is used.
      - When [attempt_watchdog_s] is [None], a generous safety cap of
        1800s (30 min) prevents a stuck fiber from locking a keeper in
        [Streaming] state forever. The previous watchdog was removed
        because it killed healthy streams at 540-600s; the 1800s cap is
        3x that, targeting only truly stuck fibers.

    Two outcomes:

    - normal completion: pass-through of [run]'s [result]
    - [Eio.Time.Timeout] (safety deadline) or [Eio.Cancel.Cancelled]:
      invoke [on_cancelled] for the terminal receipt + FSM transition,
      then re-raise so the outer cleanup handler observes the cancellation

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
