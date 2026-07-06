(** Server-owned policy constants for the RFC-0234 schedule runner loop. *)

val interval_sec : float
(** Production runner cadence in seconds. *)

val stale_after_sec : float
(** Liveness warning threshold in seconds. This only affects health/dashboard
    projection; it never changes scheduling behavior. *)
