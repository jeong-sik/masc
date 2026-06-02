type t =
  | Stripped_raw
  | Fallback_param
  | State_snapshot_progress
  | State_snapshot_goal
  | Hardcoded_default

let to_label = function
  | Stripped_raw -> "stripped_raw"
  | Fallback_param -> "fallback_param"
  | State_snapshot_progress -> "state_snapshot_progress"
  | State_snapshot_goal -> "state_snapshot_goal"
  | Hardcoded_default -> "hardcoded_default"
;;
