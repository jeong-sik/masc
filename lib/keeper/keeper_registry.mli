(** Keeper_registry — Single source of truth for keeper state.

    Replaces scattered state across keeper_keepalive Hashtbl,
    keeper_supervisor Hashtbl, and file-based meta lookups.
    All keeper state queries and mutations go through this module.

    Thread-safety: all operations are non-yielding (in-memory map/ref
    ops only).  In single-domain Eio, non-yielding code runs atomically
    w.r.t. other fibers, so no mutex is needed. *)

open Keeper_types

module StringMap : Map.S with type key = string

(** Structured failure reason for crash cohort detection. *)
type failure_reason =
  | Heartbeat_consecutive_failures of int
  | Turn_consecutive_failures of int
  | Fiber_unresolved
  | Exception of string

val failure_reason_to_string : failure_reason -> string

(** Pure control-flow signal for immediate fiber termination (RFC-0002).
    Carries no state — failure reason must be pre-stored via
    [set_failure_reason] before raising. *)
exception Keeper_fiber_crash

type registry_entry = {
  base_path : string;
  name : string;
  meta : keeper_meta;
  phase : Keeper_state_machine.phase;
      (** Keeper lifecycle phase (RFC-0002 11-state machine). *)
  conditions : Keeper_state_machine.conditions;
      (** Observable conditions that derive [phase]. *)
  fiber_stop : bool Atomic.t;
  fiber_wakeup : bool Atomic.t;
  started_at : float;
  grpc_close : (unit -> unit) option Atomic.t;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
      (** Exposed so keeper lifecycle coordinators can resolve stop/crash exactly once.
          Callers must preserve a single terminal outcome per keeper run. *)
  restart_count : int;
  last_restart_ts : float;
  dead_since_ts : float option;
  crash_log : (float * string) list;
  last_error : string option;
  last_failure_reason : failure_reason option;
  turn_consecutive_failures : int;
  last_agent_count : int;
  board_wakeups : float StringMap.t;
  board_cursor_ts : float;
  board_cursor_post_id : string option;
  tool_usage : Keeper_types.tool_call_entry StringMap.t;
  transition_seq : int;
  waiting_for_inference : bool Atomic.t;
      (** Ephemeral flag: true when keeper is blocked in admission queue.
          Does not affect state machine phase derivation. *)
}

(** Register a keeper as running. Returns the new entry. *)
val register : base_path:string -> string -> keeper_meta -> registry_entry

(** Unregister a keeper (removes from registry). *)
val unregister : base_path:string -> string -> unit

(** Look up a keeper by name. *)
val get : base_path:string -> string -> registry_entry option

(** Look up a keeper by name, raising [Not_found] if absent. *)
val get_exn : base_path:string -> string -> registry_entry

(** Return all registered keepers. *)
val all : ?base_path:string -> unit -> registry_entry list

(** Update the meta for a registered keeper. No-op if not found. *)
val update_meta : base_path:string -> string -> keeper_meta -> unit

(** @deprecated Use [dispatch_event]. No external callers remain. *)

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(** Record an error message. *)
val record_error : base_path:string -> string -> string -> unit

(** Set the structured failure reason for cohort detection. *)
val set_failure_reason : base_path:string -> string -> failure_reason option -> unit

(** Increment turn consecutive failure counter. *)
val increment_turn_failures : base_path:string -> string -> unit

(** Reset turn consecutive failure counter (on success). *)
val reset_turn_failures : base_path:string -> string -> unit

(** Get current turn consecutive failure count. *)
val get_turn_failures : base_path:string -> string -> int

(** Record a crash entry in the crash log (keeps last 5). *)
val record_crash : base_path:string -> string -> float -> string -> unit

(** Set or clear the gRPC close callback. *)
val set_grpc_close : base_path:string -> string -> (unit -> unit) option -> unit

(** Check if a keeper is in Running state. *)
val is_running : base_path:string -> string -> bool

(** Check if a keeper has ANY registry entry (regardless of state).
    Used by reconcile to skip Crashed/Dead keepers. *)
val is_registered : base_path:string -> string -> bool

(** Mark a keeper as dead tombstone and record the transition timestamp. *)
val mark_dead : base_path:string -> string -> at:float -> unit

(** Return the started_at timestamp, or None if not registered. *)
val started_at : base_path:string -> string -> float option

