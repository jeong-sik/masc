module Operation_id = struct
  type t = string

  let prefix = "shutdown-"
  (* NDT-OK: UUID entropy is an operation identity only. No lifecycle
     decision branches on the generated contents. *)
  let rng = Random.State.make_self_init () (* NDT-OK: identity entropy only *)
  let rng_mutex = Eio.Mutex.create ()

  let generate () =
    let uuid = Eio.Mutex.use_ro rng_mutex (fun () -> Uuidm.v4_gen rng ()) in
    prefix ^ Uuidm.to_string uuid
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if
      String.length value = prefix_length + 36
      && String.equal (String.sub value 0 prefix_length) prefix
    then
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some _ -> Ok value
      | None -> Error (Printf.sprintf "invalid Keeper shutdown operation id: %S" value)
    else Error (Printf.sprintf "invalid Keeper shutdown operation id: %S" value)
  ;;

  let to_string value = value
  let equal = String.equal
end

type meta_disposition =
  | Retain_operator_pause
  | Retain_dead_tombstone
  | Remove_meta

type completion_action = Dead_tombstone_reaped

type completion_receipt =
  | Completion_not_requested
  | Completion_pending of completion_action
  | Completion_delivered of completion_action

type cleanup_intent =
  { meta_disposition : meta_disposition
  ; remove_session : bool
  }

type admission_lane =
  | Autonomous
  | Chat

type active_turn =
  { lane : admission_lane option
  ; admitted_at : float option
  ; observed_turn_id : int option
  ; observation_started_at : float option
  }

type turn_disposition =
  | No_inflight_turn
  | Inflight_effect_unknown of active_turn

type failure_stage =
  | Task_discovery
  | Record_persist
  | Turn_cancel
  | Lane_cancel
  | Turn_join
  | Lane_join
  | Record_update
  | Task_settlement
  | Pending_confirm_cleanup
  | Meta_update
  | Meta_remove
  | Session_remove
  | Registry_unregister

type failure =
  { stage : failure_stage
  ; detail : string
  }

type lane_outcome =
  | Lane_completed
  | Lane_shutdown_requested
  | Lane_cancelled_by_parent of string
  | Lane_failed of string

type terminal =
  | Terminal_stopped
  | Terminal_crashed of string

type join_evidence =
  { lane_outcome : lane_outcome
  ; terminal : terminal
  ; cleanup_error : string option
  }

type cleanup_evidence =
  { settled_task_ids : Keeper_id.Task_id.t list
  ; pending_confirms_removed : int
  }

type finalization_evidence =
  { cleanup : cleanup_evidence
  ; meta_removed : bool
  ; session_removed : bool
  ; registry_unregistered : bool
  ; completion : completion_receipt
  }

type phase =
  | Prepared
  | Joined_idle
  | Finalizing_tasks of Keeper_id.Task_id.t list
  | Cleanup_ready of cleanup_evidence
  | Reconciliation_required of active_turn
  | Finalized of finalization_evidence
  | Blocked of failure

type t =
  { schema_version : int
  ; revision : int
  ; operation_id : Operation_id.t
  ; keeper_name : string
  ; lane_id : Keeper_lane.Id.t
  ; trace_id : Keeper_id.Trace_id.t
  ; generation : int
  ; actor : string
  ; cleanup_intent : cleanup_intent
  ; turn_disposition : turn_disposition
  ; expected_backlog_version : int
  ; owned_task_ids : Keeper_id.Task_id.t list
  ; join_evidence : join_evidence option
  ; phase : phase
  ; created_at : string
  ; updated_at : string
  }

type invariant_error =
  | Schema_version_mismatch of
      { expected_schema_version : int
      ; actual_schema_version : int
      }
  | Finalized_meta_removed_mismatch of
      { expected_meta_removed : bool
      ; actual_meta_removed : bool
      }
  | Finalized_session_removed_mismatch of
      { expected_session_removed : bool
      ; actual_session_removed : bool
      }
  | Finalized_completion_mismatch of meta_disposition * completion_receipt

let schema_version = 3

let meta_disposition_to_string = function
  | Retain_operator_pause -> "retain_operator_pause"
  | Retain_dead_tombstone -> "retain_dead_tombstone"
  | Remove_meta -> "remove_meta"
;;

let meta_disposition_of_string = function
  | "retain_operator_pause" -> Ok Retain_operator_pause
  | "retain_dead_tombstone" -> Ok Retain_dead_tombstone
  | "remove_meta" -> Ok Remove_meta
  | value -> Error (Printf.sprintf "unknown Keeper shutdown meta disposition: %S" value)
;;

let completion_action_to_string = function
  | Dead_tombstone_reaped -> "dead_tombstone_reaped"
;;

