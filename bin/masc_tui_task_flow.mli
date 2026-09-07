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

type t = private {
  observed_at : float;
  window_started_at : float;
  current : counts;
  recent : window;
  oldest_open_created_at : float option;
  unparseable_timestamps : int;
}

val of_tasks : now:float -> Masc_domain.task list -> t
(** Counts current states plus creation/terminal timestamps within the preceding
    24 hours. Cancellation stays separate from completion. Invalid timestamps
    remain a visible count and do not become zero-time events. *)
val open_count : counts -> int
val total_count : counts -> int
