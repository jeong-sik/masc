(** Keeper transient-retry backoff configuration. *)

val max_transient_retries : unit -> int
val transient_backoff_base_sec : unit -> float
val transient_backoff_cap_sec : unit -> float
val transient_backoff_sec : int -> float
val degraded_retry_slot_phase_budget_sec : float
