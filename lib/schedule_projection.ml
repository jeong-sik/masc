(* TEL-OK: pure schedule read-model projection; schedule tool/runner handlers own
   execution telemetry. *)

let schedule_get_tool = "masc_schedule_get"

let inspect_and_monitor_dispatch =
  "Inspect the schedule if needed and monitor dispatch; do not create a duplicate schedule."
;;

let wait_for_runner_tick =
  "The schedule is due but the runner has not refreshed it yet; inspect if needed, otherwise wait for the runner tick."
;;

let inspect_expired_before_recreate =
  "Inspect the expired schedule and recreate it with masc_schedule_create only if the operator still wants it."
;;

type attention_action =
  | Dispatch_ready

let attention_action_to_string = function
  | Dispatch_ready -> "dispatch_ready"
;;

type execution_readiness =
  | Due_pending_refresh
  | Expired
  | Ready
  | Scheduled
  | Running
  | Terminal

let execution_readiness_to_string = function
  | Due_pending_refresh -> "due_pending_refresh"
  | Expired -> "expired"
  | Ready -> "ready"
  | Scheduled -> "scheduled"
  | Running -> "running"
  | Terminal -> "terminal"
;;

let operator_action_for_execution_readiness = function
  | Due_pending_refresh -> Some "wait_for_runner_tick"
  | Expired -> Some "inspect_or_recreate"
  | Ready -> Some "wait_for_dispatch"
  | Scheduled | Running | Terminal -> None
;;

let keeper_next_tool_for_attention_action = function
  | Dispatch_ready -> Some schedule_get_tool
;;

let keeper_next_action_for_attention_action = function
  | Dispatch_ready -> inspect_and_monitor_dispatch
;;

let keeper_next_tool_for_execution_readiness = function
  | Due_pending_refresh | Expired | Ready ->
    Some schedule_get_tool
  | Scheduled | Running | Terminal -> None
;;

let keeper_next_action_for_execution_readiness = function
  | Due_pending_refresh -> Some wait_for_runner_tick
  | Expired -> Some inspect_expired_before_recreate
  | Ready -> Some inspect_and_monitor_dispatch
  | Scheduled | Running | Terminal -> None
;;
