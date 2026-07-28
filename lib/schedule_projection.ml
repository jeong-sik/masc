(* TEL-OK: pure schedule read-model projection; schedule tool/runner handlers own
   execution telemetry. *)

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

