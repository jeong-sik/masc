type t =
  | Keeper_unified_turn
  | Cost_event_write

let to_label = function
  | Keeper_unified_turn -> "keeper_unified_turn"
  | Cost_event_write -> "cost_event_write"
;;
