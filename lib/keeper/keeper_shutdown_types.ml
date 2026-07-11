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

type stale_paused_context =
  { meta_version : int
  ; last_updated : string
  ; latched_reason : Keeper_latched_reason.t option
  }

type cleanup_reason =
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup
  | Stale_paused_prune of stale_paused_context

type completion_action =
  | Dead_tombstone_reaped
  | Paused_meta_pruned

type completion_receipt =
  | Completion_not_requested
  | Completion_pending of completion_action
  | Completion_delivered of completion_action

type cleanup_intent =
  { reason : cleanup_reason
  ; remove_session : bool
  }

type lane_ownership =
  | Registered_lane of Keeper_lane.Id.t
  | Dormant_meta

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
  | Unhandled_worker
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
  ; accumulator_dropped : bool
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
  ; lane_ownership : lane_ownership
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
  | Required_accumulator_not_dropped
  | Finalized_completion_mismatch of cleanup_reason * completion_receipt

let schema_version = 4

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

let cleanup_reason_label = function
  | Operator_stop_retain_meta -> "operator_stop_retain_meta"
  | Operator_stop_remove_meta -> "operator_stop_remove_meta"
  | Dead_tombstone_cleanup -> "dead_tombstone_cleanup"
  | Stale_paused_prune _ -> "stale_paused_prune"
;;

let meta_disposition_of_cleanup_reason = function
  | Operator_stop_retain_meta -> Retain_operator_pause
  | Dead_tombstone_cleanup -> Retain_dead_tombstone
  | Operator_stop_remove_meta
  | Stale_paused_prune _ -> Remove_meta
;;

let completion_action_to_string = function
  | Dead_tombstone_reaped -> "dead_tombstone_reaped"
  | Paused_meta_pruned -> "paused_meta_pruned"
;;

let completion_action_of_string = function
  | "dead_tombstone_reaped" -> Ok Dead_tombstone_reaped
  | "paused_meta_pruned" -> Ok Paused_meta_pruned
  | value -> Error (Printf.sprintf "unknown Keeper shutdown completion action: %S" value)
;;

let completion_action_equal left right =
  match left, right with
  | Dead_tombstone_reaped, Dead_tombstone_reaped
  | Paused_meta_pruned, Paused_meta_pruned -> true
  | Dead_tombstone_reaped, Paused_meta_pruned
  | Paused_meta_pruned, Dead_tombstone_reaped -> false
;;

let completion_action_of_cleanup_reason = function
  | Dead_tombstone_cleanup -> Some Dead_tombstone_reaped
  | Stale_paused_prune _ -> Some Paused_meta_pruned
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta -> None
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
  | Required_accumulator_not_dropped ->
    "shutdown finalized cleanup without dropping its required tool accumulator"
  | Finalized_completion_mismatch (cleanup_reason, completion) ->
    Printf.sprintf
      "shutdown finalized completion mismatch: cleanup_reason=%s, completion=%s"
      (cleanup_reason_label cleanup_reason)
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
        match meta_disposition_of_cleanup_reason operation.cleanup_intent.reason with
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
        let accumulator_drop_required =
          match operation.lane_ownership, operation.cleanup_intent.reason with
          | Dormant_meta, _
          | Registered_lane _, Stale_paused_prune _ -> true
          | Registered_lane _,
            ( Operator_stop_retain_meta
            | Operator_stop_remove_meta
            | Dead_tombstone_cleanup ) -> false
        in
        if accumulator_drop_required && not evidence.accumulator_dropped
        then Error Required_accumulator_not_dropped
        else
        (match
           completion_action_of_cleanup_reason operation.cleanup_intent.reason,
           evidence.completion
         with
         | None, Completion_not_requested -> Ok ()
         | Some expected, Completion_pending actual
         | Some expected, Completion_delivered actual
           when completion_action_equal expected actual -> Ok ()
         | (None | Some _), completion ->
           Error
             (Finalized_completion_mismatch
                (operation.cleanup_intent.reason, completion)))
    | Prepared
    | Joined_idle
    | Finalizing_tasks _
    | Cleanup_ready _
    | Reconciliation_required _
    | Blocked _ -> Ok ()
