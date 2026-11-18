(* Schedule dispatch receipt codec. The receipt is the [detail] a schedule
   occurrence stores on its wake record when dispatch accepted it. It records
   what dispatch saw at that moment, never what happened afterwards.

   TEL-OK: pure decode and encode over JSON the caller already holds. *)

open Result.Syntax

let keeper_wake_enqueued_kind = "masc.keeper_wake.enqueued"
let lane_act_handed_over_kind = "masc.lane_act.handed_over"
let keeper_receipt_delivered_kind = "masc.keeper_receipt.delivered"
let keeper_event_queue_label = "keeper_event_queue"
let reaction_ledger_recorded_label = "recorded"
let reaction_ledger_record_failed_label = "record_failed"

(* Receipt-local: rejects blank strings, so only the raw field lookup is
   shared with the schedule domain. *)
let string_field name fields =
  let* value = Schedule_domain.assoc_field name fields in
  match value with
  | `String value when String.trim value <> "" -> Ok value
  | `String _ -> Error (name ^ " must be non-empty")
  | _ -> Error ("expected string field: " ^ name)
;;

let optional_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value "" then Ok None else Ok (Some value)
  | Some _ -> Error ("expected string field: " ^ name)
;;

let keeper_name_field name fields =
  let* value = string_field name fields in
  if Schedule_supported_kinds.valid_keeper_wake_target_name value
  then Ok value
  else Error (Schedule_supported_kinds.keeper_wake_target_name_error ~field:name)
;;

type keeper_wake_reaction_ledger_status =
  | Keeper_wake_reaction_ledger_recorded
  | Keeper_wake_reaction_ledger_record_failed of string

let keeper_wake_reaction_ledger_status_to_string = function
  | Keeper_wake_reaction_ledger_recorded -> reaction_ledger_recorded_label
  | Keeper_wake_reaction_ledger_record_failed _ -> reaction_ledger_record_failed_label
;;

let keeper_wake_reaction_ledger_error = function
  | Keeper_wake_reaction_ledger_recorded -> None
  | Keeper_wake_reaction_ledger_record_failed reason -> Some reason
;;

let keeper_wake_reaction_ledger_status_of_fields fields =
  let* status = optional_string_field "reaction_ledger_status" fields in
  let* detail = optional_string_field "reaction_ledger_error" fields in
  match status, detail with
  | None, None -> Ok None
  | Some value, None when String.equal value reaction_ledger_recorded_label ->
    Ok (Some Keeper_wake_reaction_ledger_recorded)
  | Some value, Some reason
    when String.equal value reaction_ledger_record_failed_label ->
    Ok (Some (Keeper_wake_reaction_ledger_record_failed reason))
  | Some value, _
    when not
      (String.equal value reaction_ledger_recorded_label
       || String.equal value reaction_ledger_record_failed_label) ->
    Error ("unsupported reaction_ledger_status: " ^ value)
  | None, Some _ ->
    Error "reaction_ledger_error requires reaction_ledger_status=record_failed"
  | Some value, Some _
    when String.equal value reaction_ledger_recorded_label ->
    Error "reaction_ledger_status=recorded requires reaction_ledger_error=null"
  | Some value, None
    when String.equal value reaction_ledger_record_failed_label ->
    Error "reaction_ledger_status=record_failed requires reaction_ledger_error"
  | Some _, _ -> Error "noncanonical reaction ledger receipt"
;;

