(** Cancel_safe — exception-safe callback wrapper for Eio fibers.

    [observe] runs [f ()] and catches all exceptions except
    [Eio.Cancel.Cancelled] (which must propagate to honor cooperative
    cancellation).  All other exceptions are routed to [on_exn] instead
    of propagating to the caller.

    **FSM-critical callback policy**: when wrapping a lifecycle callback
    that dispatches FSM state transitions (e.g. [on_compaction_started],
    [on_handoff_started]), the [on_exn] handler MUST:

    1. Increment a Otel_metric_store counter (e.g.
       [masc_keeper_lifecycle_callback_failures_total{callback=...}])
       so the failure is observable in Grafana.
    2. Record the failure via [Keeper_callback_failure.record] for
       durable audit.
    3. Track callback success in the lifecycle record (e.g.
       [started_dispatched : bool] on [compaction_event]) so downstream
       dispatch sites know the FSM state and can recover the correct
       transition path.

    See [keeper_post_turn.ml] (compaction) and [keeper_rollover.ml]
    (handoff) for reference implementations of this policy. *)

let protect ~on_exn f =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> on_exn exn

let observe ~on_exn f = protect ~on_exn f
