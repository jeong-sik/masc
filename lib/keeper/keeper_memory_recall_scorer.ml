(** Keeper_memory_recall_scorer — post-processing ranker that applies
    Cognitive_gravity to already-scored Memory OS facts.

    Layer 2 in the task-1258 integration architecture:

      Layer 1: score_fact (policy.ml)       — per-fact contradict penalty
      Layer 2: recall_scorer (this module)  — gravity re-rank
      Layer 3: combined score → final order

    This module is deliberately separate from evaluate_memory_recall
    (keeper_memory_recall.ml) to keep the 37KB pipeline file unchanged
    and minimise regression risk. *)

type scored_fact = {
  fact : Keeper_memory_os_types.fact;
  base_score : float;
  gravity_factor : float;
  combined : float;
}

(** How far back to look for recency (seconds). 7 days default —
    aligns with policy.ml's default_lambda half-life. *)
let default_recency_window = 86400.0 *. 7.0

(** Minimum frequency_weight to avoid throwing off the gravity blend
    for facts seen only once. *)
let min_frequency_weight = 0.1

(** Convert a [fact] into a [Cognitive_gravity.item] with payload as the
    fact's claim text for jaccard comparison. *)
let fact_to_gravity_item ~now fact =
  let recency =
    Float.max 0.0 (now -. fact.last_accessed)
  in
  let frequency =
    Float.max min_frequency_weight (float (max 1 fact.access_count))
  in
  Cognitive_gravity.(
    {
      payload = fact.claim;
      keywords = Keeper_memory_os_policy.fact_tokens fact.claim;
      recency_seconds = recency;
      frequency_weight = frequency;
    })

(** Compute the gravity factor for a single fact, given the full set of
    ranked gravity results.

    [gravity_factor] is normalised to [0.0, 1.0] from Cognitive_gravity's
    raw gravity_score by dividing by the max gravity_score in the set.
    When the set has one element or max is 0.0, returns 1.0 (no distortion). *)
let gravity_factor_for_fact ~gravity_results fact =
  let max_gravity =
    gravity_results
    |> List.map (fun (_, g) -> g)
    |> List.fold_left Float.max 0.0
  in
  if max_gravity = 0.0 then 1.0
  else
    let payload_match = fun (item, _) -> item.Cognitive_gravity.payload = fact.claim in
    match List.find_opt payload_match gravity_results with
    | None -> 1.0
    | Some (_, g) -> g /. max_gravity
;;

(** Weighted blend: combined = base_score × (0.7 + 0.3 × gravity_factor).
    The 0.7 floor ensures gravity can boost but never override the policy
    score entirely. *)
let combine ~base_score ~gravity_factor =
  base_score *. (0.7 +. 0.3 *. Float.max 0.0 (Float.min 1.0 gravity_factor))
;;

(** [score ~query facts] applies Cognitive_gravity ranking over the
    given facts and returns them sorted by combined score descending. *)
let score ~query facts =
  let now = Unix.gettimeofday () in
  let items = List.map (fact_to_gravity_item ~now) facts in
  let gravity_results = Cognitive_gravity.rank items in
  let scored =
    List.map (fun fact ->
      let base_score =
        Keeper_memory_os_policy.score_fact
          ~other_facts:facts
          ~seed_tokens:query
          ~now
          fact
      in
      let gravity_factor = gravity_factor_for_fact ~gravity_results fact in
      let combined = combine ~base_score ~gravity_factor in
      { fact; base_score; gravity_factor; combined })
      facts
  in
  List.sort (fun a b -> Float.compare b.combined a.combined) scored
;;