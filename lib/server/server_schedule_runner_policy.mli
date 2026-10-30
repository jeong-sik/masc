(** Server-owned policy constants for the RFC-0234 schedule runner loop. *)

val interval_sec : float
(** Production runner cadence in seconds. *)

val stale_after_sec : float
(** Liveness warning threshold in seconds. This only affects health/dashboard
    projection; it never changes scheduling behavior. *)

val status :
  now:float -> Schedule_runner_status.snapshot -> Schedule_contract_values.runner_status
(** The runner's status word with this module's threshold: the word the
    schedule list reports as [schedule_runner.status]. *)

val status_json : now:float -> Schedule_runner_status.snapshot -> Yojson.Safe.t
(** [/health]'s [schedule_runner] object, whose [status] is {!status}. The two
    are computed with one threshold, so for the same snapshot and [now] they
    say the same word. They can still disagree for a while: the fleet schedule
    list is served from the dashboard cache, which the runner loop clears on
    every tick it records, so while no tick is recorded the list can trail
    [/health] by up to that cache's lifetime. *)
