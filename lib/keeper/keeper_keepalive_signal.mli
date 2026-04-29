open Keeper_types

(** Optional gRPC client + env — WORM Atomic: set at server bootstrap
    when [MASC_AGENT_TRANSPORT=grpc]. *)
val grpc_client_ref : Masc_grpc_client.t option Atomic.t
val grpc_env_ref : Eio_unix.Stdenv.base option Atomic.t

val set_grpc_client : ?env:Eio_unix.Stdenv.base -> Masc_grpc_client.t -> unit

(** FSM guard identity helpers (Cycle 43).
    Wrapped by [Keeper_fsm_guard_runtime.wrap_unit] at call sites. *)
val pre_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_turn_complete_heartbeat : turn_running:bool ref -> unit
val post_wakeup_signal : wakeup:bool Atomic.t -> unit
val post_submit_task : meta:keeper_meta -> task_id:Keeper_id.Task_id.t -> unit
val post_heartbeat_tick : wakeup:bool Atomic.t -> unit

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
val interruptible_sleep :
  clock:'a Eio.Time.clock -> stop:bool Atomic.t -> wakeup:bool Atomic.t ->
  float -> unit

(** Wake up a specific keeper immediately. *)
val wakeup_keeper : ?base_path:string -> string -> unit

(** Wake up all running keepers. [None] preserves legacy global wakeup. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

(** Board-reactive debounce interval (seconds), from runtime config. *)
val board_reactive_debounce_sec : float

val board_reactive_wakeup_allowed :
  base_path:string -> keeper_name:string -> post_id:string -> bool

val wakeup_relevant_keeper_for_board_signal :
  config:Coord.config -> Board_dispatch.keeper_board_signal -> unit

(** Per-stage timing accumulator for Phase 0 profiling. *)
type stage_timing = {
  presence_ms : float;
  snapshot_ms : float;
  board_ms : float;
  turn_ms : float;
  recurring_ms : float;
}

val stage_timing_ring_size : unit -> int

val percentile : float array -> float -> float

val stage_timing_to_json :
  ring:stage_timing array -> count:int -> [> `Null | `Assoc of (string * [> `Assoc of (string * [> `Float | `Int ]) list ]) list ]

val format_since_last_scheduled_autonomous : int option -> string

val keepalive_entry_accepts_late_event :
  ctx:'a context -> keeper_name:string -> bool

val dispatch_keepalive_event :
  ctx:'a context -> keeper_name:string ->
  Keeper_state_machine.event -> unit

val dispatch_keepalive_event_with_audit :
  ctx:'a context -> keeper_name:string ->
  snapshot:Keeper_measurement.measurement ->
  events_fired:Keeper_guard.event list ->
  selected_event:Keeper_guard.event option ->
  Keeper_state_machine.event -> unit
