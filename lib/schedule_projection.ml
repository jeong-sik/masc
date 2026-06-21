(* TEL-OK: pure schedule read-model projection; schedule tool/runner handlers own
   execution telemetry. *)

let schedule_get_tool = "masc_schedule_get"

let inspect_and_monitor_dispatch =
  "Inspect the schedule if needed and monitor dispatch; do not create a duplicate schedule."
;;

let approval_decision_required =
  "Inspect details, then wait for the dashboard operator approval or rejection action to resolve this schedule."
;;

let wait_for_runner_tick =
  "The schedule is due but the runner has not refreshed it yet; inspect if needed, otherwise wait for the runner tick."
;;

let inspect_expired_before_recreate =
  "Inspect the expired schedule and recreate it with masc_schedule_create only if the operator still wants it."
;;

type attention_action =
  | Dispatch_ready
  | Approve_or_reject

let attention_action_to_string = function
  | Dispatch_ready -> "dispatch_ready"
  | Approve_or_reject -> "approve_or_reject"
;;

type execution_readiness =
  | Blocked_approval
  | Awaiting_approval
  | Due_pending_refresh
  | Expired
  | Ready
  | Approved
  | Scheduled
  | Running
  | Terminal

let execution_readiness_to_string = function
  | Blocked_approval -> "blocked_approval"
  | Awaiting_approval -> "awaiting_approval"
  | Due_pending_refresh -> "due_pending_refresh"
  | Expired -> "expired"
  | Ready -> "ready"
  | Approved -> "approved"
  | Scheduled -> "scheduled"
  | Running -> "running"
  | Terminal -> "terminal"
;;

let operator_action_for_execution_readiness = function
  | Blocked_approval | Awaiting_approval -> Some "approve_or_reject"
  | Due_pending_refresh -> Some "wait_for_runner_tick"
  | Expired -> Some "inspect_or_recreate"
  | Ready | Approved -> Some "wait_for_dispatch"
  | Scheduled | Running | Terminal -> None
;;

let keeper_next_tool_for_attention_action = function
  | Dispatch_ready | Approve_or_reject -> Some schedule_get_tool
;;

let keeper_next_action_for_attention_action = function
  | Dispatch_ready -> inspect_and_monitor_dispatch
  | Approve_or_reject -> approval_decision_required
;;

let keeper_next_tool_for_execution_readiness = function
  | Blocked_approval | Awaiting_approval | Due_pending_refresh | Expired | Ready
  | Approved ->
    Some schedule_get_tool
  | Scheduled | Running | Terminal -> None
;;

let keeper_next_action_for_execution_readiness = function
  | Blocked_approval | Awaiting_approval -> Some approval_decision_required
  | Due_pending_refresh -> Some wait_for_runner_tick
  | Expired -> Some inspect_expired_before_recreate
  | Ready | Approved -> Some inspect_and_monitor_dispatch
  | Scheduled | Running | Terminal -> None
;;
