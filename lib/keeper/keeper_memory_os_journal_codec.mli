(** Pure journal encoding, decoding and read-side projection. Filesystem
    traversal, append ordering, receipt recovery and cache publication belong
    to [Keeper_memory_os_current]. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types

val librarian_failure_kind_to_string : librarian_failure_kind -> string
(** Canonical wire token for a closed failure kind. *)

val revision_links_to_json : revision list -> Yojson.Safe.t
val revision_links_of_json : Yojson.Safe.t -> (revision list, string) result
(** Exact directed identity pairs. Reject malformed, self and duplicate links. *)

val journal_revision_links :
  (string * Yojson.Safe.t) list -> (revision list option, string) result
(** [None] means that the row records no lineage evidence, distinct from an
    explicitly empty list of links. *)

val journal_commit_effect :
  (string * Yojson.Safe.t) list -> (commit_effect option, string) result
(** [None] means that the row does not state whether it rewrote the snapshot.
    An unknown present token is an error. *)

val links_applied_to_snapshot : t -> revision list -> bool
(** Every source is removed and every successor is present in the snapshot. *)

val journal_entry_to_json :
  ?program:Keeper_memory_os_program_types.publication ->
  commit_effect:commit_effect ->
  revision_links:revision list ->
  dropped_statements:dropped_statement list option ->
  t -> Yojson.Safe.t
(** Persisted commit row, including transition evidence. [None] makes no
    drop-reason statement; [Some []] explicitly records no drop statements. *)

val journal_failure_to_json :
  now:float -> trace_id:string -> kind:librarian_failure_kind -> detail:string ->
  snapshot_present:bool -> Yojson.Safe.t

val journal_quarantine_to_json :
  now:float -> rejection:string -> rejected_path:string -> Yojson.Safe.t
(** Encode observations with the caller's timestamp; neither reads a clock. *)

val journal_entry_of_json : Yojson.Safe.t -> (journal_entry, string) result
(** Reject unknown outcomes/kinds, missing or duplicate fields and inconsistent
    transition evidence. Keep failure and quarantine distinct from commits. *)

val journal_line_to_json : (journal_entry, string) result -> Yojson.Safe.t
(** Dashboard row. Decode errors remain visible rows; transition metadata is
    deliberately absent from this read-side format. *)

val journal_line_rewrote : Yojson.Safe.t -> bool
(** True only for an explicit rewrite marker. Callers must decode the whole row
    before using it as transition evidence. *)
