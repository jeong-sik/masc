(** Keeper_memory_os_policy — scoring and decay for Memory OS facts.

    Provides:
    - `score_fact` : compute a composite score from confidence, recency, category
    - `decay_stale` : update stale value based on elapsed time since last access
    - `recency_factor` : exponential decay based on time since last access
    - `decay_episodes` : apply decay to all facts in an episode

    Bug1 Fix: Previously, `score_fact` only computed scores without updating
    stale values. Now `decay_stale` is called to increment stale based on
    time elapsed since `last_accessed`, using configurable decay rate. *)

let default_lambda = 0.05
let default_alpha = 0.5

(** Exponential decay factor based on time since last access.
    Returns a value in (0, 1] where 1.0 means fully fresh. *)
let recency_factor ~now ~last_accessed =
  let elapsed = now -. last_accessed in
  (* Half-life of 3600 seconds (1 hour) — facts lose 50% recency weight per hour *)
  let half_life = 3600.0 in
  if elapsed <= 0.0 then 1.0
  else
    let decay = elapsed /. half_life in
    max 0.0 (1.0 -. 0.5 **. decay)

(** Compute stale value from elapsed time since last access.
    Stale ranges from 0.0 (fresh) to 1.0 (max stale).
    Uses linear decay with configurable rate. *)
let compute_stale ~now ~last_accessed ~rate =
  let elapsed = now -. last_accessed in
  if elapsed <= 0.0 then 0.0
  else
    let decay = elapsed *. rate in
    min 1.0 decay

(** Decay stale value for a single fact.
    Updates the fact's stale field based on time elapsed since last_accessed.
    Default decay rate: 1e-6 per second (~0.0864 per day, ~0.365 per month).
    This means a fact becomes "stale" (stale > 0.5) after ~5.8 days without access. *)
let decay_stale ?(rate = 1e-6) ~now fact =
  let stale = compute_stale ~now ~last_accessed:fact.last_accessed ~rate in
  { fact with stale }

(** Decay stale values for all facts in an episode. *)
let decay_episodes ~now ~rate episode =
  { episode with
    claims = List.map (decay_stale ~now ~rate) episode.claims
  }

(** Score a fact based on confidence, recency, and category.
    Returns a composite score in [0, 1]. *)
let score_fact ?(lambda = default_lambda) ?(alpha = default_alpha) ~now fact =
  let recency = recency_factor ~now ~last_accessed:fact.last_accessed in
  let category_weight =
    match fact.category with
    | "decision" | "constraint" -> 1.0
    | "progress" | "next" -> 0.8
    | "open_question" -> 0.6
    | "goal" -> 0.9
    | _ -> 0.5
  in
  let confidence_score = fact.confidence in
  let stale_penalty = fact.stale in
  let score =
    (lambda *. confidence_score)
    + (alpha *. recency)
    + ((1.0 -. lambda -. alpha) *. category_weight)
    -. stale_penalty
  in
  max 0.0 (min 1.0 score)