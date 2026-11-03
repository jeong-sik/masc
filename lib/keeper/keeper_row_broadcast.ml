let row_changed_event = "keeper_row_changed"

let changed ~base_path ~keeper_name =
  let report exn =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", row_changed_event ]
      ();
    Log.Keeper.warn
      "keeper_row_broadcast: %s name=%s failed: %s"
      row_changed_event
      keeper_name
      (Printexc.to_string exn)
  in
  (* Every caller has already committed its write, and the registry calls this
     inside its lifecycle key lock before its own bookkeeping. A cancellation
     raised here would skip that bookkeeping, so it is reported like any
     failure; the caller's next suspension point still sees it. *)
  match
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String row_changed_event
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception exn -> report exn
;;
