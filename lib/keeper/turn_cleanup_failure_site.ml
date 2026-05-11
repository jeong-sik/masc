type t =
  | Unsubscribe_event_bus
  | Mark_turn_finished

let to_label = function
  | Unsubscribe_event_bus -> "unsubscribe_event_bus"
  | Mark_turn_finished -> "mark_turn_finished"
;;
