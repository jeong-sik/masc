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
       - tool-level timeouts and OAS max-turn limits bound tool work and
         finite turn loops
     The former watchdog killed healthy active streams that were making
     progress but slowly, wasting ~570s of productive work per event
     (~1077 events/24h, 100% at 540-600s latency). The optional supervisor
     stale-turn watchdog remains the hard-stop path for real no-progress
     runaways. *)
  try run () with
  | Eio.Cancel.Cancelled _ as e ->
    on_cancelled ();
    raise e
;;
