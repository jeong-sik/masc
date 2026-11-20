module Digest = Agent_core.Checkpoint_objects

type asked = { trace : string }

type question =
  { id : Librarian_question_id.t
  ; memory : (string * string) list
  ; basis : Digest.digest
  ; trace : string
  }

type t =
  | Room_answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string
      }
  | Room_not_answered of
      { question : question
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      }
  | Room_memory_diverged of
      { expected : Digest.digest
      ; observed : Digest.digest
      }
  | Room_snapshot_fault of Librarian_snapshot_fault.t
  | Room_failed of Librarian_read_result.failed
