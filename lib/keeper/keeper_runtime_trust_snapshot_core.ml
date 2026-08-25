type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class : string option
  ; runtime_blocker_summary : string option
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

let fallback_disposition raw =
  let sandbox_summary =
    match raw.runtime_blocker_summary with
    | Some summary when String_util.contains_substring_ci summary "sandbox" ->
      Some ("Alert", "sandbox_violation")
    | Some _ | None -> None
  in
  match raw.approval_queue with
  | Approval_queue_unavailable -> "Alert", "approval_queue_unavailable"
  | Approval_queue_available pending_approval_count when pending_approval_count > 0 ->
    "Alert", "pending_operator_decision"
  | Approval_queue_available _ ->
    (match raw.runtime_blocker_class with
     | Some raw_blocker_class ->
       (match
          Keeper_meta_contract.blocker_class_of_serialized_string raw_blocker_class
        with
        | Some (Keeper_meta_contract.Runtime_exhausted _) ->
          "Alert", "runtime_exhausted"
        | Some _ | None ->
          (match sandbox_summary with
           | Some disposition -> disposition
           | None -> "Alert", "critical_block"))
     | None ->
       (match sandbox_summary with
        | Some disposition -> disposition
        | None -> "Pass", "healthy"))
;;

let operator_disposition_of_display ~disposition ~disposition_reason =
  match disposition with
  | "Pass" -> "pass", disposition_reason
  | "Blocked" | "Pause" -> "fail_open_next_runtime", disposition_reason
  | "Alert" | _ -> "unknown", disposition_reason
;;

let display_disposition_requires_attention = function
  | "Blocked" | "Pause" | "Alert" -> true
  | _ -> false
;;

let effective_disposition raw ~fallback_disposition ~fallback_reason =
  match raw.approval_queue, raw.receipt_operator_disposition with
  | Approval_queue_available _, Some (operator_disposition, operator_reason) ->
    let disposition, disposition_reason =
      Keeper_operator_disposition_display.of_wire
        ~operator_disposition
        ~operator_disposition_reason:operator_reason
    in
    disposition, disposition_reason, operator_disposition, operator_reason
  | Approval_queue_unavailable, _
  | Approval_queue_available _, None ->
    let operator_disposition, operator_disposition_reason =
      operator_disposition_of_display
        ~disposition:fallback_disposition
        ~disposition_reason:fallback_reason
    in
    ( fallback_disposition
    , fallback_reason
    , operator_disposition
    , operator_disposition_reason )
;;

let decide raw =
  let fallback_disposition, fallback_reason = fallback_disposition raw in
  let disposition, disposition_reason, operator_disposition,
      operator_disposition_reason =
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
  ; operator_disposition
  ; operator_disposition_reason
  ; needs_attention
  ; attention_reason
  ; next_human_action
  }
;;