let completion_action_of_string = function
  | "dead_tombstone_reaped" -> Ok Dead_tombstone_reaped
  | value -> Error (Printf.sprintf "unknown Keeper shutdown completion action: %S" value)
;;

let completion_receipt_kind = function
  | Completion_not_requested -> "not_requested"
  | Completion_pending _ -> "pending"
  | Completion_delivered _ -> "delivered"
;;

let invariant_error_to_string = function
  | Schema_version_mismatch
      { expected_schema_version; actual_schema_version } ->
    Printf.sprintf
      "shutdown schema version mismatch: expected %d, actual %d"
      expected_schema_version
      actual_schema_version
  | Finalized_meta_removed_mismatch
      { expected_meta_removed; actual_meta_removed } ->
    Printf.sprintf
      "shutdown finalized meta evidence mismatch: expected removed=%b, actual=%b"
      expected_meta_removed
      actual_meta_removed
  | Finalized_session_removed_mismatch
      { expected_session_removed; actual_session_removed } ->
    Printf.sprintf
      "shutdown finalized session evidence mismatch: expected removed=%b, actual=%b"
      expected_session_removed
      actual_session_removed
  | Finalized_completion_mismatch (meta_disposition, completion) ->
    Printf.sprintf
      "shutdown finalized completion mismatch: meta_disposition=%s, completion=%s"
      (meta_disposition_to_string meta_disposition)
      (completion_receipt_kind completion)
;;

let validate operation =
  if not (Int.equal operation.schema_version schema_version)
  then
    Error
      (Schema_version_mismatch
         { expected_schema_version = schema_version
         ; actual_schema_version = operation.schema_version
         })
  else
    match operation.phase with
    | Finalized evidence ->
      let expected_meta_removed =
        match operation.cleanup_intent.meta_disposition with
        | Remove_meta -> true
        | Retain_operator_pause
        | Retain_dead_tombstone -> false
      in
      if not (Bool.equal evidence.meta_removed expected_meta_removed)
      then
        Error
          (Finalized_meta_removed_mismatch
             { expected_meta_removed
             ; actual_meta_removed = evidence.meta_removed
             })
      else if
        not
          (Bool.equal
             evidence.session_removed
             operation.cleanup_intent.remove_session)
      then
        Error
          (Finalized_session_removed_mismatch
             { expected_session_removed = operation.cleanup_intent.remove_session
             ; actual_session_removed = evidence.session_removed
             })
      else
        (match operation.cleanup_intent.meta_disposition, evidence.completion with
         | Retain_dead_tombstone,
           (Completion_pending Dead_tombstone_reaped
           | Completion_delivered Dead_tombstone_reaped)
         | (Retain_operator_pause | Remove_meta), Completion_not_requested -> Ok ()
         | meta_disposition, completion ->
           Error (Finalized_completion_mismatch (meta_disposition, completion)))
    | Prepared
    | Joined_idle
    | Finalizing_tasks _
    | Cleanup_ready _
    | Reconciliation_required _
    | Blocked _ -> Ok ()
;;

let admission_lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

let admission_lane_of_string = function
  | "autonomous" -> Ok Autonomous
  | "chat" -> Ok Chat
  | value -> Error (Printf.sprintf "unknown Keeper shutdown admission lane: %S" value)
;;

let failure_stage_to_string = function
  | Task_discovery -> "task_discovery"
  | Record_persist -> "record_persist"
  | Turn_cancel -> "turn_cancel"
  | Lane_cancel -> "lane_cancel"
  | Turn_join -> "turn_join"
  | Lane_join -> "lane_join"
  | Record_update -> "record_update"
  | Task_settlement -> "task_settlement"
  | Pending_confirm_cleanup -> "pending_confirm_cleanup"
  | Meta_update -> "meta_update"
  | Meta_remove -> "meta_remove"
  | Session_remove -> "session_remove"
  | Registry_unregister -> "registry_unregister"
;;

let failure_stage_of_string = function
  | "task_discovery" -> Ok Task_discovery
  | "record_persist" -> Ok Record_persist
  | "turn_cancel" -> Ok Turn_cancel
  | "lane_cancel" -> Ok Lane_cancel
  | "turn_join" -> Ok Turn_join
  | "lane_join" -> Ok Lane_join
  | "record_update" -> Ok Record_update
  | "task_settlement" -> Ok Task_settlement
  | "pending_confirm_cleanup" -> Ok Pending_confirm_cleanup
  | "meta_update" -> Ok Meta_update
  | "meta_remove" -> Ok Meta_remove
  | "session_remove" -> Ok Session_remove
  | "registry_unregister" -> Ok Registry_unregister
  | value -> Error (Printf.sprintf "unknown Keeper shutdown failure stage: %S" value)
;;
