let changed_event = "pending_confirms_changed"

let changed ~base_path =
  try Sse.broadcast (`Assoc [ "type", `String changed_event ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn
      "pending confirms: broadcast %s for %s failed: %s"
      changed_event
      base_path
      (Printexc.to_string exn)
;;
