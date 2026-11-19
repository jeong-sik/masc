module Digest = Agent_core.Checkpoint_objects

type size_fact =
  | Input_too_large
  | Output_over_reserve
  | Window_reached

type refusal =
  | Sized of size_fact
  | Unsized

type silence =
  | Not_called
  | Unavailable
  | Busy
  | Lost
  | Unusable of Librarian_answer.rejection

type t =
  | Slot_answered
  | Refused of refusal
  | Silent of silence

type lane_result =
  { question : Librarian_question_id.t
  ; basis : Digest.digest
  ; head : Librarian_unit.item_ref
  ; offered : Librarian_unit.offered
  ; slots : (Librarian_memory_lane.slot_key * t) list
  }

type failed =
  | Raised
  | Flow_stopped

type question =
  { id : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  ; starts_after : Librarian_log.position
  ; through : Librarian_log.position
  ; covered : Keeper_turn_log.mark
  ; turn_log : Keeper_turn_log.Log_id.t
  ; turn_log_offset : int
  ; missing : Librarian_unit.missing_part list
  }

type ask_result =
  | Answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string
      ; offered : Librarian_unit.offered
      }
  | Nothing_to_ask
  | Refused_by_lane of lane_result
  | Silent_lane of lane_result
  | Nothing_readable of
      { through : Librarian_unit.item_ref
      ; missing : Librarian_unit.missing_part list
      }
  | Span_unknown of
      { line : int
      ; before : Keeper_turn_log.mark
      ; after : Keeper_turn_log.mark
      }
  | Memory_diverged of
      { expected : Digest.digest
      ; observed : Digest.digest
      }
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of failed
