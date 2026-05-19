(** SSE broadcast helpers for keeper lifecycle events.

    Extracted from keeper_registry.ml (lines 610-652) as part of the
    godfile decomp campaign. Two pure side-effect wrappers around
    [Sse.broadcast] / [Sse.broadcast_presence] with Prometheus counter
    + log on failure. No registry state touched. *)

let composite_changed ~name ~ts_unix =
  try
    let json =
      `Assoc
        [ "type", `String "keeper_composite_changed"
        ; "name", `String name
        ; "ts_unix", `Float ts_unix
        ]
    in
    Sse.broadcast json;
    Sse.broadcast_presence json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* P2 silent-failure fix: previously this discarded the exception
         silently, hiding the case where the SSE broadcast pipe is dead
         (subscriber cleanup race, transport tear-down).  Operators
         investigating "dashboard stopped updating" had no signal that
         the broadcast itself was failing.  PR-C (#11075) added a
         counter on the SSE side, but only for per-client failures
         inside broadcast_impl — exceptions thrown out of
         Sse.broadcast itself bypass that counter.  Logging here
         makes the exception visible at the call site. *)
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
      ~labels:[ "keeper", name; "event", "broadcast_composite_failed" ]
      ();
    Log.Keeper.warn
      "registry: broadcast_composite_changed name=%s failed: %s"
      name
      (Printexc.to_string exn)
;;

let record_phase_failure ~name exn =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_sse_broadcast_failures
    ~labels:[ "keeper", name; "site", "phase_changed" ]
    ();
  Log.Keeper.warn
    "registry: keeper_phase_changed broadcast failed name=%s err=%s"
    name
    (Printexc.to_string exn)
;;
