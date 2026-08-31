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
      (** The operator released a [Blocked] dashboard purge whose worker died
          before it finished. Like {!Operator_metadata_update} this carries no
          effect-duplication risk -- the work failed -- but it is not a
          metadata update: a purge leaves no metadata to update, and the
          admission fence it holds is what stops the purge being reissued.
          Kept apart so the durable record says which release was signed off.

          Without this the pair ([Blocked], [Dashboard_keeper_purge]) had no
          exit: the fence blocks meta materialization, {!val:resolve} needs
          that meta to build a purge target, and supersession refused any
          intent but [Operator_stop_retain_meta]. A worker that died in
          [Joining_lanes] left the Keeper permanently half-purged
          (RFC-0000 1.2 LAW 1 "No dead-end", the same law #25491 restored for
          [Reconciliation_required]). *)
  | Operator_metadata_update of { actor : string }
  | Operator_reconciliation_accepted of
      { actor : string
      ; unreconciled_turn : active_turn
      }
      (** The operator released a [Reconciliation_required] admission fence,
          taking responsibility for the possibility that [unreconciled_turn]'s
          external effects were already applied.

          Distinct from {!Operator_metadata_update} on purpose. Superseding a
          [Blocked] operation carries no effect-duplication risk — the work
          failed. Superseding a [Reconciliation_required] one does: the turn
          was in flight when the process ended without a lane receipt, so its
          tool calls may or may not have landed. The durable record must say
          which of the two an operator signed off on, and the prior phase is
          overwritten by [Superseded], so the turn is carried here. *)

type phase =
  | Prepared
  | Joining_lanes
      (** The durable shutdown worker has committed its intent to join the
          Keeper lane and its detached Librarian lane. This phase is visible
          for the full cooperative wait; no implicit duration limit is added.
          If the server process ends here, boot recovery preserves the
          admission fence as [Blocked Lane_join] because Librarian completion
          cannot be inferred from the process boundary. *)
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

val schema_version : int
val requires_admission_fence : t -> bool
val cleanup_reason_label : cleanup_reason -> string
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
val phase_to_string : phase -> string
(** Phase name only, for status surfaces. [keepalive_running] answers whether
    the Keeper fiber is up, which is a different question from whether its
    shutdown operation reached a terminal: a Keeper can read as stopped while
    the operation still sits in [Finalizing_tasks] or [Cleanup_ready], and
    those phases are outside the supersedable set, so a restart is refused
    (#29181). *)


val failure_stage_to_string : failure_stage -> string
val failure_stage_of_string : string -> (failure_stage, string) result
