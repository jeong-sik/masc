(** Portal tools — agent-to-agent direct messaging.
    Tool handlers removed (deprecated #4999).
    Only filter_visible_tool_names retained for keeper agent run. *)

type context =
  { config : Coord.config
  ; agent_name : string
  }

let filter_visible_tool_names ctx tool_names =
  let portal_open =
    Option.is_some (Coord.get_portal_target ctx.config ~agent_name:ctx.agent_name)
  in
  List.filter
    (fun name ->
       match name with
       | "masc_portal_status" -> true
       | "masc_portal_open" -> not portal_open
       | "masc_portal_send" | "masc_portal_close" -> portal_open
       | _ -> true)
    tool_names
;;
