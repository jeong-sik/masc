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

(** RFC-0243: bounded EMA weight for a single re-observation (see [blend_confidence]). *)
val reaffirm_weight : float

(** Blend a prior confidence with a re-observed confidence (bounded EMA). The
    result is a convex combination of the two, so it stays in [0, 1] and moves a
    fixed fraction toward [observed]. *)
val blend_confidence : prior:float -> observed:float -> float

(** Fold a re-observation into an existing fact: blends confidence toward the
    re-observed value, increments [access_count], and refreshes [last_accessed]
    and [last_verified_at]. Identity and first-seen provenance are preserved.
    This is the write-time merge law that makes the score's re-observation
    signals live (RFC-0243). *)
val reobserve_fact : now:float -> existing:fact -> incoming:fact -> fact
