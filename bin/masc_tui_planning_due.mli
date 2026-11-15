(** Whether a Goal still at work has passed the day it was due (#39571).

    A Goal three days past its due date in [executing] drew the same row as
    one due next week: the list printed the phase, and the due date was a
    string the detail printed and the due sort compared, which nothing held
    against the clock. The list, its preview and the detail read this one
    standing, so a row that says a Goal is past due opens on a detail that
    says so too.

    A Goal is at work in [Executing] and [Verifying], the two phases whose
    next move belongs to the workspace. Awaiting confirmation, paused,
    blocked, completed and dropped Goals wait on the operator or are over,
    so their due date is not read.

    The due date is read by {!Goal_due}, the reader the store and Candle use:
    a Goal falls due at 23:59:59 UTC of its day, whatever the operator's zone.

    Display only. Passing the due date closes nothing, moves no phase and tells
    no one; the standing is what the operator reads.

    Pure: [now] is the caller's, and nothing here reads a clock. *)

type standing =
  | Due_passed  (** At work, and [now] is later than the moment it fell due. *)
  | Due_ahead  (** At work, and it falls due at [now] or later. *)
  | Not_in_progress  (** Not at work. Its due date is not read. *)
  | No_due  (** At work, with no due date. *)
  | Unreadable_due of string
      (** At work, with a due date {!Goal_due} cannot read, kept as written.
          Whether it has passed is not known, so it is neither
          {!Due_passed} nor {!No_due}. *)

val standing : now:Ptime.t -> Masc.Tui_decode.planning_goal -> standing
