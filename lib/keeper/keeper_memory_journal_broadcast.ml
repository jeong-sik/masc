let appended ~keeper_name =
  try
    Sse.broadcast
      (`Assoc
        [ "type", `String "keeper_memory_journal_appended"
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", "memory_journal_appended" ]
      ();
    Log.Keeper.warn
      "keeper_memory_journal_broadcast: appended name=%s failed: %s"
      keeper_name
      (Printexc.to_string exn)
;;
