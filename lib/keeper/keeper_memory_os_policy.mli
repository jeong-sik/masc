(** Keeper_memory_os_policy — deterministic importance scoring and
    retention decisions for the Memory OS. *)

open Keeper_memory_os_types

(** Explicit retention verdict. The librarian extracts facts; this
    policy decides how each fact should be materialised in working
    memory. *)
type retention_verdict =
  | KeepVerbatim
  | Summarize
  | ReferenceOnly
  | Discard

val default_lambda : float
val default_alpha : float
val keep_verbatim_score_threshold : float
val summarize_score_threshold : float

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

(** Map a score to a retention verdict using fixed thresholds. *)
val decide_retention : float -> retention_verdict

val verdict_to_string : retention_verdict -> string

(** [is_transient_admission_memory_text text] is true for live
    task-admission/capacity blocker snapshots such as "goal_cap 3/3
    blocks claims". These are useful in the turn that produced them, but
    stale quickly and must not be auto-recalled as durable constraints. *)
val is_transient_admission_memory_text : string -> bool

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