(** Count keepers in Running state. *)
val count_running : ?base_path:string -> unit -> int

(** Check if there are available spawn slots (respects max_active_keepers). *)
val spawn_slots_available : unit -> bool

(** Set fiber_wakeup for a specific keeper. *)
val wakeup : base_path:string -> string -> unit

(** Set fiber_wakeup for all running keepers. *)
val wakeup_all : ?base_path:string -> unit -> unit

(** Fiber-level health based on Promise resolution state.
    Returns Fiber_unknown if the keeper is not registered. *)
val fiber_health_of : base_path:string -> string -> fiber_health

(** Recent crash entries (up to 5) for a keeper. *)
val crash_log_of : base_path:string -> string -> (float * string) list

(** Restore supervisor state on a freshly registered entry (used by restart). *)
val restore_supervisor_state :
  base_path:string -> string ->
  restart_count:int -> last_restart_ts:float ->
  crash_log:(float * string) list -> unit

(** Last known agent count for roster-change detection. Returns 0 if not found. *)
val get_last_agent_count : base_path:string -> string -> int

(** Update last agent count for a keeper. No-op if not found. *)
val set_last_agent_count : base_path:string -> string -> int -> unit

(** Check if a board-reactive wakeup is allowed (debounce).
    Records timestamp if allowed. Returns true for unregistered keepers. *)
val board_wakeup_allowed :
  base_path:string -> string -> post_id:string -> debounce_sec:float -> bool

(** Clear all board wakeup timestamps for a keeper. No-op if not found. *)
val clear_board_wakeups : base_path:string -> string -> unit

(** Reset tracking state (agent count + board wakeups) for a keeper. *)
val cleanup_tracking : base_path:string -> string -> unit

(** Clear the registry. For testing only. *)
val clear : unit -> unit

(** Get board event cursor timestamp. Returns 0.0 if not found. *)
val get_board_cursor_ts : base_path:string -> string -> float

(** Update board event cursor timestamp. No-op if not found. *)
val set_board_cursor_ts : base_path:string -> string -> float -> unit

(** Get board event cursor token. Returns [(0.0, None)] if not found. *)
val get_board_cursor : base_path:string -> string -> float * string option

(** Update board event cursor token. No-op if not found. *)
val set_board_cursor :
  base_path:string -> string -> float -> string option -> unit

(** Record a tool call for a keeper. No-op if not found. *)
val record_tool_use :
  base_path:string -> string -> tool_name:string -> success:bool -> unit

(** Get tool usage sorted by call count descending. *)
val tool_usage_of : base_path:string -> string ->
  (string * Keeper_types.tool_call_entry) list

(** Look up a keeper by name across all base_paths (O(n) scan). *)
val find_by_name : string -> registry_entry option

(** Look up a keeper by agent_name across all base_paths (O(n) scan). *)
val find_by_agent_name : string -> registry_entry option

(** Get tool usage by keeper name (scans all base_paths). *)
val tool_usage_of_by_name : string ->
  (string * Keeper_types.tool_call_entry) list

(** Resolve config for a keeper tool dispatch.
    Tries scoped lookup first (O(1) map lookup), then falls back to
    cross-base_path scan (O(n)) when not found in the caller's scope.
    Returns config with the keeper's actual base_path, or the original
    config unchanged if the keeper is not in the registry. *)
val resolve_config : Room_utils_backend_setup.config -> string -> Room_utils_backend_setup.config

(** Flush in-memory tool usage stats to disk for persistence across restarts. *)
val flush_tool_usage : base_path:string -> string -> unit

(** Restore tool usage stats from disk after keeper re-registration. *)
val restore_tool_usage : base_path:string -> string -> unit

(** {1 RFC-0002 Event Dispatch} *)

(** Dispatch a typed event through the state machine.
    Updates conditions, derives new phase, syncs legacy state.
    Returns the transition result or an error for invalid transitions.
    Prefer this over [set_state] for new code. *)
val dispatch_event :
  base_path:string -> string -> Keeper_state_machine.event ->
  (Keeper_state_machine.transition_result, Keeper_state_machine.transition_error) result

(** Get the fine-grained phase of a keeper. *)
val get_phase : base_path:string -> string -> Keeper_state_machine.phase option

(** Get the observable conditions of a keeper. *)
val get_conditions : base_path:string -> string -> Keeper_state_machine.conditions option
