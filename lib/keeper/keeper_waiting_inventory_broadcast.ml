type source = Chat_operation | Event_queue

let source_to_string = function
  | Chat_operation -> "chat_operation"
  | Event_queue -> "event_queue"
;;

let changed ~base_path ~keeper_name ~source =
  try
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority)
      (`Assoc
        [ "type", `String "keeper_waiting_inventory_changed"
        ; "keeper_name", `String keeper_name
        ; "queue_kind", `String (source_to_string source)
        ; "ts_unix", `Float (Time_compat.now ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string SseBroadcastFailures)
      ~labels:[ "keeper", keeper_name; "site", "waiting_inventory_changed" ]
      ();
    Log.Keeper.warn
      "keeper_waiting_inventory_broadcast: changed name=%s failed: %s"
      keeper_name
      (Printexc.to_string exn)
;;
