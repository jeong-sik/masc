(** How one ask of a reading question ended, and what the writer commits
    from it (RFC librarian-call-only-proposes §7.1, §7.3, §9.1). The RFC
    names this type [read_result]; §7.1 calls it [ask_result].

    The writer's decision reads these values without depending on the
    module that asks, so the types live apart from it. *)

module Digest := Agent_core.Checkpoint_objects

(** Where reading stands once a result is committed, and what the commit
    line records of it. A [Read] and a [Skip] commit both write these three
    values as they are; the writer does not read the turn log again. *)
type reach =
  { line : int (** Byte offset of the last unit's line that was read. *)
  ; within : Librarian_log.within
  ; covered : Keeper_turn_log.mark
  (** [Whole]: where the unit after it starts. [Item _]: where this unit
      starts, so a Keeper request carries the whole unit again. *)
  ; turn_log_offset : int
  (** [Whole]: the byte offset just past [line]. [Item _]: [line] itself,
      since the unit is not finished. *)
  }

(** What the writer asks an ask for. *)
type asked =
  | Read_range of Librarian_width.width
  (** The unread range at a width, with Memory and the working state (§7.6). *)
  | Read_item_alone
  (** The head item, with no Memory and no working state (§7.4). The writer
      asks it only after every slot it declares refused the head item with
      Memory for the input's size. *)

(** What a question read and showed, as the writer commits it (§8.1, §8.4).
    The question's text is not here: the ask sends it and the writer does
    not read it. Where reading started and which turn log it read are the
    writer's own tail: an event that moves either cancels the ask, and an
    [Ask_ended] of another ask is dropped. *)
type question =
  { id : Librarian_question_id.t
  ; shown : Librarian_plan.read
  ; basis : Digest.digest
  (** The snapshot the tail named when the question was made, whether or not
      it showed Memory. A one-item verdict is read only while this is the
      snapshot now: a verdict about another Memory version is not one about
      this (§7.4 「옛 Memory 를 두고 한 판정으로 내려가지 않는다」). *)
  ; reach : reach
  ; trace : string
  (** The trace the last unit's line names: [after.trace] of a [Closed],
      [before.trace] of a [Reset]. New facts carry it as their origin, and
      the snapshot the commit leaves names it. *)
  ; missing : Librarian_unit.missing_at list
  ; offered : Librarian_width.offered
  (** What the question carried. The writer narrows by it when the lane
      refuses the question, and counts what a commit passed by it. *)
  }

(** The walk or the read stopped on masc's side. Not a slot's outcome. Its
    text goes to the structured log. *)
type failed =
  | Raised (** The ask raised. *)
  | Flow_stopped
  (** A measurement or an attempt could not start, a callback failed, or the
      writer was no longer open. *)
  | Read_failed
  (** The turn log or a byte file of a unit could not be read: an IO error,
      or the file changed while it was read. *)

type t =
  | Answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string (** The id of the slot that answered. *)
      }
  | Nothing_to_ask
  | No_answer of
      { question : question (** The question no slot answered. *)
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      (** Every slot of the lane value the walk started with: the admitted
          HTTP slots, then the declared CLI slots, each in declared order.
          The writer reads only the slots the lane declares now; whether
          one of those refused is the RFC's [Refused_by_lane], otherwise
          [Silent_lane]. *)
      }
  (** No slot answered. *)
  | Nothing_readable of
      { reach : reach
      ; missing : Librarian_unit.missing_at list
      ; offered : Librarian_width.offered
      (** What the range would have carried. The skip passes it. *)
      }
  (** The range holds no item that can be read. *)
  | Span_unknown of
      { before : Keeper_turn_log.mark
      ; reach : reach
      (** Through the [Unannounced] reset's line, [Whole]: [covered] is the
          line's [after]. *)
      }
  (** An [Unannounced] reset with no unit holding an item before it. No
      model is called. *)
  | Memory_diverged of
      { expected : Digest.digest (** The snapshot the last commit line names. *)
      ; observed : Digest.digest (** The snapshot the file holds. *)
      }
  | Snapshot_fault of Librarian_snapshot_fault.t
  (** The file at the snapshot path is not one the store opens: no file,
      not a regular file, a failed read, or bytes the tail names that do not
      decode. The file is read as the store reads it before a commit, and
      the writer stops for it as the store does. *)
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of failed
