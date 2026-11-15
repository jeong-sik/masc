(** The snapshot and journal reads, the program anchor and the lookups of
    dropped facts: the program reset, the content and digest reads and the
    locked read of a Keeper's snapshot, the journal tail reads, the removal
    lookup, the program anchor with its capture and verification, the journal
    mention and the drop reason of a fact, the search for a removal, the read
    of dropped facts, and the retirement context with the facts that a
    retirement targets.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

val with_program_reset :
  keepers_dir:string -> keeper_id:string -> (unit -> ('a, string) result) -> ('a, string) result

val read_locked_for_keepers_dir : keepers_dir:string -> keeper_id:string -> (t option, string) result

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val read_with_snapshot_sha256 :
  keepers_dir:string -> keeper_id:string -> ((t * string) option, string) result

val read_journal_tail_indexed :
  keepers_dir:string ->
  keeper_id:string ->
  limit:int ->
  ((int * (journal_entry, string) result) list, string) result

val read_journal_tail :
  keepers_dir:string
  -> keeper_id:string
  -> limit:int
  -> ((journal_entry, string) result list, string) result

type removal_lookup =
  | Removed of removal
  | No_removal_recorded
  | Journal_unreadable of string

type program_anchor =
  { anchor_keeper : string
  ; anchor_snapshot : t option
  ; anchor_identity : Keeper_memory_os_program_types.store_anchor
  }

val program_anchor_snapshot : program_anchor -> t option

val capture_program_anchor :
  keepers_dir:string -> keeper_id:string -> (program_anchor, string) result

val verify_program_anchor :
  keepers_dir:string ->
  keeper_id:string ->
  program_anchor ->
  snapshot_content:string option ->
  t option ->
  Keeper_memory_os_program_types.t ->
  (Keeper_memory_os_program_types.store_anchor, string) result

val find_removal :
  keepers_dir:string -> keeper_id:string -> string -> removal_lookup

type archived_fact =
  { original : fact
  ; removal : removal
  }

val read_dropped :
  keepers_dir:string -> keeper_id:string ->
  current_facts:fact list ->
  (archived_fact list, string) result

type retirement_context =
  | Retirement_source_changed
  | Retirement_source_unavailable of string
  | Retirement_archive of (archived_fact list, string) result

val read_retirement_context :
  keepers_dir:string -> keeper_id:string -> expected_revision:int option ->
  current_facts:fact list -> retirement_context

val targets_retired_since :
  keepers_dir:string ->
  keeper_id:string ->
  revision:int option ->
  held:int option ->
  Set_util.StringSet.t -> (Set_util.StringSet.t, string) result
