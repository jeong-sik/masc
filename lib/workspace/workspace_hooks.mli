(** Workspace lifecycle hook registry.

    Atomic refs filled at boot by the runtime so the workspace layer
    can call back into keeper / agent / economy / relation
    subsystems without a static dependency. Default values are
    no-ops; the runtime overrides each ref via the wiring in
    [lib/workspace.ml]. *)

open Masc_domain

type activity_entity = { kind: string; id: string }

type operator_pending_confirm_request = {
  token : string;
  trace_id : string;
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
  delegated_tool : string;
  created_at : string;
  expires_at : string option;
}

type agent_lifecycle_event =
  | Session_bound
  | Session_rebound
  | Session_ended

val force_release_task_fn : (Workspace_utils_backend_setup.config ->
            agent_name:string ->
            task_id:string -> unit -> string Masc_domain.masc_result)
           Atomic.t
val activity_emit_fn : (Workspace_utils_backend_setup.config ->
            actor:activity_entity ->
            ?subject:activity_entity ->
            kind:string ->
            payload:Yojson.Safe.t -> tags:string list -> unit -> unit)
           Atomic.t
val agent_economy_earn_fn : (base_path:string -> agent_name:string -> reason:string -> unit)
           Atomic.t
val stop_keeper_fn : (string -> unit) Atomic.t
val runtime_agents_fn :
  (Workspace_utils_backend_setup.config -> Masc_domain.agent list) Atomic.t
val relation_on_leave_fn : (leaving_agent:string -> active_agents:string list -> unit)
           Atomic.t
val relation_on_task_done_fn : (assignee:string -> active_agents:string list -> unit) Atomic.t
val hebbian_on_task_done_fn : (Workspace_utils_backend_setup.config ->
            assignee:string -> active_agents:string list -> unit)
           Atomic.t
val hebbian_on_task_cancelled_fn : (Workspace_utils_backend_setup.config ->
            agent_name:string -> active_agents:string list -> unit)
           Atomic.t
val agent_lifecycle_event_to_string : agent_lifecycle_event -> string
val observe_agent_lifecycle_fn : (Workspace_utils_backend_setup.config ->
            agent_id:string ->
            event:agent_lifecycle_event -> details:Yojson.Safe.t -> unit)
           Atomic.t
val observe_task_transition_fn : (Workspace_utils_backend_setup.config ->
            agent_name:string ->
            task_id:string ->
            transition:Masc_domain.task_action ->
            details:Yojson.Safe.t -> unit)
           Atomic.t
val cleanup_board_artifacts_fn : (unit -> int) Atomic.t
val on_task_mutation_fn : (unit -> unit) Atomic.t

val operator_pending_confirm_trace_id_fn : (string -> string) Atomic.t

val operator_pending_confirm_upsert_fn :
  (Workspace_utils_backend_setup.config ->
   operator_pending_confirm_request ->
   (unit, string) result)
    Atomic.t

val operator_pending_confirm_remove_fn :
  (Workspace_utils_backend_setup.config -> string -> (unit, string) result) Atomic.t

val operator_pending_confirm_read_all_fn :
  (Workspace_utils_backend_setup.config -> operator_pending_confirm_request list) Atomic.t

val subscribe_messages_fn : (subscriber:string -> unit) Atomic.t
val fsm_drift_observer_fn : (variant:string -> force:bool -> agent_name:string -> unit)
           Atomic.t
val distributed_lock_acquire_failed_fn : (key:string -> attempts:int -> unit) Atomic.t
val tool_assigned_fn : (agent_id:string ->
            profile:string ->
            tool_list:string list ->
            ?allow_set:string list ->
            ?deny_set:string list ->
            ?config_hash:string -> ?reason:string -> unit -> string)
           Atomic.t
val task_completion_path_observed_fn : (path:string -> contract_state:string -> agent_name:string -> unit)
           Atomic.t
val task_auto_release_observed_fn :
  (agent_name:string -> from_status:string -> unit) Atomic.t

