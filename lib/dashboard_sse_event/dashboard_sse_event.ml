type t =
  | Approval_pending
  | Approval_resolved
  | Approval_audit
  | Approval_summary_updated

let to_string = function
  | Approval_pending -> "approval:pending"
  | Approval_resolved -> "approval:resolved"
  | Approval_audit -> "approval:audit"
  | Approval_summary_updated -> "approval:summary_updated"
;;

let encode event ~payload =
  `Assoc [ "type", `String (to_string event); "payload", payload ]
;;
