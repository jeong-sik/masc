(** Shared failure-only backoff for server observation workers. *)
val initial_delay_s : float
val next_delay_s : float -> float
