let row_changed_event = "keeper_row_changed"

let changed ~keeper_name =
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
  match
    Sse.broadcast
      (`Assoc
        [ "type", `String row_changed_event
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    Eio.Fiber.check ();
    report exn
  | exception exn -> report exn
;;
