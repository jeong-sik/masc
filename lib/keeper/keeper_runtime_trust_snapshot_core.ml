type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class : Keeper_status_bridge_blocker.runtime_blocker_class option
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind
      * Keeper_execution_receipt.operator_disposition_reason)
        option
  ; status_attention : Keeper_attention_reason.t option
  ; terminal_next_human_action : string option
  }

type disposition_reason =
  | Healthy
  | Approval_queue_unreadable
  | Pending_operator_decision
  | Runtime_exhausted
  | Critical_block
  | Unknown_runtime_blocker
  | Keeper_dashboard_worker_exception
  | Receipt_reason of Keeper_execution_receipt.operator_disposition_reason

let disposition_reason_to_wire = function
  | Healthy -> "healthy"
  | Approval_queue_unreadable -> "approval_queue_unavailable"
  | Pending_operator_decision -> "pending_operator_decision"
  | Runtime_exhausted -> "runtime_exhausted"
  | Critical_block -> "critical_block"
  | Unknown_runtime_blocker -> "unknown_runtime_blocker"
  | Keeper_dashboard_worker_exception -> "keeper_dashboard_worker_exception"
  | Receipt_reason reason -> Keeper_execution_receipt.operator_disposition_reason_to_string reason
;;

type attention_reason =
  | Status_attention of Keeper_attention_reason.t
  | Disposition_attention of disposition_reason
  | Dashboard_worker_error of string

let attention_reason_to_wire = function
  | Status_attention reason -> Keeper_attention_reason.to_wire reason
  | Disposition_attention reason -> disposition_reason_to_wire reason
  | Dashboard_worker_error message -> message
;;

type t =
  { disposition : Keeper_trust_disposition.t
  ; disposition_reason : disposition_reason
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind
      * Keeper_execution_receipt.operator_disposition_reason)
        option
  ; needs_attention : bool
  ; attention_reason : attention_reason option
  ; next_human_action : string option
  }

let fallback_disposition raw =
  match raw.approval_queue with
  | Approval_queue_unavailable -> Keeper_trust_disposition.Alert, Approval_queue_unreadable
  | Approval_queue_available pending_approval_count when pending_approval_count > 0 ->
    Keeper_trust_disposition.Alert, Pending_operator_decision
  | Approval_queue_available _ ->
    (match raw.runtime_blocker_class with
     | Some Keeper_status_bridge_blocker.Blocked_by_runtime_exhaustion ->
       Keeper_trust_disposition.Alert, Runtime_exhausted
     | Some Keeper_status_bridge_blocker.Blocked_by_unresolved_fiber ->
       Keeper_trust_disposition.Alert, Critical_block
     (* These seven show as unknown_runtime_blocker. Which reason each should
        show is a display decision of its own (#43018). *)
     | Some
         ( Keeper_status_bridge_blocker.Blocked_by_heartbeat_failures
         | Keeper_status_bridge_blocker.Blocked_by_turn_failures
         | Keeper_status_bridge_blocker.Blocked_by_provider_runtime_error
         | Keeper_status_bridge_blocker.Blocked_by_official_client_recovery
         | Keeper_status_bridge_blocker.Blocked_by_turn_configuration_error
         | Keeper_status_bridge_blocker.Blocked_by_exception
         | Keeper_status_bridge_blocker.Blocked_by_operator_interrupt ) ->
       Keeper_trust_disposition.Alert, Unknown_runtime_blocker
     | None -> Keeper_trust_disposition.Pass, Healthy)
;;

(* The verdict a shown receipt stands for. A passing receipt reads as healthy
   whatever its reason (it may say the turn waits for input); every other kind
   shows the receipt's own reason. *)
let receipt_disposition kind reason =
  let module R = Keeper_execution_receipt in
  match kind with
  | R.Disp_pass -> Keeper_trust_disposition.Pass, Healthy
  | R.Disp_skipped | R.Disp_pass_next_model | R.Disp_fail_open_next_runtime
  | R.Disp_retry_later ->
    Keeper_trust_disposition.Pass, Receipt_reason reason
  | R.Disp_operator_action_required | R.Disp_user_cancelled ->
    Keeper_trust_disposition.Blocked, Receipt_reason reason
  (* Not "Blocked": the Keeper keeps running. What the turn may have done
     outside still needs a person, so it stays an alert. *)
  | R.Disp_effect_review_required -> Keeper_trust_disposition.Alert, Receipt_reason reason
  | R.Disp_unknown -> Keeper_trust_disposition.Alert, Receipt_reason reason
;;

(* Only a shown receipt has an operator disposition to relay. The snapshot's
   own verdict comes from the approval queue or a runtime blocker, and nothing
   classifies those into an operator disposition: the same [turn_failures]
   blocker follows a fenced turn and a soft failure the Keeper retries. Any
   kind picked here would be a guess, so the fallback reports none. *)
let effective_disposition raw ~fallback_disposition ~fallback_reason =
  match raw.approval_queue, raw.receipt_operator_disposition with
  | ( Approval_queue_available 0
    , (Some (operator_disposition, operator_reason) as receipt_operator_disposition) )
    ->
    let disposition, disposition_reason =
      receipt_disposition operator_disposition operator_reason
    in
    disposition, disposition_reason, receipt_operator_disposition
  | Approval_queue_unavailable, _
  | Approval_queue_available _, _ -> fallback_disposition, fallback_reason, None
;;

let decide raw =
  let fallback_disposition, fallback_reason = fallback_disposition raw in
  let disposition, disposition_reason, receipt_operator_disposition =
    effective_disposition raw ~fallback_disposition ~fallback_reason
  in
  let needs_attention =
    Option.is_some raw.status_attention
    || Keeper_trust_disposition.requires_attention disposition
  in
  let attention_reason =
    match raw.status_attention with
    | Some reason -> Some (Status_attention reason)
    | None when needs_attention -> Some (Disposition_attention disposition_reason)
    | None -> None
  in
  let next_human_action =
    match raw.status_attention with
    | Some reason -> Some (Keeper_attention_reason.next_human_action reason)
    | None when needs_attention -> raw.terminal_next_human_action
    | None -> None
  in
  { disposition
  ; disposition_reason
  ; receipt_operator_disposition
  ; needs_attention
  ; attention_reason
  ; next_human_action
  }
;;
