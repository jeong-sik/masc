(** Work outcomes from the full durable task snapshot. Built on refresh, never
    by scanning/parsing task history on a render frame. *)
type counts = {
  todo : int;
  claimed : int;
  in_progress : int;
  awaiting_verification : int;
  completed : int;
  cancelled : int;
}

type window = { created : int; completed : int; cancelled : int }

(** One row per [assignee] string exactly as the Task recorded it. Nothing is
    folded together: [rondo] and [keeper-rondo-agent] stay two rows. RFC-0393
    removed the loose "-agent" suffix strip, and which keeper an agent name
    belongs to is the agent record's stored binding rather than a spelling, so
    joining the two here would both reinstate the removed guess and hide that
    the writers disagree about what they record. *)
type assignee_flow = {
  af_assignee : string;
  af_done : int;
  af_open : int;
      (** [Claimed] + [InProgress] + [AwaitingVerification] -- the states that
          carry an assignee. [Cancelled] carries [cancelled_by], which names
          who cancelled rather than who held the task, so it is counted in
          neither field. *)
  af_median_lead_hours : float option;
      (** Median [completed_at - created_at] across this assignee's [Done]
          tasks. Lead time, not work time: [Done] carries no [started_at], so
          a task that waited a week before a minute of work reads as a week.
          [None] when no [Done] task had both timestamps parseable. *)
}

(** One UTC day. [d_start] is that day's midnight. *)
type day = {
  d_start : float;
  d_created : int;
  d_completed : int;
  d_cancelled : int;
}

val daily_days : int
(** How many UTC days [daily] spans, ending on the day [now] falls in. *)

type t = private {
  observed_at : float;
  window_started_at : float;
  current : counts;
  recent : window;
  oldest_open_created_at : float option;
  unparseable_timestamps : int;
  by_assignee : assignee_flow list;
      (** Descending by [af_done], then [af_open], then assignee, so one
          snapshot always orders the same way. *)
  daily : day list;
      (** Ascending by [d_start], every day in the span present. A quiet day
          is a row of zeroes rather than a missing row, so a gap reads as a
          gap. *)
}

val of_tasks : now:float -> Masc_domain.task list -> t
(** Counts current states plus creation/terminal timestamps within the preceding
    24 hours. Cancellation stays separate from completion. Invalid timestamps
    remain a visible count and do not become zero-time events. *)
val open_count : counts -> int
val total_count : counts -> int
