(* TEL-OK: concrete scheduled consumer details are returned to
   [Schedule_runner] and persisted as execution records; the server maintenance
   loop logs aggregate dispatch counts for runtime telemetry. *)

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

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = assoc_field name fields in
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

let optional_keeper_wake_urgency_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let* urgency =
      Schedule_supported_kinds.keeper_wake_urgency_of_string (String.trim value)
    in
    Ok (Some urgency)
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
  | Keeper_wake_already_cancelled

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
      ; schedule_id : string
      ; urgency : string
      ; post_id : string
      ; queue : string
      ; stimulus : string
      ; stimulus_id : string option
      ; reaction_ledger_status : keeper_wake_reaction_ledger_status option
      ; occurrence_status : keeper_wake_occurrence_status
      ; activation_outcome : keeper_wake_activation_outcome
      }

let dispatch_receipt_of_detail = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    if String.equal kind keeper_wake_enqueued_kind
    then
      let* keeper_name = keeper_name_field "keeper_name" fields in
      let* schedule_id = string_field "schedule_id" fields in
      let* urgency = string_field "urgency" fields in
      let* post_id = string_field "post_id" fields in
      let* queue = string_field "queue" fields in
      let* stimulus = string_field "stimulus" fields in
      let* stimulus_id = optional_string_field "stimulus_id" fields in
      let* reaction_ledger_status =
        keeper_wake_reaction_ledger_status_of_fields fields
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
        | (Keeper_wake_already_acked | Keeper_wake_already_cancelled),
          Keeper_wake_activation_not_required ->
          Ok ()
        | (Keeper_wake_already_acked | Keeper_wake_already_cancelled), _ ->
          Error "terminal occurrence requires activation_status=not_required"
      in
      Ok
        (Keeper_wake_enqueued
           { keeper_name
           ; schedule_id
           ; urgency
           ; post_id
           ; queue
           ; stimulus
           ; stimulus_id
           ; reaction_ledger_status
           ; occurrence_status
           ; activation_outcome
           })
    else Error ("unsupported schedule dispatch receipt kind: " ^ kind)
  | _ -> Error "schedule dispatch receipt detail must be an object"
;;

