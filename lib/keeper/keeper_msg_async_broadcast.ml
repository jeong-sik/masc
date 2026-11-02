let requests_changed_event = "keeper_async_requests_changed"

let requests_changed ~keeper_name =
  try
    Sse.broadcast
      (`Assoc [ "type", `String requests_changed_event; "name", `String keeper_name ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper async requests: broadcast %s keeper=%s failed: %s"
      requests_changed_event
      keeper_name
      (Printexc.to_string exn)
;;
