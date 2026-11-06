(** The server loop behind [until_github_run] (RFC-0379 §6.5).

    Every {!poll_interval_sec} it runs one {!Schedule_run_watch.tick}: each
    distinct GitHub run that a [Scheduled] one-shot Keeper wake waits for is
    read once with {!Server_github_run_reader.read}, and a schedule whose run
    completed becomes due at the current second. The schedule runner wakes the
    Keeper from there, as for any due schedule. Nothing is kept between passes:
    the schedule row is the only record of a watch, so a restart loses nothing. *)

val poll_interval_sec : float

val pause_after : now:float -> Schedule_run_watch.outcome list -> float
(** Seconds to wait before the next pass. {!poll_interval_sec}, or until the
    time GitHub gave when a read was rate limited. *)

val pass :
  now:(unit -> float) ->
  http_get:Server_repository_pulls.http_get ->
  config:Workspace.config ->
  float
(** One pass, logging each wake and each read that failed. Returns
    {!pause_after} its outcomes, or {!poll_interval_sec} when the schedule
    store cannot be read. *)

val run : clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Loops {!pass} with the production transport. A pass that raises is logged
    and the loop goes on; only cancellation ends it. *)