let dispatch_receipt_to_yojson = function
  | Keeper_wake_enqueued
      { keeper_name
      ; schedule_id
      ; urgency
      ; post_id
      ; queue
      ; stimulus
      ; stimulus_id
      ; reaction_ledger_status
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
       ; "schedule_id", `String schedule_id
       ; "urgency", `String urgency
       ; "post_id", `String post_id
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

type keeper_wake_acceptance =
  | Wake_required
  | Already_pending of string
  | Already_acked
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
      Keeper_turn_admission.snapshot_for ~base_path ~keeper_name
    in
    let runtime =
      Keeper_activation_readiness.owner_runtime_of_registry_entry
        (Keeper_registry.get ~base_path keeper_name)
    in
    (match
       Keeper_activation_readiness.classify_durable_demand_execution
         ~shutdown_operation_id:admission.snapshot_shutdown_operation_id
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
               (Keeper_lifecycle_admission.autonomous_denial_to_wire denial))))
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

type durable_occurrence_disposition =
  | Pending
  | Transfer_projecting_to of string
  | Transferred_to of string
  | Terminally_acked
  | Cancelled

type resolved_occurrence_disposition =
  | Pending_at of string
  | Terminal
  | Terminal_cancelled
  | Absent_at of string

let disposition_equal left right =
  match left, right with
  | Pending, Pending
  | Terminally_acked, Terminally_acked
  | Cancelled, Cancelled -> true
  | Transfer_projecting_to left, Transfer_projecting_to right
  | Transferred_to left, Transferred_to right -> String.equal left right
  | ( Pending
    | Transfer_projecting_to _
    | Transferred_to _
    | Terminally_acked
    | Cancelled )
    , _ -> false
;;

let occurrence_source_and_disposition
      ~projecting
      (receipt : Keeper_event_queue_state.transition_receipt)
  =
  match receipt.transition with
  | Keeper_event_queue_state.Cancel_accepted cancellation ->
    cancellation.source, Cancelled
  | Keeper_event_queue_state.Transfer_accepted transfer ->
    ( transfer.source
    , if projecting
      then Transfer_projecting_to transfer.to_keeper
      else Transferred_to transfer.to_keeper )
  | Keeper_event_queue_state.Ack_source_terminal terminal ->
    terminal.source, Terminally_acked
;;

let durable_occurrence_index state =
  let index = Hashtbl.create 16 in
  let add occurrence_id disposition =
    match Hashtbl.find_opt index occurrence_id with
    | None ->
      Hashtbl.add index occurrence_id disposition;
      Ok ()
    | Some existing when disposition_equal existing disposition -> Ok ()
    | Some _ ->
      Error
        (Printf.sprintf
           "conflicting durable queue dispositions for occurrence %s"
           occurrence_id)
  in
  let rec add_pending = function
    | [] -> Ok ()
    | (stimulus : Keeper_event_queue.stimulus) :: rest ->
      let* () = add stimulus.post_id Pending in
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
    Keeper_event_queue_state.pending state
    |> Keeper_event_queue.to_list
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

let owner_index_result cache ~base_path keeper_name =
  match Hashtbl.find_opt cache keeper_name with
  | Some result -> result
  | None ->
    let result =
      let* state =
        Keeper_registry_event_queue.durable_state_result ~base_path keeper_name
      in
      durable_occurrence_index state
    in
    Hashtbl.add cache keeper_name result;
    result
;;

let rec resolve_durable_occurrence
          cache
          ~base_path
          ~occurrence_id
          ~visited
          keeper_name
  =
  if List.exists (String.equal keeper_name) visited
  then Error ("durable queue transfer cycle at keeper " ^ keeper_name)
  else
    let* index = owner_index_result cache ~base_path keeper_name in
    match Hashtbl.find_opt index occurrence_id with
    | None -> Ok (Absent_at keeper_name)
    | Some Pending -> Ok (Pending_at keeper_name)
    | Some Terminally_acked -> Ok Terminal
    | Some Cancelled -> Ok Terminal_cancelled
    | Some (Transfer_projecting_to target) ->
      let* target_disposition =
        resolve_durable_occurrence
          cache
          ~base_path
          ~occurrence_id
          ~visited:(keeper_name :: visited)
          target
      in
      (match target_disposition with
       | Absent_at _ -> Ok (Pending_at target)
       | (Pending_at _ | Terminal | Terminal_cancelled) as disposition ->
         Ok disposition)
    | Some (Transferred_to target) ->
      resolve_durable_occurrence
        cache
        ~base_path
        ~occurrence_id
        ~visited:(keeper_name :: visited)
        target
;;

let accept_keeper_wake_occurrence
      ~base_path
      ~keeper_name
      ~stimulus_id
      stimulus
  =
  let cache = Hashtbl.create 4 in
  match
    resolve_durable_occurrence
      cache
      ~base_path
      ~occurrence_id:stimulus_id
      ~visited:[]
      keeper_name
  with
  | Error detail -> retryable_dispatch_failure detail
  | Ok Terminal -> Ok Already_acked
  | Ok Terminal_cancelled -> Ok Already_cancelled
  | Ok (Pending_at owner) -> Ok (Already_pending owner)
  | Ok (Absent_at _) ->
    (match
       Keeper_registry_event_queue.enqueue_stimulus_durable_result
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
      payload
  =
  let* keeper_name = terminal_dispatch_result (body_keeper_name payload) in
  let* message =
    terminal_dispatch_result
      (Schedule_payload_projection.body_required_string payload "message")
  in
  let* title =
    terminal_dispatch_result
      (Schedule_payload_projection.body_optional_string payload "title")
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
    { schedule_id = request.Schedule_domain.schedule_id
    ; due_at = request.due_at
    ; payload_digest = Schedule_domain.payload_digest request.payload
    ; title
    ; message
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
  let base_path = config.Workspace_utils.base_path in
  let* acceptance =
    accept_keeper_wake_occurrence ~base_path ~keeper_name ~stimulus_id stimulus
  in
  let occurrence_status =
    match acceptance with
    | Wake_required | Already_pending _ -> Keeper_wake_awaiting_ack
    | Already_acked -> Keeper_wake_already_acked
    | Already_cancelled -> Keeper_wake_already_cancelled
  in
  let activation_outcome =
    match acceptance with
    | Already_acked | Already_cancelled ->
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
    | Wake_required | Already_acked | Already_cancelled -> keeper_name
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
       ; "schedule_id", `String request.schedule_id
       ; "urgency", `String (Keeper_event_queue.urgency_to_string urgency)
       ; "post_id", `String stimulus.post_id
       ; ( "occurrence_status"
         , `String (keeper_wake_occurrence_status_to_string occurrence_status) )
       ]
       @ keeper_wake_activation_outcome_json_fields activation_outcome
       @ keeper_wake_reaction_ledger_status_json_fields
           (Some Keeper_wake_reaction_ledger_recorded))
  in
  match acceptance with
  | Wake_required | Already_pending _ -> Ok (Schedule_runner.Work_accepted detail)
  | Already_acked -> Ok (Schedule_runner.Work_completed detail)
  | Already_cancelled ->
    Ok
      (Schedule_runner.Work_failed
         { error =
             Printf.sprintf
               "scheduled keeper occurrence %s was already cancelled"
               stimulus_id
         ; detail
         })
;;

let dispatch config ~now signal request =
  match Schedule_payload_projection.dispatch_view_detailed request with
  | Error rejection ->
    Error
      (Schedule_runner.Terminal_dispatch_rejection
         (Schedule_payload_projection.dispatch_rejection_message rejection))
  | Ok (kind, payload) ->
    (match kind with
     | Schedule_payload_projection.Keeper_wake ->
       dispatch_keeper_wake config ~now signal request payload)
;;

let occurrence_stimulus_id (execution : Schedule_domain.execution_record) =
  Schedule_occurrence_id.make
    ~schedule_id:execution.schedule_id
    ~due_at:execution.due_at
    ~payload_digest:execution.payload_digest
  |> Schedule_occurrence_id.to_string
;;

let execution_keeper_name (execution : Schedule_domain.execution_record) =
  match execution.detail with
  | Some (`Assoc fields) -> keeper_name_field "keeper_name" fields
  | Some _ -> Error "schedule dispatch detail must be an object"
  | None -> Error "schedule dispatch detail is missing keeper_name"
;;

(* Exact producer snapshot -> durable owner chain. The mutable schedule request
   is deliberately absent: recurring requests may be edited after this
   occurrence was dispatched. Queue transition receipts retain every transfer
   and terminal disposition, so there is no reaction-ledger retention fallback
   and no elapsed-time guess. *)
let settlements config executions =
  let base_path = config.Workspace_utils.base_path in
  let cache = Hashtbl.create 8 in
  List.map
    (fun (execution : Schedule_domain.execution_record) ->
       let occurrence_id = occurrence_stimulus_id execution in
       let* keeper_name = execution_keeper_name execution in
       let* disposition =
         resolve_durable_occurrence
           cache
           ~base_path
           ~occurrence_id
           ~visited:[]
           keeper_name
       in
       match disposition with
       | Pending_at _ -> Ok Schedule_runner.Consumer_holds_occurrence
       | Terminal | Terminal_cancelled ->
         Ok Schedule_runner.Consumer_settled_occurrence
       | Absent_at owner ->
         Ok
           (Schedule_runner.Consumer_lost_occurrence
              (Printf.sprintf
                 "keeper %s has no pending or terminal durable disposition for scheduled wake %s"
                 owner
                 occurrence_id)))
    executions
;;

let consumer : Schedule_runner.consumer = { accepts; dispatch; settlements }
