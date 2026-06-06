let dispatch
      ~clock:_clock
      ~attempt_watchdog_s:_attempt_watchdog_s
      ~oas_timeout_s:_oas_timeout_s
      ~on_cancelled
      ~run
  =
  (* RFC-XXXX: The per-attempt wall-clock watchdog is removed.
     Provider-attempt liveness is progress-based:
       - [stream_idle_timeout_s] catches inter-line stalls
       - [Keeper_attempt_liveness] catches no-first-token / inter-chunk gaps
       - The keeper turn watchdog ([Eio.Time.with_timeout_exn] in
         [Keeper_unified_turn_execution]) is the outer runaway guard
     The former watchdog killed healthy active streams that were making
     progress but slowly, wasting ~570s of productive work per event
     (~1077 events/24h, 100% at 540-600s latency).  The outer keeper
     turn timeout still prevents runaway turns. *)
  try run () with
  | Eio.Cancel.Cancelled _ as e ->
    on_cancelled ();
    raise e
;;
