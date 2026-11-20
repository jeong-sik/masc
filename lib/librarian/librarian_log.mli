(** A line of a Keeper's commit log, [<keeper>.memory-log.jsonl]
    (RFC librarian-call-only-proposes §8.1).

    A change to Memory is committed when its line is on disk. The snapshot is
    rewritten from the line. The last line alone is enough to start again: it
    carries where reading stands and the working state, so every commit
    repeats them.

    The causes here are the ones a direct write, an operator's adoption, an
    answer and the reader's skip make. A skip names what it passed with a
    {!hole}; the holes of the width layer and of the operator's skips are
    added with the layer that makes them. *)

module Digest := Agent_core.Checkpoint_objects

(** How far into one unit of the turn log reading got. *)
type within =
  | Whole
  | Item of Librarian_unit.item_name
  (** Through this item: every item before it in the unit's order was read
      with it. *)

(** The last thing that was read. *)
type position =
  | Before_first
  | Through of
      { line : int (** Byte offset of the unit's line in the turn log. *)
      ; within : within
      }

(** What a [Skip] commit passed without a question answering it. *)
type hole =
  | Content_missing of Librarian_unit.missing_at list
  (** The range held no item that could be read, and these parts of its
      units were not there. *)
  | Unknown_span of
      { before : Keeper_turn_log.mark (** Where the stores ended before the reset. *)
      ; after : Keeper_turn_log.mark (** Where they ended after it. *)
      }
  (** An [Unannounced] reset with no unit holding an item before it. What lay
      between the two marks is not known. *)
  | Item_exceeds_window of Librarian_unit.missing_at list
  (** The head item fit no slot the lane declares, even alone: each one
      refused the item alone for the input's size (§7.4). These parts of its
      unit were not there. *)

(** What a [Read] question showed besides its units. *)
type shown =
  | With_memory (** Memory and the working state. *)
  | Item_alone of alone_working_state
  (** Nothing: its units were the head item alone (§7.4). *)

(** What the answer to a question of one item alone did with the working
    state it was not shown. *)
and alone_working_state =
  | Untouched (** It left it as it was. *)
  | Not_valid_alone
  (** It replaced it, and the commit kept it: an answer that did not see
      the working state cannot replace it. *)

type cause =
  | Direct of
      { by : Librarian_effects.actor
      ; trace : string
      (** The trace the write arrived on. The snapshot the commit leaves names
          it, so the snapshot can be written again from the line alone. *)
      ; write : Librarian_direct.write
      }
  | Adopt of
      { by : string (** The operator's name. *)
      ; observed : Digest.digest (** The snapshot bytes the operator named. *)
      }
  | Read of
      { question : Librarian_question_id.t
      ; shown : shown
      ; slot : string (** The id of the slot that answered. *)
      ; trace : string
      (** The trace the question's last unit names. The new facts carry it
          as their origin and the snapshot the commit leaves names it. *)
      ; missing : Librarian_unit.missing_at list
      (** What the question could not show of the units it read. *)
      }
  | Make_room of
      { question : Librarian_question_id.t
      ; slot : string (** The id of the slot that answered. *)
      ; trace : string
      (** The trace of the item read alone just before. A fact the answer
          merges or revises into carries it as its origin, and the snapshot
          the commit leaves names it. *)
      }
  (** An answer to the question that showed Memory and the working state and
      no unit, asked right after an item was read alone (§7.4). It does not
      move reading, so the line's [covers_through] is where that item ended.
      Only an answer that changes the snapshot or the working state is
      committed. *)
  | Skip of { hole : hole }

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

(** The snapshot a line says the file holds after it: [snapshot] of a
    [Started], [after] of a [Committed]. *)
val snapshot_after : line -> Digest.digest
