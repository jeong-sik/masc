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
  | Rewritten of Current.t

type refusal =
  | Revision_not_next of
      { snapshot : int
      ; line : int
      }
  (** The line does not carry the revision after the snapshot's. *)
  | Facts_inconsistent of string
  (** Applying the line's effects holds one fact twice. *)

(** A direct write rewrites the snapshot: its facts are
    {!Librarian_effects.apply} of the line's effects, its revision is the
    line's, it was updated when the line was written, and its source is the
    write ([explicit_retract] for a retraction, [explicit_write] otherwise)
    on the trace the line carries. An adoption leaves the bytes the operator
    named. *)
val after : previous:Current.t -> Librarian_log.commit -> (next, refusal) result
