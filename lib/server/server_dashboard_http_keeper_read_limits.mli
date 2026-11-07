(** Limits and cache lifetimes that more than one keeper read route uses. *)

val trajectory_max_limit : int
(** The most trajectory or trace entries one query returns. *)

val keeper_hot_path_cache_ttl_s : float
(** Seconds a polled keeper read stays cached. *)
