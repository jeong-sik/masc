let asks_changed_event = "keeper_asks_changed"

let asks_changed ~keeper_name =
  try Sse.broadcast (`Assoc [ "type", `String asks_changed_event; "name", `String keeper_name ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper asks: broadcast %s keeper=%s failed: %s"
      asks_changed_event
      keeper_name
      (Printexc.to_string exn)
;;
