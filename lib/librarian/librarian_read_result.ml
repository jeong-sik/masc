module Digest = Agent_core.Checkpoint_objects

type reach =
  { line : int
  ; within : Librarian_log.within
  ; covered : Keeper_turn_log.mark
  ; turn_log_offset : int
  }

type asked =
  | Read_range of Librarian_width.width
  | Read_item_alone

type question =
  { id : Librarian_question_id.t
  ; shown : Librarian_plan.read
  ; basis : Digest.digest
  ; reach : reach
  ; trace : string
  ; missing : Librarian_unit.missing_at list
  ; offered : Librarian_width.offered
  }

type failed =
  | Raised
  | Flow_stopped
  | Read_failed

type t =
  | Answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string
      }
  | Nothing_to_ask
  | No_answer of
      { question : question
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      }
  | Nothing_readable of
      { reach : reach
      ; missing : Librarian_unit.missing_at list
      ; offered : Librarian_width.offered
      }
  | Span_unknown of
      { before : Keeper_turn_log.mark
      ; reach : reach
      }
  | Memory_diverged of
      { expected : Digest.digest
      ; observed : Digest.digest
      }
  | Snapshot_fault of Librarian_snapshot_fault.t
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of failed
