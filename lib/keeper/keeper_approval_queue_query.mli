(** The reads of the pending entries in [Keeper_approval_queue].

    [pending_entries_in_sequence_order] lists the pending entries of every
    workspace by sequence. [pending_entries_snapshot_unlocked] keeps those of
    one workspace with the revision of its store and the entry read errors,
    and returns the storage error of an unavailable store that has no entry
    read errors. [pending_entries_snapshot_for_workspace] takes the store lock
    for it. [list_pending_entries_with_read_errors_for_workspace] and
    [list_pending_entries_for_workspace] return parts of that snapshot,
    [list_pending_dashboard_json_for_workspace] renders its entries as JSON
    with their input, and [pending_count_for_keeper_in_workspace] counts the
    entries of one keeper.
    [get_pending_entry_for_workspace] returns one pending entry of a
    workspace, or [None] when the id is unknown or belongs to another
    workspace. [observe_waiting_request] returns the entry that a waiting
    request names, with its decision once the entry is resolved.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_rules
open Keeper_approval_queue_result

type pending_entries_snapshot =
  { revision : int
  ; entries : pending_approval list
  ; read_errors : storage_error list
  }

val pending_entries_snapshot_for_workspace :
  base_path:string -> (pending_entries_snapshot, storage_error) result

val list_pending_entries_with_read_errors_for_workspace :
  base_path:string ->
  (pending_approval list * storage_error list, storage_error) result

val list_pending_entries_for_workspace :
  base_path:string -> (pending_approval list, storage_error) result

val get_pending_entry_for_workspace :
  base_path:string
  -> id:string
  -> (pending_approval option, storage_error) result

val list_pending_dashboard_json_for_workspace :
  base_path:string -> (Yojson.Safe.t list, storage_error) result

val pending_count_for_keeper_in_workspace :
  base_path:string -> keeper_name:string -> (int, storage_error) result

type waiting_observation =
  { waiting_request : pending_approval; waiting_decision : decision option }

val observe_waiting_request : base_path:string -> id:string ->
  (waiting_observation option, storage_error) result
