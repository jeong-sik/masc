let waits_changed_event = "keeper_tool_approval_waits_changed"
let mode_changed_event = "keeper_tool_approval_mode_changed"

let broadcast ~event ~keeper_name =
  try Sse.broadcast (`Assoc [ "type", `String event; "name", `String keeper_name ]) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "tool approval: broadcast %s keeper=%s failed: %s"
      event
      keeper_name
      (Printexc.to_string exn)
;;

let waits_changed ~keeper_name = broadcast ~event:waits_changed_event ~keeper_name
let mode_changed ~keeper_name = broadcast ~event:mode_changed_event ~keeper_name
