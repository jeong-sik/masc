(** The loading of the durable approval queue in [Keeper_approval_queue].

    [read_pending_log_unlocked] replays the append log over the maps of a
    snapshot and returns the result as a [log_read]. A final line without its
    newline is dropped and sets [partial_tail]. [read_durable_unlocked]
    returns what a restart would see, the snapshot plus the log rows after it,
    without classifying the entries or rewriting the snapshot.
    [load_snapshot_unlocked] reads the same state, plans the restart from it
    and reports the entry errors the plan lists. When the plan asks for a
    rewrite, it installs the state it read and compacts the store with
    [compact_unlocked]; if that fails, it restores the earlier durable state
    and returns the error. Both functions read a missing snapshot as an empty
    store.
    [load_replay_results_unlocked] sets the replay outcome of the deliveries
    named in the replay results file. [attach_replay_results] fails for an
    outcome without a delivery, for a delivery that is not an approval with a
    consumed grant, and for a delivery that already has an outcome. A file
    that cannot be used is returned as an error beside the unchanged
    deliveries.
    [remove_base_entries] drops the entries of one workspace from a map, and
    [merge_loaded_map] adds loaded entries to a map and fails when an id is
    already in it.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_rules
open Keeper_approval_queue_registry

type log_read =
  { log_pending : pending_approval SMap.t
  ; log_deliveries : persisted_delivery SMap.t
  ; log_next_sequence : int
  ; log_end : Fs_compat.Private_jsonl_cursor.t
  ; rows_applied : int
  ; partial_tail : bool
  }

val read_durable_unlocked :
  base_path:string ->
  (Keeper_approval_queue_rules_types.pending_approval Set_util.StringMap.t *
   persisted_delivery Set_util.StringMap.t *
   int * int * string list * log_read option,
   storage_error)
  result

type loaded_snapshot =
  { loaded_pending : pending_approval SMap.t
  ; loaded_deliveries : persisted_delivery SMap.t
  ; loaded_next_sequence : int
  ; loaded_read_errors : storage_error list
  ; loaded_durable : durable_state option
  }

val load_snapshot_unlocked :
  base_path:string ->
  (loaded_snapshot, storage_error) result

val load_replay_results_unlocked :
  base_path:string ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  persisted_delivery Set_util.StringMap.t *
  storage_error option

val remove_base_entries :
  base_path:string ->
  'a Set_util.StringMap.t ->
  ('a -> Keeper_approval_queue_rules_types.pending_approval) ->
  'a Set_util.StringMap.t

val merge_loaded_map :
  surface:string ->
  existing:'a Set_util.StringMap.t ->
  loaded:'a Set_util.StringMap.t -> ('a Set_util.StringMap.t, string) result
