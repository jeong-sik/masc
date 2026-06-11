(* Per-attempt cancel handler for a single keeper turn runtime attempt.

   A wall-clock safety deadline wraps every attempt:
     - When [attempt_watchdog_s] is [Some deadline], that deadline is used.
     - When [attempt_watchdog_s] is [None], the env-configurable safety cap
       [MASC_KEEPER_ATTEMPT_WATCHDOG_SAFETY_CAP_SEC] (default 1800s / 30 min)
       prevents a stuck fiber from locking a keeper in [Streaming] state
       forever. Any provider attempt that makes zero progress for that
       duration is definitively stuck (network hang, silent provider failure).

   The previous wall-clock watchdog was removed because it killed healthy
   streams at 540-600s. The safety cap is 3x that, targeting only truly
   stuck fibers while never affecting legitimate slow-but-progressing streams.

   Two outcomes:
     - normal completion: pass-through of [run]'s [result]
     - timeout or [Eio.Cancel.Cancelled]: invoke [on_cancelled] with a
       reason string for the terminal receipt + FSM transition, then re-raise
       so the outer cleanup handler observes the cancellation

   [on_cancelled] receives the cancellation reason:
     - ["attempt_watchdog_safety_deadline"] — wall-clock timeout fired
     - ["external_cancel"] — fiber was cancelled externally

   The Cancelled re-raise path is the outer catch for cancellations
   that escape the in-band receipt builder in
   [Keeper_agent_run.run_turn]: the inner Cancel handlers all
   re-raise, so without [on_cancelled] the FSM emits Streaming and
   then nothing — the turn silently disappears from the operator's
   timeline. *)

let dispatch
    ~clock
    ~keeper_name
    ~attempt_watchdog_s
    ~on_cancelled
    ~run
  =
  let deadline_s = match attempt_watchdog_s with
    | Some s -> Float.max s 1.0
    | None -> Env_config_keeper.KeeperKeepalive.attempt_watchdog_safety_cap_sec
  in
  try
    Eio.Time.with_timeout_exn clock deadline_s run
  with
  | Eio.Time.Timeout ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string AttemptWatchdogFired)
      ~labels:[ ("keeper", keeper_name) ]
      ();
    on_cancelled "attempt_watchdog_safety_deadline";
    raise (Eio.Cancel.Cancelled (Failure "attempt_watchdog_safety_deadline"))
  | Eio.Cancel.Cancelled _ as e ->
    on_cancelled "external_cancel";
    raise e
;;
