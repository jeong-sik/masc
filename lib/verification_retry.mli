(** A transient verification retries when its earliest actual candidate can serve. *)
val delay_of_paths :
  retry_interval_sec:float -> now:float -> Keeper_turn_driver.path_rest list -> float
val delay : retry_interval_sec:float -> now:float -> string list -> float
