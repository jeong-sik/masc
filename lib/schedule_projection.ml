(* TEL-OK: pure schedule read-model projection; schedule tool/runner handlers own
   execution telemetry. *)

let schedule_get_tool = "masc_schedule_get"

let inspect_before_action = "Inspect the schedule before taking action."

let inspect_and_monitor_dispatch =
  "Inspect the schedule if needed and monitor dispatch; do not create a duplicate schedule."
;;

let approval_decision_required =
  "Inspect details, then wait for an explicit human decision before calling masc_schedule_approve or masc_schedule_reject."
;;

let wait_for_runner_tick =
  "The schedule is due but the runner has not refreshed it yet; inspect if needed, otherwise wait for the runner tick."
;;

let inspect_expired_before_recreate =
  "Inspect the expired schedule and recreate it with masc_schedule_create only if the operator still wants it."
;;

let keeper_next_tool_for_attention_action = function
  | "dispatch_ready" | "approve_or_reject" -> Some schedule_get_tool
  | _ -> None
;;

let keeper_next_action_for_attention_action = function
  | "dispatch_ready" -> inspect_and_monitor_dispatch
  | "approve_or_reject" -> approval_decision_required
  | _ -> inspect_before_action
;;

let keeper_next_tool_for_execution_readiness = function
  | "blocked_approval" | "awaiting_approval" | "due_pending_refresh" | "expired"
  | "ready" | "approved" ->
    Some schedule_get_tool
  | "scheduled" | "running" | "terminal" -> None
  | _ -> None
;;

let keeper_next_action_for_execution_readiness = function
  | "blocked_approval" | "awaiting_approval" -> Some approval_decision_required
  | "due_pending_refresh" -> Some wait_for_runner_tick
  | "expired" -> Some inspect_expired_before_recreate
  | "ready" | "approved" -> Some inspect_and_monitor_dispatch
  | "scheduled" | "running" | "terminal" -> None
  | _ -> None
;;
