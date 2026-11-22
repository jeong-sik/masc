(** The journal reads, the program anchor and the lookups of dropped facts:
    the program reset, the journal tail reads, the removal lookup, the program
    anchor with its capture and verification, the journal mention and the drop
    reason of a fact, the search for a removal, the read of dropped facts, and
    the retirement context with the facts that a retirement targets.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

val with_program_reset :
  keepers_dir:string -> keeper_id:string -> (unit -> ('a, string) result) -> ('a, string) result

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
  ; anchor_snapshot_bytes : string option
  ; anchor_identity : Keeper_memory_os_program_types.store_anchor
  }

val program_anchor_snapshot : program_anchor -> t option

val capture_program_anchor :
  keepers_dir:string -> keeper_id:string -> (program_anchor, string) result

type program_anchor_evidence
val program_anchor_evidence : program_anchor -> program_anchor_evidence
val program_anchor_evidence_to_json : program_anchor_evidence -> Yojson.Safe.t
val program_anchor_evidence_of_json : Yojson.Safe.t -> (program_anchor_evidence, string) result
val program_anchor_evidence_matches_publication : program_anchor_evidence ->
  Keeper_memory_os_program_types.publication -> (unit, string) result
(** Pure exact join of the retained keeper, captured identity and original
    full facts with a publication. It grants no live store or ACK authority. *)
(** Pure exact evidence codec, including the captured full snapshot and journal
    prefix. Decoding validates its internal identities but grants no live
    Memory or publication authority. Retain once at the first floor step. *)
val resume_program_anchor : keepers_dir:string -> keeper_id:string ->
  program_anchor_evidence -> (program_anchor, string) result
(** Recover pending publication, then rejoin the exact recorded incarnation,
    journal prefix and snapshot lineage under Memory locks. Preserve the
    original anchor. A reset, ABA, missing transition or changed captured fact
    refuses; unrelated compatible additions may remain. May perform the
    standard publication recovery. Caller retains source-owner serialization;
    never invoke from a Memory-locked callback. *)

val verify_program_anchor :
  keepers_dir:string ->
  keeper_id:string ->
  program_anchor ->
  snapshot_content:string option ->
  t option ->
  Keeper_memory_os_program_types.t ->
  (Keeper_memory_os_program_types.store_anchor, string) result

val read_program_journal_target_locked :
  keepers_dir:string -> keeper_id:string -> transaction_id:string ->
  snapshot_content:string option -> t option ->
  ((Keeper_memory_os_program_types.publication * t) option, string) result
(** Low-level journal data read. Caller holds aggregate/snapshot locks. Require
    one actual marked transaction, exact locked prefix, current incarnation
    and all later snapshot transitions. This does not validate range receipts
    and supplies no committed-program or source settlement authority. *)

val find_removal :
  keepers_dir:string -> keeper_id:string -> string -> removal_lookup

val find_removal_inline :
  keepers_dir:string -> keeper_id:string -> string -> removal_lookup
(** Synchronous variant for callers already holding Memory OS file locks;
    never dispatches a [Domain_pool_ref] job under locks. *)

type archived_fact =
  { original : fact
  ; removal : removal
  }

val read_dropped :
  keepers_dir:string -> keeper_id:string ->
  current_facts:fact list ->
  (archived_fact list, string) result

type commit_lineage =
  { revisions : revision list
  (** Revision links of committed journal rows, in journal order: each names a
      fact the commit removed and the successor it kept. *)
  ; retractions : string list
  (** One memory id per fact an explicit retraction removed, in journal order,
      with repeats when the same claim was stored and retracted again. *)
  }

val read_commit_lineage :
  keepers_dir:string -> keeper_id:string -> (commit_lineage, string) result
(** Revisions and explicit retractions as the committed journal records them.
    The journal row is part of the commit (written by it or recovered from its
    publication receipt), so a commit cannot keep its snapshot and lose this
    lineage. Recovers a prepared publication first, as public snapshot reads
    do, then scans the complete journal in an IO pool job. A missing journal is
    no lineage; a malformed or unreadable journal, or a pending removal
    receipt, is an error, not an empty lineage. Rows that predate
    [revision_links] contribute no revisions. *)

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
