open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringMap = Set_util.StringMap

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_core.Event_bus.t -> unit

(** Apply one typed runtime directive to a Keeper lane. [Wakeup] only
    signals scheduling and never clears an operator pause; paused-work resume
    belongs to [Keeper_paused_work_resume_transaction]. *)
val process_directive : agent_name:string -> Keeper_directive.t -> unit

(** Test-visible helper for the [current_task_id] sent in gRPC heartbeats.
    This may reconcile registry state against the task backlog before reading
    the value, and returns an empty string when reconciliation cannot be trusted. *)
val current_task_id_for_agent : config:Workspace.config -> string -> string

(** Wake up a specific keeper immediately. Used by broadcast notification
    when a [@mention] targets a running keeper.

    [?stimulus] appends the payload to the keeper's Event Layer queue
    before flipping the wakeup flag. See RFC-0020 §3. *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

val not_in_registry_warn_cooldown_s : float
type not_in_registry_warn_decision =
  | Warn_unknown_keeper
  | Debug_throttled_unknown_keeper

val not_in_registry_warn_due :
  ?cooldown_s:float -> previous:float option -> now:float -> unit -> bool

val not_in_registry_warn_state_step :
  ?max_entries:int ->
  agent_name:string ->
  now:float ->
  float StringMap.t ->
  not_in_registry_warn_decision * float StringMap.t

val wakeup_relevant_keeper_for_board_signal :
  config:Workspace.config -> Board_dispatch.addressed_board_signal -> unit
(** Addressed signals are durably routed immediately. Discoverable posts are
    left to the existing per-Keeper durable Board cursor because they have no
    immediate wake target. *)

(** Fork the Board-attention judgment worker as a sibling of the heartbeat
    loop on the same Keeper lane switch. Both lane-start paths call this, so
    the lane's sidecar set has one definition: a lane reached through
    [start_keepalive] recovery judges Board candidates exactly as a supervised
    one does. Resolve [stop] when the lane's heartbeat ends.

    A worker fatal stops the worker and is recorded; the lane continues
    (RFC-0341: tool/persistence/resource failures are observations and never
    produce an implicit lifecycle transition). *)
val fork_board_attention_worker :
  sw:Eio.Switch.t ->
  ctx:'a context ->
  keeper_name:string ->
  stop:unit Eio.Promise.t ->
  unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> cadence_sleeping:bool Atomic.t -> unit

(** Compute the p-th percentile of a float array.
    Returns 0.0 for empty arrays. Used by per-stage profiling. *)
val percentile : float array -> float -> float

type start_keepalive_outcome =
  | Keepalive_started of Keeper_registry.registry_entry
  | Keepalive_already_registered of Keeper_registry.registry_entry
  | Keepalive_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Keepalive_registration_rejected of Keeper_registry.registration_error
  | Keepalive_fiber_start_rejected of Keeper_state_machine.transition_error
  | Keepalive_memory_lane_not_ready of Keeper_memory_lane.lifecycle_open_error
  | Keepalive_launch_callback_failed of string
  | Keepalive_lane_ownership_lost
  | Keepalive_fork_rejected of Keeper_lane.start_error

val start_keepalive_outcome_to_string : start_keepalive_outcome -> string

(** Launch one keeper lane and return the exact typed admission/launch
    outcome. Rejections remain logged and observable, but are never collapsed
    into [unit]; lifecycle transactions use the result to commit or roll back.
    [intake_token] keeps a create transaction live through registry handoff. *)
val start_keepalive :
  ?proactive_warmup_sec:int ->
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  ?intake_token:Keeper_shutdown_intake_fence.intake_token ->
  'a context ->
  keeper_meta ->
  start_keepalive_outcome

type joined_stop =
  { lane_exit : Keeper_lane.exit
  ; terminal : Keeper_registry.done_resolution
  }

type joined_stop_result =
  | Keeper_not_registered
  | Keeper_joined of joined_stop

(** Request cooperative stop without claiming that the lane has exited. *)
val stop_keepalive : ?base_path:string -> string -> unit

(** Signal only the exact captured registry entry. *)
val request_entry_stop : Keeper_registry.registry_entry -> unit

(** Request cooperative stop and join the exact registry entry observed by
    this call. No timeout is invented: callers choose whether to await. *)
val stop_keepalive_and_await :
  base_path:string -> string -> joined_stop_result

