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

(** What a question read and showed, as the writer commits it (§8.1, §8.4).
    The question's text is not here: the ask sends it and the writer does
    not read it. Where reading started and which turn log it read are the
    writer's own tail: an event that moves either cancels the ask, and an
    [Ask_ended] of another ask is dropped. *)
type question =
  { id : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  (** [shown.memory] is [Some] exactly when the question showed Memory. *)
  ; reach : reach
  ; trace : string
  (** The trace the last unit's line names: [after.trace] of a [Closed],
      [before.trace] of a [Reset]. New facts carry it as their origin, and
      the snapshot the commit leaves names it. *)
  ; missing : Librarian_unit.missing_at list
  }

(** The walk or the read stopped on masc's side. Not a slot's outcome. Its
    text goes to the structured log. *)
type failed =
  | Raised (** The ask raised. *)
  | Flow_stopped
  (** A measurement or an attempt could not start, or a callback failed. *)
  | Read_failed
  (** The turn log or a byte file of a unit could not be read: an IO
      error, or the file changed while it was read. *)

type t =
  | Answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string (** The id of the slot that answered. *)
      }
  | Nothing_to_ask
  | No_answer of
      { slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
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
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of failed
