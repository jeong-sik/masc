type size_fact =
  | Input_too_large
  | Output_over_reserve
  | Window_reached

type refusal =
  | Sized of size_fact
  | Unsized

type 'rejection silence =
  | Not_called
  | Unavailable
  | Busy
  | Overdue
  | Lost
  | Unusable of 'rejection

type 'rejection unanswered =
  | Refused of refusal
  | Silent of 'rejection silence

type 'rejection t =
  | Slot_answered
  | Unanswered of 'rejection unanswered
