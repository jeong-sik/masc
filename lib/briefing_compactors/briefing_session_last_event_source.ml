type t =
  | Recent_event_latest
  | Fabricated_no_recent_events

let to_label = function
  | Recent_event_latest -> "recent_event_latest"
  | Fabricated_no_recent_events -> "fabricated_no_recent_events"
