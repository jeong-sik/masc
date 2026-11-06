(** The durable writes of the approval queue in [Keeper_approval_queue].

    [report_pending_read_drop] and [report_replay_results_read_drop] report a
    dropped read of the pending store or of the replay results and count it in
    the persistence read-drop metric.
    [save_snapshot_file_unlocked], [save_snapshot_file_strict_staged_unlocked]
    and [save_replay_results_file_unlocked] write the snapshot file and the
    replay results file of a workspace. [publish_snapshot_outcome] raises the
    store revision after a write that landed and marks the store unavailable
    after a failed one.
    [compact_unlocked] writes the snapshot at the next generation and then
    empties the append log. [persist_delta_unlocked] appends only the rows
    that differ from the last durable state, and compacts instead when the
    write mode asks for a rewrite, when the workspace has no durable state,
    when the log would hold more than [compaction_ratio] times as many rows as
    entries, or when the log is not what memory believes it is.
    [store_lifecycle] says whether the store of a workspace is not installed,
    ready with its next sequence, or unavailable, and [next_sequence_lifecycle]
    reads it. [persist_snapshot_unlocked] writes the pending and delivery maps
    of a ready store and returns an error for the other two states.
    [persist_snapshot_with_sequence_unlocked] writes at a given sequence, and
    [persist_snapshot_exact_unlocked] takes the snapshot writer and the write
    mode from its caller.
    [Keeper_approval_queue] includes this module. *)
open Keeper_approval_queue_result
open Keeper_approval_queue_codec
open Keeper_approval_queue_registry

val report_pending_read_drop :
  reason:Read_drop_reason.t -> path:string -> detail:string -> unit

val report_replay_results_read_drop :
  reason:Read_drop_reason.t -> path:string -> detail:string -> unit

val save_snapshot_file_unlocked :
  base_path:string ->
  next_sequence:int ->
  generation:int ->
  pending_map:Keeper_approval_queue_rules_types.pending_approval
              Set_util.StringMap.t ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  (unit, storage_error) result

val save_replay_results_file_unlocked :
  base_path:string ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  (Keeper_event_queue_persistence.exact_write_outcome,
   storage_error)
  result

val compact_unlocked :
  write_snapshot:(generation:int -> ('a, 'b) result) ->
  base_path:string ->
  pending_map:Keeper_approval_queue_rules_types.pending_approval
              Set_util.StringMap.t ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  ('a, 'b) result

val persist_snapshot_with_sequence_unlocked :
  base_path:string ->
  next_sequence:int ->
  pending_map:Keeper_approval_queue_rules_types.pending_approval
              Set_util.StringMap.t ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  (unit, storage_error) result

type store_lifecycle =
  | Uninstalled
  | Ready of int
  | Unavailable of storage_error

val next_sequence_lifecycle : base_path:string -> store_lifecycle

val persist_snapshot_unlocked :
  base_path:string ->
  pending_map:Keeper_approval_queue_rules_types.pending_approval
              Set_util.StringMap.t ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  (unit, storage_error) result

val persist_snapshot_exact_unlocked :
  save_file_atomic_strict_staged:(string ->
                                  string ->
                                  (unit, Fs_compat.atomic_replace_failure)
                                  result) ->
  write_mode:write_mode ->
  base_path:string ->
  pending_map:Keeper_approval_queue_rules_types.pending_approval
              Set_util.StringMap.t ->
  delivery_map:persisted_delivery
               Set_util.StringMap.t ->
  (Keeper_event_queue_persistence.exact_write_outcome,
   storage_error)
  result
