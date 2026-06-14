(** Keeper_memory_os_policy — deterministic importance scoring for the
    Memory OS. *)

open Keeper_memory_os_types

val default_lambda : float
val default_alpha : float

(** Composite importance score for a fact.

    Score = confidence × recency × access_boost
    where recency follows an exponential forgetting curve and
    access_boost is [(1 + access_count) ** alpha]. *)
val score_fact : ?lambda:float -> ?alpha:float -> now:float -> fact -> float

(** Score an archived tool result. *)
val score_tool_result
  :  ?lambda:float
  -> ?alpha:float
  -> now:float
  -> created_at:float
  -> was_successful:bool
  -> access_count:int
  -> unit
  -> float

(** Lightweight keyword access bump.

    Increments [access_count] and updates [last_accessed] for facts
    whose claims contain at least one keyword from [turn_text]. This is
    a cheap, deterministic heuristic to approximate recall without an
    embedding model. *)
val bump_access_for_turn
  :  now:float
  -> fact list
  -> turn_text:string
  -> fact list
