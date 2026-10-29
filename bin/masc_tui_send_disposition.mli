(** What Enter will do for the currently selected conversation. A retained
    preflight can keep a new line local until the operator resumes it. *)
type 'request t =
  | Sends
  | Updates of 'request
  | Queues_until_resume

val of_state : inflight:'request option -> waiting:'request option -> 'request t
