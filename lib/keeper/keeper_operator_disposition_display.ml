let reason_or_default ~operator_disposition_reason default =
  match String.trim operator_disposition_reason with
  | "" -> default
  | value -> value
;;

let of_kind ~operator_disposition_reason = function
  | Keeper_execution_receipt.Disp_pass -> ("Pass", "healthy")
  | Keeper_execution_receipt.Disp_skipped -> ("Pass", "phase_skipped")
  | Keeper_execution_receipt.Disp_pass_next_model -> ("Pass", "runtime_fallback")
  | Keeper_execution_receipt.Disp_pause_human ->
    ( "Blocked",
      reason_or_default ~operator_disposition_reason "needs_human_attention" )
  | Keeper_execution_receipt.Disp_fail_open_next_runtime ->
    ("Blocked", reason_or_default ~operator_disposition_reason "degraded_retry")
  | Keeper_execution_receipt.Disp_user_cancelled ->
    ("Blocked", reason_or_default ~operator_disposition_reason "cancelled")
  | Keeper_execution_receipt.Disp_alert_exhausted ->
    ("Alert", reason_or_default ~operator_disposition_reason "runtime_exhausted")
  | Keeper_execution_receipt.Disp_unknown ->
    ( "Alert",
      reason_or_default ~operator_disposition_reason "unmapped_runtime_state" )
;;

let of_wire ~operator_disposition ~operator_disposition_reason =
  let normalized = String.lowercase_ascii operator_disposition in
  match Keeper_execution_receipt.operator_disposition_kind_of_string normalized with
  | Some kind -> of_kind ~operator_disposition_reason kind
  | None -> (
    match normalized with
    | "blocked" | "blocked_runtime" ->
      ("Blocked", reason_or_default ~operator_disposition_reason "runtime_blocked")
    | _ ->
      ( "Alert",
        reason_or_default ~operator_disposition_reason
          "unmapped_operator_disposition" ))
;;
