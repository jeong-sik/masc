(** Keeper supervisor runtime configuration. *)

val sweep_interval_default_sec : float
val sweep_interval_min_sec : float
val sweep_interval_max_sec : float
val sweep_interval_sec : unit -> float
(** Finite interval within the same bounds as TOML and Runtime_params. *)
