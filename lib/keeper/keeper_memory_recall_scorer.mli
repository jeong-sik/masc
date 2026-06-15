(** Keeper_memory_recall_scorer — post-processing ranker that applies
    Cognitive_gravity to already-scored Memory OS facts.

    Layer 2 in the task-1258 integration architecture:

      Layer 1: score_fact (policy.ml)       — per-fact contradict penalty
      Layer 2: recall_scorer (this module)  — gravity re-rank
      Layer 3: combined score → final order

    This module is deliberately separate from evaluate_memory_recall
    (keeper_memory_recall.ml) to keep the 37KB pipeline file unchanged
    and minimise regression risk. *)

(** Combined and re-ranked score for a fact.

    [base_score] is the score_fact result (already includes contradict
    penalty); [gravity_factor] is [0.0–1.0] normalised from Cognitive_gravity's
    raw gravity_score; [combined] = base_score × (0.7 + 0.3 × gravity_factor). *)
type scored_fact = {
  fact : Keeper_memory_os_types.fact;
  base_score : float;
  gravity_factor : float;
  combined : float;
}

(** [score ~query facts] applies Cognitive_gravity ranking over the
    given facts and returns them sorted by combined score descending.

    [query] is the current turn's tokenised keywords (RFC-0244 seed_tokens
    or user query tokens). When empty, the gravity factor is 1.0 for all
    facts and the result is sorted by base_score only. *)
val score
  :  query:string list
  -> Keeper_memory_os_types.fact list
  -> scored_fact list