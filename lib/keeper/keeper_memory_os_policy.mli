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

(** Tokenise fact content into lowercase alphanumeric words >= 3 chars. *)
val fact_tokens : string -> string list

(** Jaccard-like overlap ratio between two token sets. *)
val token_overlap_ratio : string list -> string list -> float

(** Compute contradict multiplier for a fact given other candidate facts.
    Returns 1.0 (no penalty) when no contradict evidence is found. *)
val contradict_multiplier : ?other_facts:fact list -> fact -> float

(** Composite importance score for a fact.

    Score = confidence × access_recency × truth_recency ×
    stale_penalty × access_boost × contradict_mult.

    [other_facts] feeds the contradict detection — any fact with >= 30%
    token overlap and higher confidence reduces the score proportionally. *)
val score_fact
  :  ?lambda:float
  -> ?alpha:float
  -> ?other_facts:fact list
  -> now:float
  -> fact
  -> float

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

(** Lightweight keyword access bump. *)
val bump_access_for_turn
  :  now:float
  -> fact list
  -> turn_text:string
  -> fact list

(** Find facts that contradict a given observation token set.
    Returns facts with >= [min_overlap] token overlap and confidence > 0.5. *)
val find_contradictors
  :  ?min_overlap:float
  -> string list
  -> fact list
  -> fact list