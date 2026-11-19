(** The snapshot a commit leaves, as a pure function of the snapshot before it
    and the commit's line (RFC librarian-call-only-proposes §8.2 step 3).

    The snapshot keeps the bytes it has today: [revision], [updated_at],
    [source], [facts], [change]. Every one of them comes from the line, so a
    snapshot that was not written after its line was appended is written
    again from that line when the store boots, and has the same bytes. *)

module Current := Keeper_memory_os_current_types
module Digest := Agent_core.Checkpoint_objects

(** The digest a line names a snapshot by: SHA-256 of the bytes the snapshot
    codec writes. *)
val digest : Current.t -> Digest.digest

(** The snapshot of a Keeper that has none, written at its first boot.
    Revision 1, no fact, and [turn_log] as the trace of its source. *)
val empty : at:float -> turn_log:Keeper_turn_log.Log_id.t -> Current.t

type next =
  | Unchanged (** The commit changes no byte of the snapshot. *)
  | Rewritten of
      { snapshot : Current.t
      ; bytes : string (** What the snapshot file holds after the commit. *)
      }

type refusal =
  | Revision_not_next of
      { snapshot : int
      ; line : int
      }
  (** The line does not carry the revision after the snapshot's. *)
  | Facts_inconsistent of string
  (** Applying the line's effects holds one fact twice. *)
  | Not_encodable of string
  (** The snapshot codec does not write the result: a fact said to have lost
      its support names no premise it lacks, or names them out of order. *)

(** What a cause does to the snapshot, before its line exists. A direct write
    rewrites it: the facts are {!Librarian_effects.apply} of the effects, the
    revision is the one after [previous]'s, it was updated at [at], and its
    source is the write ([explicit_retract] for a retraction,
    [explicit_write] otherwise) on the trace the cause carries. An answer
    rewrites it the same way with [librarian] as the source's kind, when its
    effects add, see or remove a fact; an answer that does none of these
    leaves the bytes. A skip and an adoption leave the bytes. Never
    [Revision_not_next]. *)
val next
  :  previous:Current.t
  -> at:float
  -> Librarian_log.cause
  -> Librarian_effects.t
  -> (next, refusal) result

(** {!next} of a line's time, cause and effects. A line that rewrites the
    snapshot has to carry the revision {!next} gives. *)
val after : previous:Current.t -> Librarian_log.commit -> (next, refusal) result
