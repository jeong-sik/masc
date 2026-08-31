(* TEL-OK: concrete wake-delivery receipts are returned to [Schedule_runner];
   the server maintenance loop logs aggregate dispatch counts for runtime
   telemetry. *)

let supported_payload_kinds = Schedule_payload_projection.supported_payload_kinds
let keeper_wake_enqueued_kind = "masc.keeper_wake.enqueued"
let keeper_event_queue_label = "keeper_event_queue"
let reaction_ledger_recorded_label = "recorded"
let reaction_ledger_record_failed_label = "record_failed"

let ( let* ) = Result.bind

let terminal_dispatch_result result =
  Result.map_error
    (fun detail -> Schedule_runner.Terminal_dispatch_rejection detail)
    result
;;

let unsupported_payload_labels ~phase = [ "phase", phase ]

let record_unsupported_payload_dispatch _request rejection =
  match rejection with
  | Schedule_payload_projection.Dispatch_unsupported_kind _ ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_schedule_payload_unsupported_total
      ~labels:(unsupported_payload_labels ~phase:"dispatch")
      ()
  | Schedule_payload_projection.Dispatch_invalid_payload _
  | Schedule_payload_projection.Dispatch_invalid_supported_payload _ -> ()
;;

(* Consumer-local: rejects blank strings, so only the raw field lookup is
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

let keeper_queue_urgency_of_schedule_urgency = function
  | Schedule_supported_kinds.Keeper_wake_immediate -> Keeper_event_queue.Immediate
  | Schedule_supported_kinds.Keeper_wake_normal -> Keeper_event_queue.Normal
  | Schedule_supported_kinds.Keeper_wake_low -> Keeper_event_queue.Low
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
  | Keeper_wake_already_failed
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
  | Keeper_wake_already_failed -> "already_failed"
  | Keeper_wake_already_cancelled -> "already_cancelled"
;;

let keeper_wake_occurrence_status_of_string = function
  | "awaiting_ack" -> Ok Keeper_wake_awaiting_ack
  | "already_acked" -> Ok Keeper_wake_already_acked
  | "already_failed" -> Ok Keeper_wake_already_failed
  | "already_cancelled" -> Ok Keeper_wake_already_cancelled
  | value -> Error ("unsupported occurrence_status: " ^ value)
;;

type keeper_wake_activation_deferred_reason =
  | Keeper_wake_activation_lifecycle_denied of string
  | Keeper_wake_activation_autoboot_disabled
  | Keeper_wake_activation_proactive_disabled
  | Keeper_wake_activation_shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Keeper_wake_activation_owner_unknown of string
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
  | "unregistered", None -> Ok Keeper_wake_activation_unregistered
  | "not_running", Some phase ->
    (match Keeper_state_machine.phase_of_string phase with
     | Some phase -> Ok (Keeper_wake_activation_not_running phase)
     | None -> Error ("unsupported activation_detail phase: " ^ phase))
  | ( "lifecycle_denied"
    | "shutdown_fenced"
    | "owner_unknown"
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

let dispatch_receipt_of_detail = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    if String.equal kind keeper_wake_enqueued_kind
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
          | Keeper_wake_already_failed
          | Keeper_wake_already_cancelled ),
          Keeper_wake_activation_not_required ->
          Ok ()
        | ( Keeper_wake_already_acked
          | Keeper_wake_already_failed
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
;;

let accepts request =
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Ok (_kind, _payload) -> Ok ()
  | Error rejection ->
    record_unsupported_payload_dispatch request rejection;
    Error (Schedule_payload_projection.dispatch_rejection_message rejection)
;;

let body_keeper_name payload =
  let* keeper_name =
    Schedule_payload_projection.body_required_string payload "keeper_name"
  in
  if Schedule_supported_kinds.valid_keeper_wake_target_name keeper_name
  then Ok keeper_name
  else
    Error
      (Schedule_supported_kinds.keeper_wake_target_name_error ~field:"keeper_name")
;;

(** Resolve the schedule payload boundary to the canonical Keeper name once.
    Exact Keeper-name ownership wins; only an absent exact owner is considered
    as an [agent_name] binding. Ambiguity and storage failures remain errors so
    a due occurrence is retained instead of being enqueued under the wrong
    durable owner. *)
let resolve_keeper_wake_target config requested_name =
  let base_path = config.Workspace_utils.base_path in
  match Keeper_registry.get ~base_path requested_name with
  | Some _ -> Ok requested_name
  | None ->
    (match Keeper_meta_store.read_meta config requested_name with
     | Error detail ->
       Error
         (Printf.sprintf
            "scheduled keeper wake target metadata read failed target=%s: %s"
            requested_name
            detail)
     | Ok (Some _) -> Ok requested_name
     | Ok None -> Ok requested_name)
;;

let body_keeper_wake_urgency payload =
  let* raw = Schedule_payload_projection.body_optional_string payload "urgency" in
  match raw with
  | None -> Ok None
  | Some value ->
    let* urgency = Schedule_supported_kinds.keeper_wake_urgency_of_string value in
    Ok (Some urgency)
;;

let record_keeper_wake_stimulus ~base_path ~keeper_name stimulus =
  try
    Keeper_reaction_ledger.record_event_queue_stimulus ~base_path ~keeper_name stimulus;
    Keeper_wake_reaction_ledger_recorded
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Keeper_wake_reaction_ledger_record_failed
      (Printf.sprintf
         "failed to persist keeper reaction ledger stimulus: %s"
         (Printexc.to_string exn))
;;

let ensure_keeper_wake_stimulus_recorded
      ~base_path
      ~keeper_name
      ~stimulus_id
      stimulus
  =
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Ok (Keeper_reaction_ledger.Evidence_complete { stimulus_seen = true; _ }) ->
    Keeper_wake_reaction_ledger_recorded
  | Ok (Keeper_reaction_ledger.Evidence_complete { stimulus_seen = false; _ }) ->
    record_keeper_wake_stimulus ~base_path ~keeper_name stimulus
  | Ok (Keeper_reaction_ledger.Evidence_quarantined { first_reason; _ }) ->
    Keeper_wake_reaction_ledger_record_failed
      (Printf.sprintf
         "scheduled keeper reaction ledger evidence is quarantined: %s"
         (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason))
  | Error error ->
    Keeper_wake_reaction_ledger_record_failed
      (Printf.sprintf
         "failed to read scheduled keeper reaction ledger evidence: %s"
         (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
            error))
;;

type keeper_wake_acceptance =
  | Wake_required
  | Already_pending of string
  | Already_acked
  | Already_failed of string
  | Already_cancelled

let activation_deferred_of_paused_dead = function
  | Keeper_activation_readiness.Persisted_lifecycle_denied denial ->
    Keeper_wake_activation_lifecycle_denied
      (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
  | Keeper_activation_readiness.Runtime_terminal phase ->
    Keeper_wake_activation_lifecycle_denied
      ("runtime_" ^ Keeper_state_machine.phase_to_string phase)
;;

let activation_outcome_for_required_wake config ~base_path ~keeper_name =
  match
    Executor_pool_ref.submit_strict (fun () ->
      match Keeper_meta_store.read_effective_meta config keeper_name with
      | Ok (Some meta) -> Ok meta
      | Ok None -> Error "durable keeper metadata missing"
      | Error detail -> Error detail)
  with
  | Error (Executor_pool_ref.Work_failed failure) ->
    Keeper_wake_activation_deferred
      (Keeper_wake_activation_owner_unknown
         ("durable keeper metadata read failed: "
          ^ Executor_pool_ref.strict_submit_error_to_string
              (Executor_pool_ref.Work_failed failure)))
  | Error error ->
    Keeper_wake_activation_deferred
      (Keeper_wake_activation_owner_unknown
         ("durable keeper metadata read unavailable: "
          ^ Executor_pool_ref.strict_submit_error_to_string error))
  | Ok meta_result ->
    let admission =
      Keeper_owner_registry.shutdown_operation_id ~base_path ~keeper_name
    in
    let runtime =
      Keeper_activation_readiness.owner_runtime_of_registry_entry
        (Keeper_registry.get ~base_path keeper_name)
    in
    (match admission with
     | Error error ->
       Keeper_wake_activation_deferred
         (Keeper_wake_activation_owner_unknown
            (Keeper_owner_registry.lookup_error_to_string error))
     | Ok shutdown_operation_id ->
    (match
       Keeper_activation_readiness.classify_durable_demand_execution
         ~shutdown_operation_id
         ~runtime
         meta_result
     with
     | Keeper_activation_readiness.Retained_disabled
         Keeper_activation_readiness.Retained_autoboot_disabled ->
       Keeper_wake_activation_deferred
         Keeper_wake_activation_autoboot_disabled
     | Keeper_activation_readiness.Retained_disabled
         Keeper_activation_readiness.Retained_proactive_disabled ->
       Keeper_wake_activation_deferred
         Keeper_wake_activation_proactive_disabled
     | Keeper_activation_readiness.Paused_dead reason ->
       Keeper_wake_activation_deferred
         (activation_deferred_of_paused_dead reason)
     | Keeper_activation_readiness.Shutdown_fenced operation_id ->
       Keeper_wake_activation_deferred
         (Keeper_wake_activation_shutdown_fenced operation_id)
     | Keeper_activation_readiness.Unknown detail ->
       Keeper_wake_activation_deferred
         (Keeper_wake_activation_owner_unknown detail)
     | Keeper_activation_readiness.Recoverable ->
       (match runtime with
        | Keeper_activation_readiness.Owner_unregistered ->
          Keeper_wake_activation_deferred Keeper_wake_activation_unregistered
        | Keeper_activation_readiness.Owner_registered { phase; _ } ->
          Keeper_wake_activation_deferred
            (Keeper_wake_activation_not_running phase))
     | Keeper_activation_readiness.Executable ->
       (match
          Keeper_registry.wakeup_running
            ~intent:Keeper_registry.Scheduled_signal
            ~base_path
            keeper_name
        with
        | Keeper_registry.Signaled -> Keeper_wake_activation_signaled
        | Keeper_registry.Deferred_unregistered ->
          Keeper_wake_activation_deferred Keeper_wake_activation_unregistered
        | Keeper_registry.Deferred_not_running phase ->
          Keeper_wake_activation_deferred
            (Keeper_wake_activation_not_running phase)
        | Keeper_registry.Deferred_lifecycle denial ->
          Keeper_wake_activation_deferred
            (Keeper_wake_activation_lifecycle_denied
               (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)))))
;;

let log_activation_outcome ~schedule_id ~keeper_name = function
  | Keeper_wake_activation_signaled
  | Keeper_wake_activation_not_required -> ()
  | Keeper_wake_activation_deferred reason ->
    let reason, detail = keeper_wake_activation_deferred_reason_fields reason in
    (match detail with
     | None ->
       Log.Keeper.info
         "schedule stimulus retained without owner activation schedule_id=%s keeper=%s reason=%s"
         schedule_id
         keeper_name
         reason
     | Some detail ->
       Log.Keeper.info
         "schedule stimulus retained without owner activation schedule_id=%s keeper=%s reason=%s detail=%s"
         schedule_id
         keeper_name
         reason
         detail)
;;

let retryable_dispatch_failure detail =
  Error (Schedule_runner.Retryable_dispatch_failure detail)
;;

let accept_with_recorded_stimulus
      ~base_path
      ~keeper_name
      ~stimulus_id
      stimulus
      acceptance
  =
  match
    ensure_keeper_wake_stimulus_recorded
      ~base_path
      ~keeper_name
      ~stimulus_id
      stimulus
  with
  | Keeper_wake_reaction_ledger_recorded -> Ok acceptance
  | Keeper_wake_reaction_ledger_record_failed detail ->
    retryable_dispatch_failure detail
;;

type durable_occurrence_state =
  | Pending
  | Transfer_projecting_to of string
  | Transferred_to of string
  | Terminally_completed of terminal_evidence_status
  | Terminally_failed of string * terminal_evidence_status
  | Cancelled of string * terminal_evidence_status

and terminal_evidence_status =
  | Terminal_evidence_pending of string
  | Terminal_evidence_recorded

type durable_occurrence_disposition =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; state : durable_occurrence_state
  }

type resolved_occurrence_disposition =
  | Pending_at of string * Keeper_event_queue.stimulus
  | Transfer_projecting_at of string * string
  | Terminal_completed_at of
      string * Keeper_event_queue.stimulus * terminal_evidence_status
  | Terminal_failed_at of
      string * Keeper_event_queue.stimulus * string * terminal_evidence_status
  | Terminal_cancelled_at of
      string * Keeper_event_queue.stimulus * string * terminal_evidence_status
  | Absent_at of string

let terminal_evidence_status_equal left right =
  match left, right with
  | Terminal_evidence_recorded, Terminal_evidence_recorded -> true
  | Terminal_evidence_pending left, Terminal_evidence_pending right ->
    String.equal left right
  | Terminal_evidence_recorded, Terminal_evidence_pending _
  | Terminal_evidence_pending _, Terminal_evidence_recorded -> false
;;

let occurrence_state_equal left right =
  match left, right with
  | Pending, Pending -> true
  | Terminally_completed left, Terminally_completed right ->
    terminal_evidence_status_equal left right
  | Terminally_failed (left_reason, left_evidence),
    Terminally_failed (right_reason, right_evidence)
  | Cancelled (left_reason, left_evidence),
    Cancelled (right_reason, right_evidence) ->
    String.equal left_reason right_reason
    && terminal_evidence_status_equal left_evidence right_evidence
  | Transfer_projecting_to left, Transfer_projecting_to right
  | Transferred_to left, Transferred_to right -> String.equal left right
  | ( Pending
    | Transfer_projecting_to _
    | Transferred_to _
    | Terminally_completed _
    | Terminally_failed _
    | Cancelled _ )
    , _ -> false
;;

let occurrence_source_and_disposition
      ~projecting
      (receipt : Keeper_event_queue_state.transition_receipt)
  =
  let terminal_evidence =
    if projecting
    then Terminal_evidence_pending receipt.transition_id
    else Terminal_evidence_recorded
  in
  match receipt.transition with
  | Keeper_event_queue_state.Cancel_accepted cancellation ->
    ( cancellation.source
    , { source = cancellation.source
      ; source_incarnation = cancellation.source_incarnation
      ; state = Cancelled (cancellation.reason, terminal_evidence)
      } )
  | Keeper_event_queue_state.Transfer_accepted transfer ->
    ( transfer.source
    , { source = transfer.source
      ; source_incarnation = transfer.source_incarnation
      ; state =
          (if projecting
           then Transfer_projecting_to transfer.to_keeper
           else Transferred_to transfer.to_keeper)
      } )
  | Keeper_event_queue_state.Ack_source_terminal terminal ->
    let state =
      match terminal.source_receipt with
      | Keeper_event_queue_state.Turn_attempt_terminal { detail } ->
        Terminally_failed (detail, terminal_evidence)
      | Keeper_event_queue_state.Fusion_terminal _
      | Keeper_event_queue_state.Hitl_terminal _
      | Keeper_event_queue_state.Turn_completed ->
        Terminally_completed terminal_evidence
    in
    ( terminal.source
    , { source = terminal.source
      ; source_incarnation = terminal.source_incarnation
      ; state
      } )
;;

let durable_occurrence_index state =
  let index = Hashtbl.create 16 in
  let add occurrence_id disposition =
    match Hashtbl.find_opt index occurrence_id with
    | None ->
      Hashtbl.add index occurrence_id disposition;
      Ok ()
    | Some existing ->
      let incarnation_order =
        Int64.compare disposition.source_incarnation existing.source_incarnation
      in
      if incarnation_order > 0
      then (
        Hashtbl.replace index occurrence_id disposition;
        Ok ())
      else if incarnation_order < 0
      then Ok ()
      else if existing.source = disposition.source
              && occurrence_state_equal existing.state disposition.state
      then Ok ()
      else
      Error
        (Printf.sprintf
           "conflicting durable queue dispositions for occurrence %s incarnation %Ld"
           occurrence_id
           disposition.source_incarnation)
  in
  let rec add_pending = function
    | [] -> Ok ()
    | (selection : Keeper_event_queue_state.pending_selection) :: rest ->
      let* () =
        add
          selection.source.post_id
          { source = selection.source
          ; source_incarnation = selection.admitted_revision
          ; state = Pending
          }
      in
      add_pending rest
  in
  let rec add_receipts ~projecting = function
    | [] -> Ok ()
    | receipt :: rest ->
      let source, disposition =
        occurrence_source_and_disposition ~projecting receipt
      in
      let* () = add source.post_id disposition in
      add_receipts ~projecting rest
  in
  let* () =
    Keeper_event_queue_state.pending_selections state
    |> add_pending
  in
  let* () =
    Keeper_event_queue_state.transition_outbox state
    |> List.map (fun (entry : Keeper_event_queue_state.outbox_entry) -> entry.receipt)
    |> add_receipts ~projecting:true
  in
  let* () =
    Keeper_event_queue_state.projected_transition_receipts state
    |> add_receipts ~projecting:false
  in
  Ok index
;;

let owner_index_result cache ~read_state ~base_path keeper_name =
  match Hashtbl.find_opt cache keeper_name with
  | Some result -> result
  | None ->
    let result =
      let* state =
        read_state ~base_path keeper_name
        |> Result.map_error (fun detail ->
          Printf.sprintf
            "scheduled keeper wake durable state read failed keeper=%s: %s"
            keeper_name
            detail)
      in
      durable_occurrence_index state
    in
    Hashtbl.add cache keeper_name result;
    result
;;

let rec resolve_durable_occurrence
          cache
          ~read_state
          ~base_path
          ~occurrence_id
          ~visited
          keeper_name
  =
  if List.exists (String.equal keeper_name) visited
  then Error ("durable queue transfer cycle at keeper " ^ keeper_name)
  else
    let* index = owner_index_result cache ~read_state ~base_path keeper_name in
    match Hashtbl.find_opt index occurrence_id with
    | None -> Ok (Absent_at keeper_name)
    | Some { source; state = Pending; _ } -> Ok (Pending_at (keeper_name, source))
    | Some { source; state = Terminally_completed evidence; _ } ->
      Ok (Terminal_completed_at (keeper_name, source, evidence))
    | Some { source; state = Terminally_failed (reason, evidence); _ } ->
      Ok (Terminal_failed_at (keeper_name, source, reason, evidence))
    | Some { source; state = Cancelled (reason, evidence); _ } ->
      Ok (Terminal_cancelled_at (keeper_name, source, reason, evidence))
    | Some { state = Transfer_projecting_to target; _ } ->
      (* The source outbox is the sole durable authority until projection
         retires it. Reading or activating the target here would turn a valid
         pre-commit absence into either false loss or a speculative wake. *)
      Ok (Transfer_projecting_at (keeper_name, target))
    | Some { state = Transferred_to target; _ } ->
      let target_was_cached = Hashtbl.mem cache target in
      let resolve_target () =
        resolve_durable_occurrence
          cache
          ~read_state
          ~base_path
          ~occurrence_id
          ~visited:(keeper_name :: visited)
          target
      in
      let* target_disposition = resolve_target () in
      (match target_disposition with
       | Absent_at _ when target_was_cached ->
         (* A transfer is marked projected only after the target commit. A
            cached target snapshot may predate that commit when the same batch
            resolved another occurrence first, so absence must be revalidated
            against a fresh target snapshot before it can become loss proof. *)
         Hashtbl.remove cache target;
         resolve_target ()
       | disposition -> Ok disposition)
;;

let resolved_occurrence_owner = function
  | Pending_at (owner, _)
  | Terminal_completed_at (owner, _, _)
  | Terminal_failed_at (owner, _, _, _)
  | Terminal_cancelled_at (owner, _, _, _)
  | Absent_at owner -> owner
  | Transfer_projecting_at (source, _) -> source
;;

let resolve_keeper_wake_occurrence ~base_path ~keeper_name ~stimulus_id =
  resolve_durable_occurrence
    (Hashtbl.create 4)
    ~read_state:Keeper_registry_event_queue.durable_state_result
    ~base_path
    ~occurrence_id:stimulus_id
    ~visited:[]
    keeper_name
;;

let accept_keeper_wake_occurrence
      ?intake_token
      ~base_path
      ~keeper_name
      ~expected_owner
      ~stimulus_id
      stimulus
  =
  let accept_terminal
        ~owner
        ~durable_stimulus
        ~evidence
        acceptance
    =
    let* () =
      match evidence with
      | Terminal_evidence_recorded -> Ok ()
      | Terminal_evidence_pending transition_id ->
        Keeper_reaction_ledger.project_event_queue_transition_outbox_result
          ~base_path
          ~keeper_name:owner
          ~expected_transition_id:transition_id
        |> Result.map_error (fun detail ->
          Schedule_runner.Retryable_dispatch_failure detail)
    in
    accept_with_recorded_stimulus
      ~base_path
      ~keeper_name:owner
      ~stimulus_id
      durable_stimulus
      acceptance
  in
  match
    resolve_keeper_wake_occurrence ~base_path ~keeper_name ~stimulus_id
  with
  | Error detail -> retryable_dispatch_failure detail
  | Ok disposition
    when not
           (String.equal
              expected_owner
              (resolved_occurrence_owner disposition)) ->
    retryable_dispatch_failure
      (Printf.sprintf
         "scheduled keeper wake owner changed while acquiring intake fence expected=%s actual=%s"
         expected_owner
         (resolved_occurrence_owner disposition))
  | Ok (Transfer_projecting_at (source, target)) ->
    retryable_dispatch_failure
      (Printf.sprintf
         "scheduled keeper wake transfer projection pending source=%s target=%s"
         source
         target)
  | Ok (Pending_at (owner, durable_stimulus)) ->
    (* A prior attempt may have committed the queue entry and then failed the
       independent reaction-ledger append. Verify the exact stimulus identity
       and repair only an absent row before reporting durable acceptance. *)
    accept_with_recorded_stimulus
      ~base_path
      ~keeper_name:owner
      ~stimulus_id
      durable_stimulus
      (Already_pending owner)
  | Ok (Terminal_completed_at (owner, durable_stimulus, evidence)) ->
    accept_terminal ~owner ~durable_stimulus ~evidence Already_acked
  | Ok (Terminal_failed_at (owner, durable_stimulus, reason, evidence)) ->
    accept_terminal
      ~owner
      ~durable_stimulus
      ~evidence
      (Already_failed reason)
  | Ok (Terminal_cancelled_at (owner, durable_stimulus, _, evidence)) ->
    accept_terminal ~owner ~durable_stimulus ~evidence Already_cancelled
  | Ok (Absent_at owner) when not (String.equal owner keeper_name) ->
    retryable_dispatch_failure
      (Printf.sprintf
         "scheduled keeper wake transferred owner is missing occurrence owner=%s occurrence=%s"
         owner
         stimulus_id)
  | Ok (Absent_at _) ->
    (match
       Keeper_registry_event_queue.enqueue_stimulus_durable_result
         ?intake_token
         ~base_path
         keeper_name
         stimulus
     with
     | Keeper_registry_event_queue.Stimulus_storage_error detail ->
       retryable_dispatch_failure
         ("scheduled keeper wake durable enqueue failed: " ^ detail)
     | Keeper_registry_event_queue.Stimulus_enqueued
     | Keeper_registry_event_queue.Stimulus_already_present ->
       (match record_keeper_wake_stimulus ~base_path ~keeper_name stimulus with
        | Keeper_wake_reaction_ledger_recorded -> Ok Wake_required
        | Keeper_wake_reaction_ledger_record_failed detail ->
          retryable_dispatch_failure detail))
;;

let dispatch_keeper_wake
      config
      ~now
      (signal : Schedule_runner.wake_signal)
      (request : Schedule_domain.schedule_request)
      ~commit_acceptance
      payload
  =
  let* requested_keeper_name = terminal_dispatch_result (body_keeper_name payload) in
  let base_path = config.Workspace_utils.base_path in
  let* keeper_name =
    match resolve_keeper_wake_target config requested_keeper_name with
    | Ok keeper_name -> Ok keeper_name
    | Error detail -> retryable_dispatch_failure detail
  in
  let* message =
    terminal_dispatch_result
      (Schedule_payload_projection.body_required_string payload "message")
  in
  let* title =
    terminal_dispatch_result
      (Schedule_payload_projection.body_optional_string payload "title")
  in
  let* result_delivery =
    terminal_dispatch_result
      (Schedule_payload_projection.body_result_delivery payload)
  in
  let* urgency = terminal_dispatch_result (body_keeper_wake_urgency payload) in
  let urgency =
    urgency
    (* DET-OK: absent masc.keeper_wake urgency is the schema-v1 default;
       invalid or unknown urgency strings are rejected above. *)
    |> Option.value ~default:Schedule_supported_kinds.default_keeper_wake_urgency
    |> keeper_queue_urgency_of_schedule_urgency
  in
  let wake : Keeper_event_queue.scheduled_wake =
    { occurrence_id = Schedule_occurrence_id.to_string signal.occurrence_id
    ; schedule_instance_id = request.Schedule_domain.schedule_instance_id
    ; schedule_id = request.Schedule_domain.schedule_id
    ; due_at = request.due_at
    ; payload_digest = Schedule_domain.payload_digest request.payload
    ; title
    ; message
    ; result_delivery
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = Schedule_occurrence_id.to_string signal.occurrence_id
    ; urgency
    ; arrived_at = now
    ; payload = Keeper_event_queue.Schedule_due wake
    }
  in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  let* initial_disposition =
    match resolve_keeper_wake_occurrence ~base_path ~keeper_name ~stimulus_id with
    | Ok disposition -> Ok disposition
    | Error detail -> retryable_dispatch_failure detail
  in
  let intake_owner = resolved_occurrence_owner initial_disposition in
  let dispatch_while_fenced intake_token =
    let* acceptance =
      accept_keeper_wake_occurrence
        ~intake_token
        ~base_path
        ~keeper_name
        ~expected_owner:intake_owner
        ~stimulus_id
        stimulus
    in
    let occurrence_status =
      match acceptance with
      | Wake_required | Already_pending _ -> Keeper_wake_awaiting_ack
      | Already_acked -> Keeper_wake_already_acked
      | Already_failed _ -> Keeper_wake_already_failed
      | Already_cancelled -> Keeper_wake_already_cancelled
    in
    let activation_outcome =
      match acceptance with
      | Already_acked | Already_failed _ | Already_cancelled ->
        Keeper_wake_activation_not_required
      | Wake_required ->
        activation_outcome_for_required_wake
          config
          ~base_path
          ~keeper_name
      | Already_pending owner ->
        activation_outcome_for_required_wake
          config
          ~base_path
          ~keeper_name:owner
    in
    let activation_keeper_name =
      match acceptance with
      | Already_pending owner -> owner
      | Wake_required | Already_acked | Already_failed _ | Already_cancelled ->
        keeper_name
    in
    let* () =
      match activation_outcome with
      | Keeper_wake_activation_deferred
          ((Keeper_wake_activation_not_running _) as reason) ->
        let reason_label, reason_detail =
          keeper_wake_activation_deferred_reason_fields reason
        in
        Log.Keeper.info
          "schedule stimulus retained; owner activation deferred, dispatch \
           will retry schedule_id=%s keeper=%s reason=%s%s"
          request.schedule_id
          activation_keeper_name
          reason_label
          (match reason_detail with
           | Some detail -> " detail=" ^ detail
           | None -> "");
        retryable_dispatch_failure
          (Printf.sprintf
             "scheduled keeper wake deferred owner-not-running \
              schedule_id=%s keeper=%s reason=%s%s"
             request.schedule_id
             activation_keeper_name
             reason_label
             (match reason_detail with
              | Some detail -> " detail=" ^ detail
              | None -> ""))
      | _ -> Ok ()
    in
    log_activation_outcome
      ~schedule_id:request.schedule_id
      ~keeper_name:activation_keeper_name
      activation_outcome;
    let detail =
      `Assoc
        ([ "kind", `String keeper_wake_enqueued_kind
         ; "queue", `String keeper_event_queue_label
         ; "stimulus", `String (Keeper_event_queue.payload_kind_label stimulus.payload)
         ; "stimulus_id", `String stimulus_id
         ; "keeper_name", `String keeper_name
         ; "schedule_instance_id", `String request.schedule_instance_id
         ; "schedule_id", `String request.schedule_id
         ; "urgency", `String (Keeper_event_queue.urgency_to_string urgency)
         ; "post_id", `String stimulus.post_id
         ; ( "result_delivery_policy"
           , `String
               (match result_delivery with
                | None -> "none"
                | Some _ -> "reply_to_origin") )
         ; ( "occurrence_status"
           , `String (keeper_wake_occurrence_status_to_string occurrence_status) )
         ]
         @ keeper_wake_activation_outcome_json_fields activation_outcome
         @ keeper_wake_reaction_ledger_status_json_fields
             (Some Keeper_wake_reaction_ledger_recorded))
    in
    match acceptance with
    | Wake_required
    | Already_pending _
    | Already_acked
    | Already_failed _
    | Already_cancelled ->
      let* acceptance_commit = commit_acceptance detail in
      Ok (Schedule_runner.Work_accepted { detail; acceptance_commit })
  in
  match
    Keeper_shutdown_intake_fence.run_durable_intake_if_open
      ~base_path
      ~keeper_name:intake_owner
      dispatch_while_fenced
  with
  | Keeper_shutdown_intake_fence.Intake_committed result -> result
  | Keeper_shutdown_intake_fence.Intake_shutdown_reserved operation_id ->
    retryable_dispatch_failure
      (Printf.sprintf
         "scheduled keeper wake rejected by shutdown fence keeper=%s operation=%s"
         intake_owner
         (Keeper_shutdown_types.Operation_id.to_string operation_id))
;;

let dispatch config ~now signal request ~commit_acceptance =
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Error rejection ->
    Error
      (Schedule_runner.Terminal_dispatch_rejection
         (Schedule_payload_projection.dispatch_rejection_message rejection))
  | Ok (kind, payload) ->
    (match kind with
     | Schedule_payload_projection.Keeper_wake ->
       dispatch_keeper_wake config ~now signal request ~commit_acceptance payload)
;;

let cancel_keeper_schedules config ~keeper_name =
  let should_cancel (request : Schedule_domain.schedule_request) =
    match Schedule_payload_projection.dispatch_view_detailed request with
    | Ok (Schedule_payload_projection.Keeper_wake, payload) ->
      (match body_keeper_name payload with
       | Error _ -> false
       | Ok target ->
         (match resolve_keeper_wake_target config target with
          | Ok resolved -> String.equal resolved keeper_name
          | Error detail ->
            Log.Keeper.warn
              "cancel_keeper_schedules: target resolution failed target=%s: %s"
              target
              detail;
            false))
    | Error _ -> false
  in
  Schedule_store.cancel_matching config ~should_cancel
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch }
