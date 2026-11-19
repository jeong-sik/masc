(** A line of a Keeper's commit log, [<keeper>.memory-log.jsonl]
    (RFC librarian-call-only-proposes §8.1).

    A change to Memory is committed when its line is on disk. The snapshot is
    rewritten from the line. The last line alone is enough to start again: it
    carries where reading stands and the working state, so every commit
    repeats them.

    The causes here are the ones a direct write and an operator's adoption
    make. The causes of an answer and of a skip are added with the layers
    that produce them. *)

module Digest := Agent_core.Checkpoint_objects

(** How far into one unit of the turn log reading got. *)
type within =
  | Whole
  | Item of int (** Through this item of the unit, counted from 0. *)

(** The last thing that was read. *)
type position =
  | Before_first
  | Through of
      { line : int (** Byte offset of the unit's line in the turn log. *)
      ; within : within
      }

type cause =
  | Direct of
      { by : Librarian_effects.actor
      ; write : Librarian_direct.write
      }
  | Adopt of
      { by : string (** The operator's name. *)
      ; observed : Digest.digest (** The snapshot bytes the operator named. *)
      }

type commit =
  { seq : int
  ; at : float
  ; basis : Digest.digest (** The snapshot before the commit. *)
  ; after : Digest.digest (** The snapshot after it. [basis] when no byte changes. *)
  ; revision : int (** The snapshot's revision after the commit. *)
  ; cause : cause
  ; effects : Librarian_effects.t
  ; turn_log : Keeper_turn_log.Log_id.t
  ; turn_log_offset : int
  (** Byte offset of the first unread line in that turn log. A reader starts
      there without scanning. *)
  ; covers_through : position
  ; covered : Keeper_turn_log.mark
  (** Where the stores ended at [covers_through]. A Keeper request starts
      from it also when the turn log cannot be read. *)
  ; working_state : string option
  }

type line =
  | Started of
      { at : float
      ; turn_log : Keeper_turn_log.Log_id.t
      ; snapshot : Digest.digest
      ; revision : int
      ; turn_log_offset : int
      ; covered : Keeper_turn_log.mark
      }
  (** Nothing of that turn log has been read. *)
  | Committed of commit