;;

let option_equal equal left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> equal left right
  | None, Some _
  | Some _, None -> false
;;

let admission_lane_equal left right =
  match left, right with
  | Autonomous, Autonomous
  | Chat, Chat -> true
  | Autonomous, Chat
  | Chat, Autonomous -> false
;;

let active_turn_equal left right =
  option_equal admission_lane_equal left.lane right.lane
  && option_equal Float.equal left.admitted_at right.admitted_at
  && option_equal Int.equal left.observed_turn_id right.observed_turn_id
  && option_equal Float.equal left.observation_started_at right.observation_started_at
;;

let turn_disposition_equal left right =
  match left, right with
  | No_inflight_turn, No_inflight_turn -> true
  | Inflight_effect_unknown left, Inflight_effect_unknown right ->
    active_turn_equal left right
  | No_inflight_turn, Inflight_effect_unknown _
  | Inflight_effect_unknown _, No_inflight_turn -> false
;;

let stale_paused_context_equal left right =
  Int.equal left.meta_version right.meta_version
  && String.equal left.last_updated right.last_updated
  && option_equal Keeper_latched_reason.equal left.latched_reason right.latched_reason
;;

let cleanup_reason_equal left right =
  match left, right with
  | Operator_stop_retain_meta, Operator_stop_retain_meta
  | Operator_stop_remove_meta, Operator_stop_remove_meta
  | Dead_tombstone_cleanup, Dead_tombstone_cleanup -> true
  | Stale_paused_prune left, Stale_paused_prune right ->
    stale_paused_context_equal left right
  | Operator_stop_retain_meta,
    (Operator_stop_remove_meta | Dead_tombstone_cleanup | Stale_paused_prune _)
  | Operator_stop_remove_meta,
    (Operator_stop_retain_meta | Dead_tombstone_cleanup | Stale_paused_prune _)
  | Dead_tombstone_cleanup,
    (Operator_stop_retain_meta | Operator_stop_remove_meta | Stale_paused_prune _)
  | Stale_paused_prune _,
    (Operator_stop_retain_meta | Operator_stop_remove_meta | Dead_tombstone_cleanup) ->
    false
;;

let cleanup_intent_equal left right =
  cleanup_reason_equal left.reason right.reason
  && Bool.equal left.remove_session right.remove_session
;;

let lane_ownership_equal left right =
  match left, right with
  | Registered_lane left, Registered_lane right -> Keeper_lane.Id.equal left right
  | Dormant_meta, Dormant_meta -> true
  | Registered_lane _, Dormant_meta
  | Dormant_meta, Registered_lane _ -> false
;;

let immutable_fields_equal left right =
  Int.equal left.schema_version right.schema_version
  && Operation_id.equal left.operation_id right.operation_id
  && String.equal left.keeper_name right.keeper_name
  && lane_ownership_equal left.lane_ownership right.lane_ownership
  && Keeper_id.Trace_id.equal left.trace_id right.trace_id
  && Int.equal left.generation right.generation
  && String.equal left.actor right.actor
  && cleanup_intent_equal left.cleanup_intent right.cleanup_intent
  && turn_disposition_equal left.turn_disposition right.turn_disposition
  && List.equal Keeper_id.Task_id.equal left.owned_task_ids right.owned_task_ids
  && String.equal left.created_at right.created_at
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
  | Unhandled_worker -> "unhandled_worker"
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
  | "unhandled_worker" -> Ok Unhandled_worker
  | "task_settlement" -> Ok Task_settlement
  | "pending_confirm_cleanup" -> Ok Pending_confirm_cleanup
  | "meta_update" -> Ok Meta_update
  | "meta_remove" -> Ok Meta_remove
  | "session_remove" -> Ok Session_remove
  | "registry_unregister" -> Ok Registry_unregister
  | value -> Error (Printf.sprintf "unknown Keeper shutdown failure stage: %S" value)
;;