let keeper_wake_reaction_ledger_status_json_fields = function
  | None -> [ "reaction_ledger_status", `Null; "reaction_ledger_error", `Null ]
  | Some status ->
    [ "reaction_ledger_status"
    , `String (keeper_wake_reaction_ledger_status_to_string status)
    ; ( "reaction_ledger_error"
      , match keeper_wake_reaction_ledger_error status with
        | None -> `Null
        | Some reason -> `String reason )
    ]
;;

type keeper_wake_occurrence_status =
  | Keeper_wake_awaiting_ack
  | Keeper_wake_already_acked
  | Keeper_wake_already_cancelled

type keeper_wake_result_delivery_policy =
  | Keeper_wake_result_delivery_none
  | Keeper_wake_result_delivery_reply_to_origin

let keeper_wake_result_delivery_policy_to_string = function
  | Keeper_wake_result_delivery_none -> "none"
  | Keeper_wake_result_delivery_reply_to_origin -> "reply_to_origin"
;;

let keeper_wake_result_delivery_policy_of_fields fields =
  let* policy = optional_string_field "result_delivery_policy" fields in
  match policy with
  | None -> Ok Keeper_wake_result_delivery_none
  | Some "none" -> Ok Keeper_wake_result_delivery_none
  | Some "reply_to_origin" -> Ok Keeper_wake_result_delivery_reply_to_origin
  | Some value -> Error ("unsupported result_delivery_policy: " ^ value)
;;

let keeper_wake_occurrence_status_to_string = function
  | Keeper_wake_awaiting_ack -> "awaiting_ack"
  | Keeper_wake_already_acked -> "already_acked"
  | Keeper_wake_already_cancelled -> "already_cancelled"
;;

let keeper_wake_occurrence_status_of_string = function
  | "awaiting_ack" -> Ok Keeper_wake_awaiting_ack
  | "already_acked" -> Ok Keeper_wake_already_acked
  | "already_cancelled" -> Ok Keeper_wake_already_cancelled
  | value -> Error ("unsupported occurrence_status: " ^ value)
;;

type keeper_wake_activation_deferred_reason =
  | Keeper_wake_activation_lifecycle_denied of string
  | Keeper_wake_activation_autoboot_disabled
  | Keeper_wake_activation_proactive_disabled
  | Keeper_wake_activation_shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Keeper_wake_activation_owner_unknown of string
  | Keeper_wake_activation_owner_not_current of string
  | Keeper_wake_activation_unregistered
  | Keeper_wake_activation_not_running of Keeper_state_machine.phase

type keeper_wake_activation_outcome =
  | Keeper_wake_activation_signaled
  | Keeper_wake_activation_deferred of keeper_wake_activation_deferred_reason
  | Keeper_wake_activation_not_required

let keeper_wake_activation_deferred_reason_fields = function
  | Keeper_wake_activation_lifecycle_denied detail ->
    "lifecycle_denied", Some detail
  | Keeper_wake_activation_autoboot_disabled -> "autoboot_disabled", None
  | Keeper_wake_activation_proactive_disabled -> "proactive_disabled", None
  | Keeper_wake_activation_shutdown_fenced operation_id ->
    ( "shutdown_fenced"
    , Some (Keeper_shutdown_types.Operation_id.to_string operation_id) )
  | Keeper_wake_activation_owner_unknown detail -> "owner_unknown", Some detail
  | Keeper_wake_activation_owner_not_current detail ->
    "owner_not_current", Some detail
  | Keeper_wake_activation_unregistered -> "unregistered", None
  | Keeper_wake_activation_not_running phase ->
    "not_running", Some (Keeper_state_machine.phase_to_string phase)
;;

let keeper_wake_activation_deferred_reason_of_fields fields =
  let* reason = string_field "activation_reason" fields in
  let* detail = optional_string_field "activation_detail" fields in
  match reason, detail with
  | "lifecycle_denied", Some detail ->
    Ok (Keeper_wake_activation_lifecycle_denied detail)
  | "autoboot_disabled", None -> Ok Keeper_wake_activation_autoboot_disabled
  | "proactive_disabled", None -> Ok Keeper_wake_activation_proactive_disabled
  | "shutdown_fenced", Some operation_id ->
    Keeper_shutdown_types.Operation_id.of_string operation_id
    |> Result.map (fun operation_id ->
      Keeper_wake_activation_shutdown_fenced operation_id)
  | "owner_unknown", Some detail ->
    Ok (Keeper_wake_activation_owner_unknown detail)
  | "owner_not_current", Some detail ->
    Ok (Keeper_wake_activation_owner_not_current detail)
  | "unregistered", None -> Ok Keeper_wake_activation_unregistered
  | "not_running", Some phase ->
    (match Keeper_state_machine.phase_of_string phase with
     | Some phase -> Ok (Keeper_wake_activation_not_running phase)
     | None -> Error ("unsupported activation_detail phase: " ^ phase))
  | ( "lifecycle_denied"
    | "shutdown_fenced"
    | "owner_unknown"
    | "owner_not_current"
    | "not_running" ), None ->
    Error ("activation_detail is required for activation_reason: " ^ reason)
  | ( "autoboot_disabled"
    | "proactive_disabled"
    | "unregistered" ), Some _ ->
    Error ("activation_detail must be null for activation_reason: " ^ reason)
  | reason, _ -> Error ("unsupported activation_reason: " ^ reason)
;;

let keeper_wake_activation_outcome_of_fields fields =
  let* status = string_field "activation_status" fields in
  let* reason = optional_string_field "activation_reason" fields in
  let* detail = optional_string_field "activation_detail" fields in
  match status, reason, detail with
  | "signaled", None, None -> Ok Keeper_wake_activation_signaled
  | "not_required", None, None -> Ok Keeper_wake_activation_not_required
  | "deferred", Some _, _ ->
    let* reason = keeper_wake_activation_deferred_reason_of_fields fields in
    Ok (Keeper_wake_activation_deferred reason)
  | ("signaled" | "not_required"), _, _ ->
    Error
      ("activation_status=" ^ status
       ^ " requires activation_reason=null and activation_detail=null")
  | "deferred", None, _ ->
    Error "activation_status=deferred requires activation_reason"
  | value, _, _ -> Error ("unsupported activation_status: " ^ value)
;;

let keeper_wake_activation_outcome_json_fields = function
  | Keeper_wake_activation_signaled ->
    [ "activation_status", `String "signaled"
    ; "activation_reason", `Null
    ; "activation_detail", `Null
    ]
  | Keeper_wake_activation_not_required ->
    [ "activation_status", `String "not_required"
    ; "activation_reason", `Null
    ; "activation_detail", `Null
    ]
  | Keeper_wake_activation_deferred reason ->
    let reason, detail = keeper_wake_activation_deferred_reason_fields reason in
    [ "activation_status", `String "deferred"
    ; "activation_reason", `String reason
    ; ( "activation_detail"
      , match detail with
        | None -> `Null
        | Some detail -> `String detail )
    ]
;;

type dispatch_receipt =
  | Keeper_wake_enqueued of
      { keeper_name : string
      ; schedule_instance_id : string
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string option
      ; reaction_ledger_status : keeper_wake_reaction_ledger_status option
      ; result_delivery_policy : keeper_wake_result_delivery_policy
      ; occurrence_status : keeper_wake_occurrence_status
      ; activation_outcome : keeper_wake_activation_outcome
      }
  | Lane_act_handed_over of
      { installation_id : string
      ; instance_id : string
      ; request_id : string
      ; schedule_instance_id : string
      ; schedule_id : string
      }
  | Keeper_receipt_delivered of
      { keeper_name : string
      ; schedule_instance_id : string
      ; schedule_id : string
      }

let dispatch_receipt_of_detail = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    if String.equal kind lane_act_handed_over_kind
    then
      let* installation_id = string_field "installation_id" fields in
      let* instance_id = string_field "instance_id" fields in
      let* request_id = string_field "request_id" fields in
      let* schedule_instance_id = string_field "schedule_instance_id" fields in
      let* schedule_id = string_field "schedule_id" fields in
      Ok
        (Lane_act_handed_over
           { installation_id; instance_id; request_id; schedule_instance_id; schedule_id })
    else if String.equal kind keeper_wake_enqueued_kind
    then
      let* keeper_name = keeper_name_field "keeper_name" fields in
      let* schedule_instance_id = string_field "schedule_instance_id" fields in
      let* schedule_id = string_field "schedule_id" fields in
      let* urgency = string_field "urgency" fields in
      let* post_id = string_field "post_id" fields in
      let* queue = string_field "queue" fields in
      let* stimulus = string_field "stimulus" fields in
      let* stimulus_id = optional_string_field "stimulus_id" fields in
      let* reaction_ledger_status =
        keeper_wake_reaction_ledger_status_of_fields fields
      in
      let* result_delivery_policy =
        keeper_wake_result_delivery_policy_of_fields fields
      in
      let* occurrence_status =
        let* value = string_field "occurrence_status" fields in
        keeper_wake_occurrence_status_of_string value
      in
      let* activation_outcome =
        keeper_wake_activation_outcome_of_fields fields
      in
      let* () =
        match occurrence_status, activation_outcome with
        | Keeper_wake_awaiting_ack,
          ( Keeper_wake_activation_signaled
          | Keeper_wake_activation_deferred _ ) ->
          Ok ()
        | Keeper_wake_awaiting_ack, Keeper_wake_activation_not_required ->
          Error "awaiting_ack occurrence requires an activation outcome"
        | ( Keeper_wake_already_acked
          | Keeper_wake_already_cancelled ),
          Keeper_wake_activation_not_required ->
          Ok ()
        | ( Keeper_wake_already_acked
          | Keeper_wake_already_cancelled ),
          _ ->
          Error "terminal occurrence requires activation_status=not_required"
      in
      Ok
        (Keeper_wake_enqueued
           { keeper_name
           ; schedule_instance_id
           ; schedule_id
           ; urgency
           ; post_id
           ; queue
           ; stimulus
           ; stimulus_id
           ; reaction_ledger_status
           ; result_delivery_policy
           ; occurrence_status
           ; activation_outcome
           })
    else if String.equal kind keeper_receipt_delivered_kind
    then
      let* keeper_name = keeper_name_field "keeper_name" fields in
      let* schedule_instance_id = string_field "schedule_instance_id" fields in
      let* schedule_id = string_field "schedule_id" fields in
      Ok (Keeper_receipt_delivered { keeper_name; schedule_instance_id; schedule_id })
    else Error ("unsupported schedule dispatch receipt kind: " ^ kind)
  | _ -> Error "schedule dispatch receipt detail must be an object"
;;

let dispatch_receipt_to_yojson = function
  | Keeper_wake_enqueued
      { keeper_name
      ; schedule_instance_id
      ; schedule_id
      ; urgency
      ; post_id
      ; queue
      ; stimulus
      ; stimulus_id
      ; reaction_ledger_status
      ; result_delivery_policy
      ; occurrence_status
      ; activation_outcome
      } ->
    `Assoc
      ([ "kind", `String keeper_wake_enqueued_kind
       ; "queue", `String queue
       ; "stimulus", `String stimulus
       ; ( "stimulus_id"
         , match stimulus_id with
           | None -> `Null
           | Some value -> `String value )
       ; "keeper_name", `String keeper_name
       ; "schedule_instance_id", `String schedule_instance_id
       ; "schedule_id", `String schedule_id
       ; "urgency", `String urgency
       ; "post_id", `String post_id
       ; ( "result_delivery_policy"
         , `String
             (keeper_wake_result_delivery_policy_to_string
                result_delivery_policy) )
       ; ( "occurrence_status"
         , `String (keeper_wake_occurrence_status_to_string occurrence_status) )
       ]
       @ keeper_wake_activation_outcome_json_fields activation_outcome
       @ keeper_wake_reaction_ledger_status_json_fields reaction_ledger_status)
  | Lane_act_handed_over
      { installation_id; instance_id; request_id; schedule_instance_id; schedule_id } ->
    `Assoc
      [ "kind", `String lane_act_handed_over_kind
      ; "installation_id", `String installation_id
      ; "instance_id", `String instance_id
      ; "request_id", `String request_id
      ; "schedule_instance_id", `String schedule_instance_id
      ; "schedule_id", `String schedule_id
      ]
  | Keeper_receipt_delivered { keeper_name; schedule_instance_id; schedule_id } ->
    `Assoc
      [ "kind", `String keeper_receipt_delivered_kind
      ; "keeper_name", `String keeper_name
      ; "schedule_instance_id", `String schedule_instance_id
      ; "schedule_id", `String schedule_id
      ]
;;
