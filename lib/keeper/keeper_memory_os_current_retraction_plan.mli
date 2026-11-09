(** The retraction plan receipt: the record of one retraction batch with the
    plan id, the prior and target revision and digest, the dropped statements
    and the revision links, its JSON encoder, decoder and parse, the read,
    write and remove of the receipt file, the append of the removal journal
    entry that clears the receipt, the journal checks for a rewrite line and
    for an entry, and the reconcile of a receipt left on disk.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

type retraction_plan_receipt =
  { plan_id : string option
      (* [Some id] belongs to the exact batch API. [None] preserves an
         ordinary removal without claiming an operator-approved plan. *)
  ; prior_revision : int
  ; prior_snapshot_sha256 : string
  ; target_revision : int
  ; target_snapshot_sha256 : string
  ; dropped_statements : dropped_statement list
  ; revision_links : revision list
  }

val parse_retraction_plan_receipt :
  path:string -> string -> (retraction_plan_receipt, string) result

val read_retraction_plan_receipt :
  keepers_dir:string ->
  keeper_id:string -> (retraction_plan_receipt option, string) result

val write_retraction_plan_receipt :
  keepers_dir:string ->
  keeper_id:string -> retraction_plan_receipt -> (unit, string) result

val remove_retraction_plan_receipt :
  keepers_dir:string -> keeper_id:string -> (unit, string) result

val reconcile_retraction_plan_receipt :
  keepers_dir:string ->
  keeper_id:string ->
  snapshot:(t * string) option ->
  (unit, string) result
