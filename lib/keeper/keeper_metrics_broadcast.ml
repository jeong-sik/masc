let appended_event = "keeper_metrics_appended"

let appended ~base_path ~name =
  (* The row is already on disk. A failure to announce it is counted here and
     never reported as a failed append. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String appended_event
        ; "name", `String name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "site", appended_event; "keeper", name ]
      ();
    Log.Keeper.warn "keeper_metrics_broadcast: %s for %s failed: %s" appended_event name
      (Printexc.to_string exn)
;;
