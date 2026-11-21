(** How one ask of the question that makes room ended (RFC
    librarian-call-only-proposes §7.4, §9.3). The RFC names this type
    [room_result].

    Making room shows Memory and the working state and no unit, so it reads
    no turn log: no input fault and nothing to read can end it. *)

module Digest := Agent_core.Checkpoint_objects

(** What the writer asks for. *)
type asked =
  { trace : string
  (** The trace of the item read alone just before, or the structural trigger
      trace when [molt_trigger = Some _]. A fact an answer merges or revises
      into carries it as its origin. *)
  ; molt_trigger : Librarian_lifecycle.molt_trigger option
  (** [None] for a reactive [Make_room] ask; [Some trigger] for a proactive
      structural [Molt_and_synthesize] ask that commits through
      {!Librarian_store.commit_molt} followed by {!Librarian_store.compact_log}. *)
  }

(** What the question showed, as the writer commits it. *)
type question =
  { id : Librarian_question_id.t
  ; memory : (string * string) list
  (** Short name and Memory id of every fact shown
      ({!Librarian_plan.Room}). *)
  ; basis : Digest.digest (** The snapshot the question showed. *)
  ; trace : string (** [asked.trace]. *)
  }

type t =
  | Room_answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string (** The id of the slot that answered. *)
      }
  | Room_not_answered of
      { question : question
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      (** Every slot of the lane value the walk started with, as in
          {!Librarian_read_result.No_answer}. *)
      }
  (** No slot answered: the RFC's [Room_refused] and [Room_silent]. *)
  | Room_memory_diverged of
      { expected : Digest.digest (** The snapshot the last commit line names. *)
      ; observed : Digest.digest (** The snapshot the file holds. *)
      }
  | Room_snapshot_fault of Librarian_snapshot_fault.t
  (** The snapshot file is not one the store opens, as for a reading
      question. *)
  | Room_failed of Librarian_read_result.failed
