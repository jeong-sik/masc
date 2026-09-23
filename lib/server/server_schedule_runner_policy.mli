(** Server-owned policy constants for the RFC-0234 schedule runner loop. *)

val interval_sec : float
(** Production runner cadence in seconds. *)

val stale_after_sec : float
(** Liveness warning threshold in seconds. This only affects health/dashboard
    projection; it never changes scheduling behavior. *)

val status_json : now:float -> Schedule_runner_status.snapshot -> Yojson.Safe.t
(** The runner's status as this server reports it, with this module's
    threshold. [/health] and the schedule list both render it here, so the
    two cannot disagree about whether the runner is stale. *)
