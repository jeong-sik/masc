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
    folded together: [rondo] and [keeper-rondo-agent] stay two rows. Nothing
    strips a loose "-agent" suffix, and which keeper an agent name
    belongs to is the agent record's stored binding rather than a spelling, so
    joining the two here would both guess from the spelling and hide that
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

(** The tasks [masc_gc] moved out of the backlog, as the flow counts them:
    for each, its id, its registration time and how it ended (still open,
    completed at, cancelled at), with the times parsed. Nothing else of the
    task is kept. The ids stay because a task restored to the backlog counts
    once, as live, and the backlog moves; the times stay because the 24 hour
    window moves with the clock. *)
module Archived : sig
  type t

  val empty : t

  val add : t -> Masc_domain.task -> t
  (** One more archived task. A repeated id is another task, as in the
      archive file. *)
end

val of_tasks : now:float -> archived:Archived.t -> Masc_domain.task list -> t
(** Counts current states plus creation/terminal timestamps within the preceding
    24 hours. Cancellation stays separate from completion. Invalid timestamps
    remain a visible count and do not become zero-time events. [archived]
    counts in [recent], [daily], the invalid timestamps and the oldest open
    registration, never in [current] or [by_assignee], and one whose id is
    also live is counted once, as live. *)
val open_count : counts -> int
val total_count : counts -> int
