type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class :
      (Keeper_meta_contract.blocker_class, string) result option
  ; receipt_operator_disposition : (string * string) option
  ; attention_needs_attention : bool
  ; attention_reason : string option
  ; attention_next_human_action : string option
  ; terminal_next_human_action : string option
  }

type t =
  { disposition : string
  ; disposition_reason : string
  ; operator_disposition : string
  ; operator_disposition_reason : string
  ; needs_attention : bool
  ; attention_reason : string option
  ; next_human_action : string option
  }

(* The snapshot's own verdict when it shows no receipt verdict: the approval
   queue or a runtime blocker decides, or nothing is wrong. Closed, so the
   operator disposition is chosen per verdict below instead of being parsed
   back out of a display label. *)
type fallback_verdict =
  | Fallback_pass
  | Fallback_alert

let fallback_display = function
  | Fallback_pass -> "Pass"
  | Fallback_alert -> "Alert"
;;

let fallback_disposition raw =
  match raw.approval_queue with
  | Approval_queue_unavailable -> Fallback_alert, "approval_queue_unavailable"
  | Approval_queue_available pending_approval_count when pending_approval_count > 0 ->
    Fallback_alert, "pending_operator_decision"
  | Approval_queue_available _ ->
    (match raw.runtime_blocker_class with
     | Some (Ok (Keeper_meta_contract.Runtime_exhausted _)) ->
       Fallback_alert, "runtime_exhausted"
     | Some (Ok _) -> Fallback_alert, "critical_block"
     | Some (Error _) -> Fallback_alert, "unknown_runtime_blocker"
     | None -> Fallback_pass, "healthy")
;;

(* Every alert above names its cause in the reason and asks a person to act on
   it: decide the pending approval, repair the queue store the snapshot cannot
   read, or clear the runtime blocker. [Disp_unknown] reports a receipt the
   classifier could not place, which none of these is. *)
let fallback_operator_disposition = function
  | Fallback_pass -> Keeper_execution_receipt.Disp_pass
  | Fallback_alert -> Keeper_execution_receipt.Disp_operator_action_required
;;

let display_disposition_requires_attention = function
  | "Blocked" | "Pause" | "Alert" -> true
  | _ -> false
;;

let effective_disposition raw ~fallback ~fallback_reason =
  match raw.approval_queue, raw.receipt_operator_disposition with
  | Approval_queue_available 0, Some (operator_disposition, operator_reason) ->
    let disposition, disposition_reason =
      Keeper_operator_disposition_display.of_wire
        ~operator_disposition
        ~operator_disposition_reason:operator_reason
    in
    disposition, disposition_reason, operator_disposition, operator_reason
  | Approval_queue_unavailable, _
  | Approval_queue_available _, _ ->
    ( fallback_display fallback
    , fallback_reason
    , Keeper_execution_receipt.operator_disposition_kind_to_string
        (fallback_operator_disposition fallback)
    , fallback_reason )
;;

let decide raw =
  let fallback, fallback_reason = fallback_disposition raw in
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
    effective_disposition raw ~fallback ~fallback_reason
  in
  let needs_attention =
    raw.attention_needs_attention
    || display_disposition_requires_attention disposition
  in
  let attention_reason =
    match raw.attention_reason with
    | Some _ as reason -> reason
    | None when needs_attention -> Some disposition_reason
    | None -> None
  in
  let next_human_action =
    match raw.attention_next_human_action with
    | Some _ as action -> action
    | None when needs_attention -> raw.terminal_next_human_action
    | None -> None
  in
  { disposition
  ; disposition_reason
  ; operator_disposition
  ; operator_disposition_reason
  ; needs_attention
  ; attention_reason
  ; next_human_action
  }
;;
