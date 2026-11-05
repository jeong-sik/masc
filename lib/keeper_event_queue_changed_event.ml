let event_type = "keeper_event_queue_changed"

let to_json ~keeper_name =
  `Assoc [ ("type", `String event_type); ("keeper", `String keeper_name) ]
;;
