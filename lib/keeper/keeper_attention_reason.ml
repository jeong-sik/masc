type t =
  | Approval_queue_unavailable
  | Approval_pending
  | Paused_on_blocker
  | Runtime_attempts_exhausted
  | Provider_runtime_error
  | Fiber_unresolved
  | Runtime_blocked
  | Paused
  | Keepalive_stopped
[@@deriving enumerate]

let to_wire = function
  | Approval_queue_unavailable -> "approval_queue_unavailable"
  | Approval_pending -> "approval_pending"
  | Paused_on_blocker | Paused -> "paused"
  | Runtime_attempts_exhausted -> "runtime_attempts_exhausted"
  | Provider_runtime_error -> "provider_runtime_error"
  | Fiber_unresolved -> "fiber_unresolved"
  | Runtime_blocked -> "runtime_blocked"
  | Keepalive_stopped -> "keepalive_stopped"
;;

let next_human_action = function
  | Approval_queue_unavailable -> "reset_runtime_state"
  | Approval_pending -> "resolve_approval"
  | Paused_on_blocker -> "inspect_blocker_before_resume"
  | Runtime_attempts_exhausted -> "inspect_runtime_attempts"
  | Provider_runtime_error -> "inspect_provider_runtime_cause"
  | Fiber_unresolved -> "inspect_turn_finalization"
  | Runtime_blocked -> "inspect_runtime_blocker"
  | Paused -> "resume_or_review"
  | Keepalive_stopped -> "inspect_latest_error"
;;
