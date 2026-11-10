(** Where one Keeper's current Memory OS files live under the Keepers
    directory, and the incarnation epoch kept beside them: the suffix and path
    of the snapshot, the journal, the durable range receipt, the publication
    receipt and the retraction plan receipt, the unread ledger path, the read,
    rotate and ensure operations of the epoch file, the text of an upsert
    error and the merge basis.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

val suffix : string

val journal_suffix : string

val epoch_suffix : string

val upsert_error_to_string : upsert_error -> string

val merge_basis :
  basis ->
  basis -> basis

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val journal_path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val durable_range_receipt_suffix : string

val durable_range_receipt_path : keepers_dir:string -> keeper_id:string -> string

val unread_ledger_path : keepers_dir:string -> keeper_id:string -> string

val publication_receipt_suffix : string

val publication_receipt_path : keepers_dir:string -> keeper_id:string -> string

val epoch_path : keepers_dir:string -> keeper_id:string -> string

val read_epoch :
  keepers_dir:string -> keeper_id:string -> (string option, string) result

val rotate_epoch :
  keepers_dir:string -> keeper_id:string -> (string, string) result

val ensure_epoch : keepers_dir:string -> keeper_id:string -> (string, string) result

val retraction_plan_receipt_suffix : string

val retraction_plan_receipt_path : keepers_dir:string -> keeper_id:string -> string
