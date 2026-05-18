(** Keeper registry dashboard broadcast helpers. *)

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
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_lifecycle_dispatch_rejections
      ~labels:[ "keeper", name; "event", "broadcast_composite_failed" ]
      ();
    Log.Keeper.warn
      "registry: broadcast_composite_changed name=%s failed: %s"
      name
      (Printexc.to_string exn)
;;

let phase_failure ~name exn =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_sse_broadcast_failures
    ~labels:[ "keeper", name; "site", "phase_changed" ]
    ();
  Log.Keeper.warn
    "registry: keeper_phase_changed broadcast failed name=%s err=%s"
    name
    (Printexc.to_string exn)
;;
