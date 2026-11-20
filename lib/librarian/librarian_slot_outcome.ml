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
