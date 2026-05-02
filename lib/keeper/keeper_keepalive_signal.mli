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

(** Outcome of an [interruptible_sleep] call. Mirrors the three terminal
    branches of the polling loop, so callers can react to "woken by an
    external signal" distinctly from "slept the full duration".

    Closing the [Skip_idle] half of the [MissedWakeup] gap (see
    [specs/keeper-state-machine/KeeperHeartbeat.tla]) requires
    discriminating [`Woken`] from [`Timeout`] at the call site — sibling
    fix #10078 covered [Skip_busy] without exposing this distinction. *)
type sleep_outcome =
  | Stopped   (** [stop] atomic was observed [true] before the duration
                  elapsed. *)
  | Woken     (** [wakeup] atomic transitioned [true -> false] via CAS;
                  the caller should treat this as a [HeartbeatTick]
                  spec-action and dispatch a turn. *)
  | Timeout   (** Full [duration] elapsed without [stop] or [wakeup]. *)

(** Sleep in short chunks so [stop_keepalive] or [wakeup_keeper] takes
    effect within ~chunk_sec instead of waiting for the full interval. *)
val interruptible_sleep :
  clock:'a Eio.Time.clock -> stop:bool Atomic.t -> wakeup:bool Atomic.t ->
  float -> sleep_outcome

(** Wake up a specific keeper immediately.

    When [?stimulus] is given, the stimulus is appended to the keeper's
    Event Layer queue ([Keeper_registry.enqueue_event]) before the wakeup
    flag flips. Callers that have a real payload (board post, mention,
    operator directive) should pass it; callers that only need to break
    the keeper out of [interruptible_sleep] may omit it and the call
    behaves as before. See RFC-0020 §3 (data channel vs hint signal). *)
val wakeup_keeper :
  ?base_path:string ->
  ?stimulus:Keeper_event_queue.stimulus ->
  string -> unit

(** Wake up all running keepers. [None] preserves legacy global wakeup. *)
val wakeup_all_keepers : ?base_path:string -> unit -> unit

(** Board-reactive debounce interval (seconds), from runtime config. *)
val board_reactive_debounce_sec : float

val board_reactive_generic_wakeup_limit : int

val board_reactive_wakeup_allowed :
  base_path:string -> keeper_name:string -> post_id:string -> bool

val select_board_wakeup_candidates :
  ?generic_limit:int -> ('a * string option) list -> ('a * string) list * int

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
  ring:stage_timing array -> count:int ->
  [> `Null
  | `Assoc of
      (string *
       [> `Assoc of (string * [> `Float of float | `Int of int ]) list ])
      list
  ]

val format_since_last_scheduled_autonomous : int option -> string

val keepalive_entry_accepts_late_event :
  ctx:'a context -> keeper_name:string -> bool

val dispatch_keepalive_event :
  ctx:'a context -> keeper_name:string ->
  Keeper_state_machine.event -> unit

val dispatch_keepalive_event_with_audit :
  ctx:'a context -> keeper_name:string ->
  snapshot:Keeper_measurement.measurement_snapshot ->
  events_fired:Keeper_state_machine.event list ->
  selected_event:Keeper_state_machine.event ->
  Keeper_state_machine.event -> unit
