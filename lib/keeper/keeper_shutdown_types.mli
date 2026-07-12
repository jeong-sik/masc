(** Durable types for one Keeper lifecycle cleanup operation. These records
    describe coordination only; task ownership remains authoritative in the
    Workspace backlog. *)

module Operation_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
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

type dashboard_purge_context =
  { requested_name : string
  ; agent_name : string
  ; meta_version : int
  }

type cleanup_reason =
  | Operator_stop_retain_meta
  | Operator_stop_remove_meta
  | Dead_tombstone_cleanup
  | Stale_paused_prune of stale_paused_context
  | Dashboard_keeper_purge of dashboard_purge_context

type completion_action =
  | Dead_tombstone_reaped
  | Paused_meta_pruned
  | Dashboard_keeper_purged

type dashboard_purge_artifact =
  | Keeper_metrics_artifact
  | Keeper_memory_bank_artifact
  | Keeper_generation_index_artifact
  | Keeper_policy_log_artifact
  | Keeper_decision_log_artifact
  | Keeper_feedback_log_artifact
  | Keeper_dataset_export_artifact
  | Keeper_runtime_directory_artifact
  | Keeper_configuration_artifact
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

val schema_version : int
val meta_disposition_to_string : meta_disposition -> string
val meta_disposition_of_string : string -> (meta_disposition, string) result
val meta_disposition_of_cleanup_reason : cleanup_reason -> meta_disposition
val completion_action_to_string : completion_action -> string
val completion_action_of_string : string -> (completion_action, string) result
val completion_action_of_cleanup_reason : cleanup_reason -> completion_action option
val cleanup_intent_equal : cleanup_intent -> cleanup_intent -> bool
val dashboard_purge_artifact_plan :
  keeper_name:string ->
  dashboard_purge_context ->
  dashboard_purge_artifact list
val invariant_error_to_string : invariant_error -> string
val validate : t -> (unit, invariant_error) result
val immutable_fields_equal : t -> t -> bool
(** Compare every operation field that must remain fixed across revision
    replacement. Progress fields ([revision], backlog version, join/finalization
    evidence, phase, and [updated_at]) are intentionally excluded. *)
val admission_lane_to_string : admission_lane -> string
val admission_lane_of_string : string -> (admission_lane, string) result
val failure_stage_to_string : failure_stage -> string
val failure_stage_of_string : string -> (failure_stage, string) result
