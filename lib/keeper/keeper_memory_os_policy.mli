(** Keeper_memory_os_policy — deterministic importance scoring for the
    Memory OS. *)

open Keeper_memory_os_types

val default_lambda : float
val default_alpha : float
val default_truth_lambda : float
val default_max_access_factor : float
val default_discard_score_threshold : float

type retention_verdict =
  | KeepVerbatim
  | Discard

(** Composite importance score for a fact.

    Score = confidence × access_recency × truth_recency ×
    stale_penalty × access_boost.  [access_recency] uses
    [last_accessed], while [truth_recency] uses [last_verified_at] or
    [first_seen] so recall cannot make an unverified claim fresh again. *)
val score_fact : ?lambda:float -> ?alpha:float -> now:float -> fact -> float

val truth_recency_factor : ?lambda:float -> now:float -> fact -> float
val stale_penalty : fact -> float
val decide_retention : ?discard_threshold:float -> float -> retention_verdict

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
