module Tui_decode = Masc.Tui_decode

type standing =
  | Due_passed
  | Due_ahead
  | Not_in_progress
  | No_due
  | Unreadable_due of string

(* The phase decides first: a Goal that is over or waiting on the operator has
   no race with its date, so even an unreadable date is not this module's to
   report for it. *)
let standing ~now (goal : Tui_decode.planning_goal) =
  match goal.pg_phase with
  | Goal_phase.Awaiting_confirmation | Goal_phase.Completed | Goal_phase.Dropped
  | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
      Not_in_progress
  | Goal_phase.Executing | Goal_phase.Verifying -> (
      match Goal_due.read goal.pg_due_date with
      | Goal_due.No_due_date -> No_due
      | Goal_due.Unreadable_due_date raw -> Unreadable_due raw
      | Goal_due.Due_date { instant } ->
          if Ptime.is_later now ~than:instant then Due_passed else Due_ahead)
