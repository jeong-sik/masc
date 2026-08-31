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
  | Remove_meta

type dashboard_purge_context =
  { requested_name : string
  }

type cleanup_reason =
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Supervisor_cleanup
  | Dashboard_keeper_purge of dashboard_purge_context

type completion_action =
  | Supervisor_cleaned
  | Dashboard_keeper_purged

type dashboard_purge_artifact =
  | Keeper_metrics_store_artifact
  | Keeper_decision_log_artifact
  | Keeper_feedback_log_artifact
  | Keeper_runtime_directory_artifact
  | Keeper_memory_current_artifact
  | Keeper_memory_source_current_artifact
  | Keeper_memory_journal_artifact
  | Keeper_configuration_artifact
  | Keeper_chat_store_artifact
  | Agent_artifact_bundle of string list

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
  | Approval_summary_retirement
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
  ; meta_snapshot_digest : Keeper_meta_json.Snapshot_digest.t
  }

type finalization_evidence =
  { cleanup : cleanup_evidence
  ; meta_removed : bool
  ; session_removed : bool
  ; registry_unregistered : bool
  ; accumulator_dropped : bool
  ; completion : completion_receipt
  }

type supersession =
  | Operator_blocked_purge_released of { actor : string }
  | Operator_metadata_update of { actor : string }
  | Operator_reconciliation_accepted of
      { actor : string
      ; unreconciled_turn : active_turn
      }

type phase =
  | Prepared
  | Joining_lanes
  | Joined_idle
  | Finalizing_tasks of Keeper_id.Task_id.t list
  | Cleanup_ready of cleanup_evidence
  | Reconciliation_required of active_turn
  | Finalized of finalization_evidence
  | Blocked of failure
  | Superseded of supersession