(** Fires once per [Workspace_broadcast.broadcast] return, with the wall-clock
    duration of the broadcast body (next_seq + agent.json read +
    msg.json write + activity emit + on_broadcast_mention).  Wired at
    startup ([lib/workspace.ml]) to a Otel_metric_store histogram
    [masc_workspace_broadcast_duration_seconds] labelled by [msg_type] so
    operators can compare regular broadcasts against
    [cache_invalidated] / mention follow-ups. *)
val workspace_broadcast_observed_fn :
  (msg_type:string -> elapsed_s:float -> unit) Atomic.t

(** RFC-0040: sender-side mention dedup decision counter.
    Wired at startup ([lib/workspace.ml]) to
    [masc_mention_dedup_decisions_total{outcome}].
    Outcome vocabulary: [skipped|passed|no_target|bypassed]. *)
val mention_dedup_decision_fn :
  (outcome:string -> unit) Atomic.t
val cache_desync_cleared_fn :
  (Workspace_utils_backend_setup.config ->
   module_name:string -> task_id:string -> status:string -> unit) Atomic.t
val workspace_telemetry_drop_fn : (Workspace_telemetry_drop_event.t -> unit) Atomic.t
val active_agents_change_fn : ([ `Inc | `Dec ] -> unit) Atomic.t
val telemetry_observe_failure_fn : (string -> unit) Atomic.t
val get_default_runtime_id_fn : (unit -> string) Atomic.t

(** [\[runtime\].cross_verifier] runtime id for the anti-rationalization
    evaluator, or [None] to use {!get_default_runtime_id_fn}. Wired to
    [Runtime.cross_verifier_runtime_id] at startup; defaults to [fun () -> None]
    (use the global default) when not connected, so callers in test contexts
    fall back rather than crash. *)
val get_cross_verifier_runtime_id_fn : (unit -> string option) Atomic.t

val record_task_metric_fn :
  (Workspace_utils_backend_setup.config ->
   agent_id:string ->
   task_id:string ->
   started_at:float ->
   completed_at:float option ->
   success:bool ->
   error_message:string option ->
   collaborators:string list ->
   handoff_from:string option ->
   handoff_to:string option ->
   unit) Atomic.t

val record_thompson_result_fn :
  (agent_name:string -> success:bool -> reason:string option -> unit) Atomic.t

val push_task_event_fn :
  (event_type:string -> details:(string * Yojson.Safe.t) list -> unit) Atomic.t

val verification_submit_request_fn :
  (Workspace_utils_backend_setup.config ->
   task:Masc_domain.task ->
   assignee:string ->
   verification_id:string ->
   evidence_refs:string list ->
   (unit, string) result) Atomic.t

val verification_record_verdict_fn :
  (Workspace_utils_backend_setup.config ->
   task_id:string ->
   verifier:string ->
   verification_id:string ->
   decision:[ `Approve of string | `Reject of string ] ->
   (unit, string) result) Atomic.t

(** RFC-0221 §3.1: compensation hook — delete a verification record whose
    task_status commit failed, so the record store and [task_status] never
    disagree. Default no-op until the runtime fills it at boot. *)
val verification_delete_request_fn :
  (Workspace_utils_backend_setup.config ->
   verification_id:string ->
   (unit, string) result) Atomic.t

val verification_notify_submit_fn :
  (Workspace_utils_backend_setup.config ->
   task:Masc_domain.task ->
   assignee:string ->
   verification_id:string ->
   evidence_refs:string list ->
   unit) Atomic.t

val verification_notify_verdict_fn :
  (task_id:string ->
   verifier:string ->
   verification_id:string ->
   decision:[ `Approve of string | `Reject of string ] ->
   unit) Atomic.t

val is_admin_agent_fn :
  (base_path:string -> agent_name:string -> bool) Atomic.t

type evidence_gate_verdict =
  | Pass
  | Reject of { reason : string; rule_id : string; hint : string; payload_json : Yojson.Safe.t }

val cdal_evidence_gate_decide_fn :
  (task_id:string ->
   task_opt:Masc_domain.task option ->
   notes:string ->
   handoff:Masc_domain.task_handoff_context option ->
   unit ->
   evidence_gate_verdict)
  Atomic.t
