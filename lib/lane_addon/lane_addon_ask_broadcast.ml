let asks_changed_event = "lane_addon_asks_changed"

let asks_changed ~declaration_id =
  try
    Sse.broadcast
      (`Assoc [ "type", `String asks_changed_event; "declaration_id", `String declaration_id ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn
      "installation questions: broadcast %s declaration=%s failed: %s"
      asks_changed_event
      declaration_id
      (Printexc.to_string exn)
;;
