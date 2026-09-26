type approval_lifecycle_phase =
  | Approval_requested
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate
  | Approval_continuation_recorded
  | Approval_continuation_failed

let next_approval_lifecycle_phase = function
  | Approval_requested -> Some Approval_resolved_approved
  | Approval_resolved_approved -> Some Approval_resolved_rejected
  | Approval_resolved_rejected -> Some Approval_replay_applied
  | Approval_replay_applied -> Some Approval_replay_applied_with_warning
  | Approval_replay_applied_with_warning -> Some Approval_replay_failed
  | Approval_replay_failed -> Some Approval_replay_indeterminate
  | Approval_replay_indeterminate -> Some Approval_continuation_recorded
  | Approval_continuation_recorded -> Some Approval_continuation_failed
  | Approval_continuation_failed -> None
;;

let approval_lifecycle_phases =
  let rec walk phase =
    phase :: Option.fold ~none:[] ~some:walk (next_approval_lifecycle_phase phase)
  in
  walk Approval_requested
;;

let approval_lifecycle_phase_to_label = function
  | Approval_requested -> "requested"
  | Approval_resolved_approved -> "resolved_approved"
  | Approval_resolved_rejected -> "resolved_rejected"
  | Approval_replay_applied -> "replay_applied"
  | Approval_replay_applied_with_warning -> "replay_applied_with_warning"
  | Approval_replay_failed -> "replay_failed"
  | Approval_replay_indeterminate -> "replay_indeterminate"
  | Approval_continuation_recorded -> "continuation_recorded"
  | Approval_continuation_failed -> "continuation_failed"
;;

let approval_lifecycle_phase_of_label = function
  | "requested" -> Some Approval_requested
  | "resolved_approved" -> Some Approval_resolved_approved
  | "resolved_rejected" -> Some Approval_resolved_rejected
  | "replay_applied" -> Some Approval_replay_applied
  | "replay_applied_with_warning" -> Some Approval_replay_applied_with_warning
  | "replay_failed" -> Some Approval_replay_failed
  | "replay_indeterminate" -> Some Approval_replay_indeterminate
  | "continuation_recorded" -> Some Approval_continuation_recorded
  | "continuation_failed" -> Some Approval_continuation_failed
  | _ -> None
;;
