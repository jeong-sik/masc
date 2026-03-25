(** Keeper_registry — Single source of truth for keeper state.

    Replaces scattered state across keeper_keepalive Hashtbl,
    keeper_resident_supervisor Hashtbl, and file-based meta lookups.
    All keeper state queries and mutations go through this module.

    Thread-safe: all operations protected by Eio.Mutex when available,
    falls back to Stdlib.Mutex for test contexts without Eio. *)

open Keeper_types

type keeper_state =
  | Running
  | Paused
  | Stopped

type registry_entry = {
  base_path : string;
  name : string;
  mutable meta : keeper_meta;
  mutable state : keeper_state;
  fiber_stop : bool ref;
  fiber_wakeup : bool ref;
  started_at : float;
  grpc_close : (unit -> unit) option ref;
  done_p : [ `Stopped | `Crashed of string ] Eio.Promise.t;
  done_r : [ `Stopped | `Crashed of string ] Eio.Promise.u;
      (** Exposed so the supervisor fiber can resolve on stop/crash.
          Only the fiber owning this keeper should call [Eio.Promise.resolve]. *)
  mutable restart_count : int;
  mutable last_restart_ts : float;
  mutable crash_log : (float * string) list;
  mutable last_error : string option;
  mutable last_agent_count : int;
  board_wakeups : (string, float) Hashtbl.t;
}

val state_to_string : keeper_state -> string

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

(** Change keeper state. No-op if not found. *)
val set_state : base_path:string -> string -> keeper_state -> unit

(** Record a restart. Increments restart_count and updates last_restart_ts. *)
val record_restart : base_path:string -> string -> unit

(** Record an error message. *)
val record_error : base_path:string -> string -> string -> unit

(** Record a crash entry in the crash log (keeps last 5). *)
val record_crash : base_path:string -> string -> float -> string -> unit

(** Set or clear the gRPC close callback. *)
val set_grpc_close : base_path:string -> string -> (unit -> unit) option -> unit

(** Check if a keeper is in Running state. *)
val is_running : base_path:string -> string -> bool

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