type t =
  { schema_version : int
  ; revision : int
  ; operation_id : Operation_id.t
  ; keeper_name : string
  ; lane_ownership : lane_ownership
  ; trace_id : Keeper_id.Trace_id.t
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
  | Superseded_cleanup_reason_mismatch of cleanup_reason

let schema_version = 8

let requires_admission_fence operation =
  match operation.phase with
  | Finalized { completion = Completion_pending _; _ } -> true
  | Finalized
      { completion = (Completion_not_requested | Completion_delivered _); _ }
  | Superseded _ -> false
  | Prepared
  | Joining_lanes
  | Joined_idle
  | Finalizing_tasks _
  | Cleanup_ready _
  | Reconciliation_required _
  | Blocked _ -> true
;;

let cleanup_reason_label = function
  | Operator_stop_retain_meta -> "operator_stop_retain_meta"
  | Operator_stop_remove_meta -> "operator_stop_remove_meta"
  | Supervisor_cleanup -> "supervisor_cleanup"
  | Dashboard_keeper_purge _ -> "dashboard_keeper_purge"
;;

let meta_disposition_of_cleanup_reason = function
  | Operator_stop_retain_meta -> Retain_operator_pause
  | Supervisor_cleanup -> Remove_meta
  | Operator_stop_remove_meta
  | Dashboard_keeper_purge _ -> Remove_meta
;;

let completion_action_to_string = function
  | Supervisor_cleaned -> "supervisor_cleaned"
  | Dashboard_keeper_purged -> "dashboard_keeper_purged"
;;

let completion_action_of_string = function
  | "supervisor_cleaned" -> Ok Supervisor_cleaned
  | "dashboard_keeper_purged" -> Ok Dashboard_keeper_purged
  | value -> Error (Printf.sprintf "unknown Keeper shutdown completion action: %S" value)
;;

let completion_action_equal left right =
  match left, right with
  | Supervisor_cleaned, Supervisor_cleaned
  | Dashboard_keeper_purged, Dashboard_keeper_purged -> true
  | Supervisor_cleaned, Dashboard_keeper_purged
  | Dashboard_keeper_purged, Supervisor_cleaned -> false
;;

let completion_action_of_cleanup_reason = function
  | Supervisor_cleanup -> Some Supervisor_cleaned
  | Dashboard_keeper_purge _ -> Some Dashboard_keeper_purged
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
  | Superseded_cleanup_reason_mismatch cleanup_reason ->
    Printf.sprintf
      "shutdown supersession requires operator_stop_retain_meta, actual=%s"
      (cleanup_reason_label cleanup_reason)
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
        | Retain_operator_pause -> false
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
          | Registered_lane _, Dashboard_keeper_purge _ ->
            true
          | Registered_lane _,
            ( Operator_stop_retain_meta
            | Operator_stop_remove_meta
            | Supervisor_cleanup ) -> false
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
    | Superseded (Operator_metadata_update _ | Operator_reconciliation_accepted _) ->
      (match operation.cleanup_intent.reason with
       | Operator_stop_retain_meta -> Ok ()
       | ( Operator_stop_remove_meta
         | Supervisor_cleanup
         | Dashboard_keeper_purge _ ) as cleanup_reason ->
         Error (Superseded_cleanup_reason_mismatch cleanup_reason))
    | Superseded (Operator_blocked_purge_released _) ->
      (* The mirror of the arm above: this release exists only for a purge, so
         every other intent is as wrong here as a purge is there. *)
      (match operation.cleanup_intent.reason with
       | Dashboard_keeper_purge _ -> Ok ()
       | ( Operator_stop_retain_meta
         | Operator_stop_remove_meta
         | Supervisor_cleanup ) as cleanup_reason ->
         Error (Superseded_cleanup_reason_mismatch cleanup_reason))
    | Prepared
    | Joining_lanes
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

let dashboard_purge_context_equal
    (left : dashboard_purge_context)
    (right : dashboard_purge_context)
  =
  String.equal left.requested_name right.requested_name
;;

let cleanup_reason_equal left right =
  match left, right with
  | Operator_stop_retain_meta, Operator_stop_retain_meta
  | Operator_stop_remove_meta, Operator_stop_remove_meta
  | Supervisor_cleanup, Supervisor_cleanup -> true
  | Dashboard_keeper_purge left, Dashboard_keeper_purge right ->
    dashboard_purge_context_equal left right
  | Operator_stop_retain_meta,
    ( Operator_stop_remove_meta
    | Supervisor_cleanup
    | Dashboard_keeper_purge _ )
  | Operator_stop_remove_meta,
    ( Operator_stop_retain_meta
    | Supervisor_cleanup
    | Dashboard_keeper_purge _ )
  | Supervisor_cleanup,
    ( Operator_stop_retain_meta
    | Operator_stop_remove_meta
    | Dashboard_keeper_purge _ )
  | Dashboard_keeper_purge _,
    ( Operator_stop_retain_meta
    | Operator_stop_remove_meta
    | Supervisor_cleanup ) ->
    false
;;

let dashboard_purge_artifact_plan ~keeper_name context =
  let agent_aliases =
    [ context.requested_name; keeper_name ]
    |> List.filter_map String_util.trim_nonempty
    |> List.sort_uniq String.compare
  in
  [ Keeper_metrics_store_artifact
  ; Keeper_decision_log_artifact
  ; Keeper_feedback_log_artifact
  ; Keeper_runtime_directory_artifact
    (* Memory OS sidecars live next to the toml in the config keepers
       directory, outside the runtime directory removed above: without
       explicit entries a purged keeper leaves its ordinary/source-bound
       snapshots and journal behind, and a later keeper with the same name
       inherits them. *)
  ; Keeper_memory_current_artifact
  ; Keeper_memory_source_current_artifact
  ; Keeper_memory_journal_artifact
  ; Keeper_configuration_artifact
    (* The chat store is a top-level per-keeper file
       (.masc/keeper_chat/<name>.jsonl), so it sits outside the runtime
       directory removed above. Without an explicit entry a purged keeper
       leaves its conversation behind and a later keeper with the same name
       reads it as its own history. *)
  ; Keeper_chat_store_artifact
  ; Agent_artifact_bundle agent_aliases
  ]
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

(* Projection for status surfaces: the phase name only, no payload. A
   consumer waiting for the operation to reach a terminal reads this; the
   evidence carried by [Finalized]/[Cleanup_ready] stays in the record. *)
let phase_to_string = function
  | Prepared -> "prepared"
  | Joining_lanes -> "joining_lanes"
  | Joined_idle -> "joined_idle"
  | Finalizing_tasks _ -> "finalizing_tasks"
  | Cleanup_ready _ -> "cleanup_ready"
  | Reconciliation_required _ -> "reconciliation_required"
  | Finalized _ -> "finalized"
  | Blocked _ -> "blocked"
  | Superseded _ -> "superseded"
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
  | Approval_summary_retirement -> "approval_summary_retirement"
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
  | "approval_summary_retirement" -> Ok Approval_summary_retirement
  | "meta_update" -> Ok Meta_update
  | "meta_remove" -> Ok Meta_remove
  | "session_remove" -> Ok Session_remove
  | "registry_unregister" -> Ok Registry_unregister
  | value -> Error (Printf.sprintf "unknown Keeper shutdown failure stage: %S" value)
;;
