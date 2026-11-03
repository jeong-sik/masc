let native_tasks_appended_event = "keeper_native_tasks_appended"
let child_content_appended_event = "keeper_child_content_appended"

let appended ~event ~keeper_name =
  try
    Sse.broadcast
      (`Assoc
        [ "type", `String event
        ; "name", `String keeper_name
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", event ]
      ();
    Log.Keeper.warn
      "keeper_runtime_journal_broadcast: %s name=%s failed: %s"
      event
      keeper_name
      (Printexc.to_string exn)
;;

let native_tasks_appended ~keeper_name =
  appended ~event:native_tasks_appended_event ~keeper_name
;;

let child_content_appended ~keeper_name =
  appended ~event:child_content_appended_event ~keeper_name
;;
