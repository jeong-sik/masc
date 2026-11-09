(** The durable range receipt store: the same-file check, the rejected
    marker paths, the cache of receipt reads with its fixed point, the
    inspect, cached read, write and remove of the receipt file, the quarantine
    of skipped entries, the holes between receipts and their archive, the
    upsert of one receipt, the sync with a prepared snapshot and the
    reconcile, and the listing of Keeper ids from the file names in the
    Keepers directory.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_current_types
open Keeper_memory_os_current_range_codec

val same_file_identity : Unix.stats -> Unix.stats -> bool

val rejected_base : string -> string option

val unused_rejected_path : snapshot_path:string -> now:float -> string

(* A reconcile against the snapshot at [fixed_revision] whose bytes hash to
   [fixed_snapshot_sha256] returned the cached receipts unchanged. *)
type receipt_fixed_point =
  { fixed_revision : int
  ; fixed_snapshot_sha256 : string
  }

(* [receipts] is the result of [read_durable_range_receipts] for the file
   [receipt_identity] describes: the same decode and the same validation. *)
type durable_range_receipt_cache_entry =
  { receipt_identity : Unix.stats
  ; receipts : durable_range_receipt list
  ; fixed_point : receipt_fixed_point option
  }

type durable_range_receipt_read =
  | Cached_receipts of durable_range_receipt_cache_entry
  | Uncached_receipts of durable_range_receipt list * skipped_range_receipt list

val read_durable_range_receipts_cached :
  keepers_dir:string ->
  keeper_id:string -> (durable_range_receipt_read, string) result

val write_durable_range_receipts :
  keepers_dir:string ->
  keeper_id:string ->
  durable_range_receipt list ->
  (unit, string) result

val sha256 : string -> string

val receipt_range_id :
  durable_range_receipt ->
  consumed_range

val upsert_durable_range_receipt :
  durable_range_receipt list ->
  durable_range_receipt ->
  durable_range_receipt list

val sync_matching_prepared_snapshot :
  keepers_dir:string ->
  keeper_id:string ->
  snapshot:(t * string lazy_t) option ->
  durable_range_receipt list ->
  (unit, string) result

val reconcile_durable_range_receipts :
  keepers_dir:string ->
  keeper_id:string ->
  snapshot:(t * string) option ->
  (durable_range_receipt list, string) result

val keeper_id_of_filename : string -> string option

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val list_preflight_keeper_ids : keepers_dir:string -> (string list, string) result

val list_durable_range_receipt_keeper_ids : keepers_dir:string -> string list
