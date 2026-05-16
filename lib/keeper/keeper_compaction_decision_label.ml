type t =
  | Applied_ratio
  | Applied_message
  | Applied_token
  | Applied_tool_heavy
  | Applied_manual
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection

let to_label = function
  | Applied_ratio -> "applied_ratio"
  | Applied_message -> "applied_message"
  | Applied_token -> "applied_token"
  | Applied_tool_heavy -> "applied_tool_heavy"
  | Applied_manual -> "applied_manual"
  | Blocked_below_thresholds -> "blocked_below_thresholds"
  | Skipped_no_checkpoint -> "skipped_no_checkpoint"
  | Skipped_continuity_reflection -> "skipped_continuity_reflection"
;;
