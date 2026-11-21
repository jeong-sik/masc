type size_fact = Exact_lane_slot_outcome.size_fact =
  | Input_too_large
  | Output_over_reserve
  | Window_reached

type refusal = Exact_lane_slot_outcome.refusal =
  | Sized of size_fact
  | Unsized

type 'rejection silence_of = 'rejection Exact_lane_slot_outcome.silence =
  | Not_called
  | Unavailable
  | Busy
  | Overdue
  | Lost
  | Unusable of 'rejection

type silence = Librarian_answer.rejection silence_of

type 'rejection unanswered_of = 'rejection Exact_lane_slot_outcome.unanswered =
  | Refused of refusal
  | Silent of 'rejection silence_of

type unanswered = Librarian_answer.rejection unanswered_of

type 'rejection t_of = 'rejection Exact_lane_slot_outcome.t =
  | Slot_answered
  | Unanswered of 'rejection unanswered_of

type t = Librarian_answer.rejection t_of
