(** A transient verification retries when its earliest actual candidate can serve. *)
val delay_of_paths :
  retry_interval_sec:float -> now:float -> Keeper_turn_driver.path_rest list -> float
val delay : retry_interval_sec:float -> now:float -> string list -> float

val provider_rest : string -> Task.Anti_rationalization.provider_rest
(** Whether a review candidate's path rests until a time its provider stated,
    read now from the stores the provider walk writes — the same rest
    {!delay} dates the retry from. [Rests_until_stated_end] while that time is
    ahead; [No_stated_rest] for a serving path, a rest with no stated end, and
    an id the runtime table cannot resolve. *)
