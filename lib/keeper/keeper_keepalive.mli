open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringMap = Set_util.StringMap

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

(** Retrieve the shared Event_bus, if set. *)
val get_bus : unit -> Agent_sdk.Event_bus.t option

val register_grpc_heartbeat_starter : Keeper_keepalive_signal.grpc_heartbeat_starter_fn -> unit

(** Apply one typed control-plane directive to a Keeper lane. *)
val process_directive : agent_name:string -> Keeper_directive.t -> unit

(** Test-visible helper for the [current_task_id] sent in gRPC heartbeats.
    This may reconcile registry state against the task backlog before reading
    the value, and returns an empty string when reconciliation cannot be trusted. *)
val current_task_id_for_agent : config:Workspace.config -> string -> string

(** Wake up a specific keeper immediately. Used by broadcast notification
    when a @mention targets a running keeper.

    [?stimulus] appends the payload to the keeper's Event Layer queue
    before flipping the wakeup flag. See RFC-0020 §3. *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. Used for @@all broadcast mentions
    or system-wide events. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

val not_in_registry_warn_cooldown_s : float
val not_in_registry_warn_max_entries : int

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

(** Test-only wrapper for the in-turn liveness pulse lifecycle. *)
val with_in_turn_liveness_pulse_for_test :
  sw:Eio.Switch.t ->
  clock:'a Eio.Time.clock ->
  interval_sec:float ->
  tick:(unit -> unit) ->
  (unit -> 'b) ->
  'b

(** Keepalive loop meta selection. Disk wins when it changed; otherwise
    fall back to the latest registry snapshot instead of the original boot
    meta so continuity/runtime fields do not regress across turns. *)
val effective_keepalive_meta :
  base_path:string ->
  fallback:keeper_meta ->
  disk_meta_opt:keeper_meta option ->
  keeper_meta

val wakeup_relevant_keeper_for_board_signal :
  config:Workspace.config -> Board_dispatch.board_signal -> unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool Atomic.t ->
  wakeup:bool Atomic.t -> unit

(** Compute the p-th percentile of a float array.
    Returns 0.0 for empty arrays. Used by per-stage profiling. *)
val percentile : float array -> float -> float

type start_keepalive_outcome =
  | Keepalive_started of Keeper_registry.registry_entry
  | Keepalive_already_registered of Keeper_registry.registry_entry
  | Keepalive_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Keepalive_identity_unrepairable
  | Keepalive_registration_rejected of Keeper_registry.registration_error
  | Keepalive_fiber_start_rejected of Keeper_state_machine.transition_error
  | Keepalive_lane_ownership_lost
  | Keepalive_fork_rejected of Keeper_lane.start_error

val start_keepalive_outcome_to_string : start_keepalive_outcome -> string

(** Launch one keeper lane and return the exact typed admission/launch
    outcome. Rejections remain logged and observable, but are never collapsed
    into [unit]; lifecycle transactions use the result to commit or roll back. *)
val start_keepalive :
  ?proactive_warmup_sec:int ->
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
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

val stop_all_keepalives : unit -> unit
