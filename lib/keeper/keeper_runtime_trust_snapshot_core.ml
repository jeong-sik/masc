type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class : Keeper_status_bridge_blocker.runtime_blocker_class option
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind * string) option
  ; attention_needs_attention : bool
  ; attention_reason : string option
  ; attention_next_human_action : string option
  ; terminal_next_human_action : string option
  }

type t =
  { disposition : string
  ; disposition_reason : string
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind * string) option
  ; needs_attention : bool
  ; attention_reason : string option
  ; next_human_action : string option
  }

let fallback_disposition raw =
  match raw.approval_queue with
  | Approval_queue_unavailable -> "Alert", "approval_queue_unavailable"
  | Approval_queue_available pending_approval_count when pending_approval_count > 0 ->
    "Alert", "pending_operator_decision"
  | Approval_queue_available _ ->
    (match raw.runtime_blocker_class with
     | Some Keeper_status_bridge_blocker.Blocked_by_runtime_exhaustion ->
       "Alert", "runtime_exhausted"
     | Some Keeper_status_bridge_blocker.Blocked_by_unresolved_fiber ->
       "Alert", "critical_block"
     (* These seven read as unknown because the class used to reach this
        module as a string decoded against [Keeper_meta_contract.blocker_class],
        which spells only the two above. The reason they should show is a
        display decision of its own (#43018); this keeps what operators see. *)
     | Some
         ( Keeper_status_bridge_blocker.Blocked_by_heartbeat_failures
         | Keeper_status_bridge_blocker.Blocked_by_turn_failures
         | Keeper_status_bridge_blocker.Blocked_by_provider_runtime_error
         | Keeper_status_bridge_blocker.Blocked_by_official_client_recovery
         | Keeper_status_bridge_blocker.Blocked_by_turn_configuration_error
         | Keeper_status_bridge_blocker.Blocked_by_exception
         | Keeper_status_bridge_blocker.Blocked_by_operator_interrupt ) ->
       "Alert", "unknown_runtime_blocker"
     | None -> "Pass", "healthy")
;;

let display_disposition_requires_attention = function
  | "Blocked" | "Pause" | "Alert" -> true
  | _ -> false
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
      Keeper_operator_disposition_display.of_kind
        ~operator_disposition_reason:operator_reason
        operator_disposition
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
  ; receipt_operator_disposition
  ; needs_attention
  ; attention_reason
  ; next_human_action
  }
;;
