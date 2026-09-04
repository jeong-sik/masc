(** Workspace lifecycle hook registry.

    Atomic refs filled at boot by the runtime so the workspace layer
    can call back into keeper / agent / relation
    subsystems without a static dependency. Default values are
    no-ops; the runtime overrides each ref via the wiring in
    [lib/workspace.ml]. *)


type activity_entity = { kind: string; id: string }

type operator_pending_confirm_request = {
  confirm_token : string;
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

type task_terminal_delivery =
  | Task_terminal_delivered
  | Task_terminal_delivery_degraded of { kind : string; detail : string }

val activity_emit_fn : (Workspace_utils_backend_setup.config ->
            actor:activity_entity ->
            ?subject:activity_entity ->
            kind:string ->
            payload:Yojson.Safe.t -> tags:string list -> unit -> unit)
           Atomic.t
val runtime_agents_fn :
  (Workspace_utils_backend_setup.config -> Masc_domain.agent list) Atomic.t

(** Whether [agent_name] is present in the live Keeper registry for
    [base_path]. The default is [false]; the runtime installs the registry
    lookup before tool dispatch. *)
val keeper_registered_fn :
  (base_path:string -> agent_name:string -> bool) Atomic.t

(** Whether a schedule keeper_wake target has durable keeper metadata.
    [Ok true] = registered, [Ok false] = absent, [Error] = read failure.
    Default allows every target; the runtime installs the
    durable-metadata reader at boot so the tool layer keeps no static
    keeper dependency (RFC-0194). *)
val schedule_wake_target_registered_fn :
  (Workspace_utils_backend_setup.config -> string -> (bool, string) result) Atomic.t
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
val on_task_mutation_fn : (unit -> unit) Atomic.t

(** A workspace message's authoritative row was committed or its delivery
    state changed. Runtime wiring invalidates projections and emits the
    corresponding refresh signal. *)
val on_workspace_message_mutation_fn :
  (Workspace_utils_backend_setup.config ->
   request_id:string ->
   mention_delivery:Masc_domain.message_mention_delivery ->
   unit)
    Atomic.t

val operator_pending_confirm_trace_id_fn : (string -> string) Atomic.t

val operator_pending_confirm_upsert_fn :
  (Workspace_utils_backend_setup.config ->
   operator_pending_confirm_request ->
   (unit, string) result)
    Atomic.t

val operator_pending_confirm_read_result_fn :
  (Workspace_utils_backend_setup.config ->
   (operator_pending_confirm_request list, string) result)
    Atomic.t

val operator_pending_confirm_remove_fn :
  (Workspace_utils_backend_setup.config -> string -> (unit, string) result) Atomic.t

val subscribe_messages_fn : (subscriber:string -> unit) Atomic.t
val distributed_lock_acquire_failed_fn : (key:string -> attempts:int -> unit) Atomic.t
val tool_assigned_fn : (agent_id:string ->
            profile:string ->
            tool_list:string list ->
            ?config_hash:string -> ?reason:string -> unit -> string)
           Atomic.t
(** Fires once per successful [Workspace_broadcast.broadcast] commit, with the wall-clock
    duration of the broadcast body (next_seq + agent.json read +
    msg.json write + activity emit + on_broadcast_mention).  Wired at
    startup ([lib/workspace.ml]) to a Otel_metric_store histogram
    [masc_workspace_broadcast_duration_seconds] labelled by [msg_type] so
    operators can compare regular broadcasts against
    [cache_invalidated] / mention follow-ups. Authoritative write failures are
    excluded rather than merged into the success latency distribution. *)
val workspace_broadcast_observed_fn :
  (msg_type:string -> elapsed_s:float -> unit) Atomic.t

val cache_desync_cleared_fn :
  (Workspace_utils_backend_setup.config ->
   module_name:string -> task_id:string -> status:string -> unit) Atomic.t
val workspace_telemetry_drop_fn : (Workspace_telemetry_drop_event.t -> unit) Atomic.t
val active_agents_change_fn : ([ `Inc | `Dec ] -> unit) Atomic.t
val telemetry_observe_failure_fn : (string -> unit) Atomic.t
val get_default_runtime_id_fn : (unit -> string) Atomic.t

(** Admitted [\[runtime.exact_output_lanes.verifier_exact\]] slot ids in frozen
    declaration order for the completion-authority evaluator (RFC-0361 D7(a)).
    Wired to [Runtime.verifier_exact_lane_slot_ids] at startup; the unconnected
    default is an explicit [Error], so test contexts that drive a review must
    install their own slot list rather than inherit a silent runtime default. *)
val get_verifier_exact_lane_slot_ids_fn : (unit -> (string list, string) result) Atomic.t

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

val push_task_event_fn :
  (event_type:string -> details:(string * Yojson.Safe.t) list -> unit) Atomic.t

val task_terminal_committed_fn :
  (Workspace_utils_backend_setup.config ->
   agent_name:string ->
   task_id:string ->
   task_terminal_delivery) Atomic.t

(** Persists the immutable verification request used by the system LLM
    completion-authority lane. The default returns an explicit not-installed
    error until the runtime fills it at boot. *)
val verification_submit_request_fn :
  (Workspace_utils_backend_setup.config ->
   task:Masc_domain.task ->
   assignee:string ->
   verification_id:string ->
   claim:Masc_domain.verification_claim ->
   (unit, string) result) Atomic.t

(** RFC-0221 §3.1: compensation hook — delete a verification record whose
    task_status commit failed, so the record store and [task_status] never
    disagree. The default returns an explicit not-installed error until the
    runtime fills it at boot. *)
val verification_delete_request_fn :
  (Workspace_utils_backend_setup.config ->
   verification_id:string ->
   (unit, string) result) Atomic.t

(** Publishes the submitted-verification notification after persistence. A
    missing runtime adapter is logged explicitly by the default. *)
val verification_notify_submit_fn :
  (Workspace_utils_backend_setup.config ->
   task:Masc_domain.task ->
   assignee:string ->
   verification_id:string ->
   claim:Masc_domain.verification_claim ->
   unit) Atomic.t

(** Notify the system LLM completion-authority lane after the task status and
    verification request have both committed. The callback must not be a
    Keeper wake-up or a Keeper task action; it only schedules the typed
    out-of-band authority review. *)
val verification_submitted_fn :
  (Workspace_utils_backend_setup.config ->
   task:Masc_domain.task ->
   assignee:string ->
   verification_id:string ->
   unit) Atomic.t

(** Notify the goal verifier lane (RFC-0387 stage 2) after a durable
    verification request committed on the goal ledger — the [Proof_pending]
    row written before the phase enters [Verifying]. The
    goal-side analogue of {!verification_submitted_fn}: the callback only
    schedules the out-of-band review; it is never a Keeper wake-up. *)
val goal_verification_pending_fn :
  (Workspace_utils_backend_setup.config -> goal_id:string -> unit) Atomic.t

(** Publishes the completion-verdict notification after the task status
    commit. A missing runtime adapter is logged explicitly by the default. *)
val verification_notify_verdict_fn :
  (task_id:string ->
   authority:Masc_domain.completion_authority ->
   verification_id:string ->
   decision:[ `Approve of string | `Reject of string ] ->
   unit) Atomic.t

val is_admin_agent_fn :
  (base_path:string -> agent_name:string -> bool) Atomic.t
