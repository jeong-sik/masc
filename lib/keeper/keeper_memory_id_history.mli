(** What the Memory commit log says one memory_id has been through.

    A write receipt and a retract receipt both name the [memory_id] they
    touched, but each says only what this call did: re-inserting a fact that
    was retracted a minute ago reads exactly like a first insert. A Keeper
    that alternates writes and retractions of one claim therefore sees no
    sign of it in its own receipts (task-1644: one turn wrote and retracted
    the same ids ten times each). This reads the id's past off the commit log
    the receipt's commit was appended to, so the receipt can carry it.

    Counts include the commit the receipt reports. Nothing here writes. *)

type t =
  { inserted : int
  (** Commits whose added facts include this id. *)
  ; retracted : int
  (** Removals of this id by an explicit retraction. *)
  ; removed_otherwise : int
  (** Removals of this id for any other reason: dropped, merged, revised,
      superseded, lost support or molted. *)
  ; last_retracted_at : float option
  (** Commit time of the latest retraction, when there was one. *)
  ; unreadable : int
  (** Commit log lines that did not decode. What they did is not known, so
      every count is a lower bound when this is not 0. *)
  ; folded : bool
  (** Compaction folded older commits into removal-only rows. Inserts from
      before the fold are not counted, so [inserted] is a lower bound. *)
  }

val of_history : memory_id:string -> Librarian_archive.history -> t

(** Reads the Keeper's commit log and cold archive. The error is the scan's,
    already a sentence. *)
val read : keepers_dir:string -> keeper_id:string -> memory_id:string -> (t, string) result

(** The receipt field for a read: the history, or why it is not known. A
    history that cannot be read does not fail the write it is reported on. *)
val receipt_field : (t, string) result -> string * Yojson.Safe.t
