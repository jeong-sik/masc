(** Coord lifecycle hook registry.

    Atomic refs filled at boot by the runtime so the coord layer
    can call back into keeper / agent / economy / relation
    subsystems without a static dependency. Default values are
    no-ops; the runtime overrides each ref via the wiring in
    [lib/coord.ml]. *)

open Masc_domain

type activity_entity = { kind: string; id: string }
type agent_lifecycle_event =
  | Lifecycle_join
  | Lifecycle_rejoin
  | Lifecycle_leave

val force_release_task_fn : (Coord_utils_backend_setup.config ->
            agent_name:string ->
            task_id:string -> unit -> string Masc_domain.masc_result)
           Atomic.t
val activity_emit_fn : (Coord_utils_backend_setup.config ->
            actor:activity_entity ->
            ?subject:activity_entity ->
            kind:string ->
            payload:Yojson.Safe.t -> tags:string list -> unit -> unit)
           Atomic.t
val agent_economy_earn_fn : (base_path:string -> agent_name:string -> reason:string -> unit)
           Atomic.t
val stop_keeper_fn : (string -> unit) Atomic.t
val relation_on_leave_fn : (leaving_agent:string -> active_agents:string list -> unit)
           Atomic.t
val relation_on_task_done_fn : (assignee:string -> active_agents:string list -> unit) Atomic.t
val hebbian_on_task_done_fn : (Coord_utils_backend_setup.config ->
            assignee:string -> active_agents:string list -> unit)
           Atomic.t
val hebbian_on_task_cancelled_fn : (Coord_utils_backend_setup.config ->
            agent_name:string -> active_agents:string list -> unit)
           Atomic.t
val agent_lifecycle_event_to_string : agent_lifecycle_event -> string
val observe_agent_lifecycle_fn : (Coord_utils_backend_setup.config ->
            agent_id:string ->
            event:agent_lifecycle_event -> details:Yojson.Safe.t -> unit)
           Atomic.t
val observe_task_transition_fn : (Coord_utils_backend_setup.config ->
            agent_name:string ->
            task_id:string ->
            transition:Masc_domain.task_action ->
            details:Yojson.Safe.t -> unit)
           Atomic.t
val cleanup_board_artifacts_fn : (unit -> int) Atomic.t
val on_task_mutation_fn : (unit -> unit) Atomic.t
val subscribe_messages_fn : (subscriber:string -> unit) Atomic.t
val fsm_drift_observer_fn : (variant:string -> force:bool -> agent_name:string -> unit)
           Atomic.t
val distributed_lock_acquire_failed_fn : (key:string -> attempts:int -> unit) Atomic.t
val tool_assigned_fn : (agent_id:string ->
            profile:string ->
            ?preset:string ->
            tool_list:string list ->
            ?allow_set:string list ->
            ?deny_set:string list ->
            ?config_hash:string -> ?reason:string -> unit -> string)
           Atomic.t
val task_completion_path_observed_fn : (path:string -> contract_state:string -> agent_name:string -> unit)
           Atomic.t
val task_auto_release_observed_fn :
  (agent_name:string -> from_status:string -> unit) Atomic.t

(** Fires once per [Coord_broadcast.broadcast] return, with the wall-clock
    duration of the broadcast body (next_seq + agent.json read +
    msg.json write + activity emit + on_broadcast_mention).  Wired at
    startup ([lib/coord.ml]) to a Prometheus histogram
    [masc_coord_broadcast_duration_seconds] labelled by [msg_type] so
    operators can compare regular broadcasts against
    [cache_invalidated] / mention follow-ups. *)
val coord_broadcast_observed_fn :
  (msg_type:string -> elapsed_s:float -> unit) Atomic.t

(** RFC-0040: sender-side mention dedup decision counter.
    Wired at startup ([lib/coord.ml]) to
    [masc_mention_dedup_decisions_total{outcome}].
    Outcome vocabulary: [skipped|passed|no_target|bypassed]. *)
val mention_dedup_decision_fn :
  (outcome:string -> unit) Atomic.t
val cache_desync_cleared_fn :
  (Coord_utils_backend_setup.config ->
   module_name:string -> task_id:string -> status:string -> unit) Atomic.t
val claim_post_provision_fn : (Coord_utils_backend_setup.config ->
            agent_name:string ->
            task_id:string -> unit)
           Atomic.t
val claim_post_provision_failed_fn :
  (site:string ->
   agent_name:string ->
   task_id:string ->
   error:string ->
   unit) Atomic.t
val observe_claim_post_provision_failure :
  site:string -> agent_name:string -> task_id:string -> exn -> unit
