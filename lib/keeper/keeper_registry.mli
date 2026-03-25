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
  name : string;
  mutable meta : keeper_meta;
  mutable state : keeper_state;
  fiber_stop : bool ref;
  fiber_wakeup : bool ref;
  started_at : float;
  mutable restart_count : int;
  mutable last_error : string option;
}

val state_to_string : keeper_state -> string

(** Register a keeper as running. Returns the new entry. *)
val register : string -> keeper_meta -> registry_entry

(** Unregister a keeper (removes from registry). *)
val unregister : string -> unit

(** Look up a keeper by name. *)
val get : string -> registry_entry option

(** Look up a keeper by name, raising [Not_found] if absent. *)
val get_exn : string -> registry_entry

(** Return all registered keepers. *)
val all : unit -> registry_entry list

(** Update the meta for a registered keeper. No-op if not found. *)
val update_meta : string -> keeper_meta -> unit

(** Change keeper state. No-op if not found. *)
val set_state : string -> keeper_state -> unit

(** Record a restart for a keeper. Increments restart_count. *)
val record_restart : string -> unit

(** Record an error for a keeper. *)
val record_error : string -> string -> unit

(** Return the started_at timestamp for a keeper, or None if not registered. *)
val started_at : string -> float option

(** Check if a keeper is in Running state. *)
val is_running : string -> bool

(** Count keepers in Running state. *)
val count_running : unit -> int

(** Clear the registry. For testing only. *)
val clear : unit -> unit
