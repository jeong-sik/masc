(** Semantic Gravity ranker — Master Report Dim01 / P0 #5.

    Given a query context and a list of candidate items, produce a ranking
    that maximises the weighted sum of:

    - keyword overlap (Jaccard similarity) between the item's keywords and
      the query's keywords;
    - recency, decaying exponentially with time since the item was last
      touched;
    - frequency weight, capturing how often the item has been referenced.

    The module is intentionally pure: it has no I/O, no Eio, no global state,
    and no dependency on dashboard or oas surfaces. Its only purpose is to
    compute a deterministic ranking given inputs. The dashboard renders the
    ranking; oas does not see it.

    See `docs/rfc/RFC-0035-cognitive-ide-roadmap.md` (PR-1) for the
    integration plan. *)

(** A candidate item to rank.

    [recency_seconds] is the seconds since the item was last touched (0.0 = now,
    larger = older). Negative values are clamped to 0.0 inside [gravity_score].

    [frequency_weight] is a normalised frequency score in [0.0, 1.0]; values
    outside that range are clamped. *)
type 'a item = {
  payload : 'a;
  keywords : string list;
  recency_seconds : float;
  frequency_weight : float;
}

(** Component weights used to combine the three sub-scores. The ranker does
    not require the components to sum to any particular total; the final
    [gravity_score] is itself the weighted sum and is not renormalised. *)
type weights = {
  keyword : float;
  recency : float;
  frequency : float;
}

(** Default weights chosen so that keyword overlap dominates, with recency
    and frequency providing a secondary nudge. *)
val default_weights : weights

(** Time constant used for the recency decay, in seconds. Items older than
    a few multiples of this constant contribute virtually no recency score.
    Hard-coded for now; future tuning is the subject of PR-2 onwards. *)
val recency_tau_seconds : float

(** [gravity_score weights ~query item] computes the weighted sum of
    keyword similarity, recency decay and frequency weight. The result is
    not normalised to [0.0, 1.0] — comparing two scores under the same
    weights is meaningful, comparing under different weights is not. *)
val gravity_score : weights -> query:string list -> 'a item -> float

(** [rank ?weights ~query items] returns a list sorted by descending
    gravity score, paired with the score that produced the ordering. The
    sort is stable: items with equal scores retain their input order. *)
val rank :
  ?weights:weights ->
  query:string list ->
  'a item list ->
  ('a item * float) list

(** Decay triggers sourced from the Event Bus for Memory OS stale-fact
    reconciliation. Each variant corresponds to a workspace channel that
    can signal staleness. Merged from rondo's Phase4 design (4 types)
    and garnet's original trigger taxonomy (8 types total).

    @see <p-fafed821f4c8d5b6d87106c4bc82fbc0> rondo task-1282 design
    @see <p-2caf95edeb5f5ab376154a2363e395a2> garnet task-1289 root cause *)
type decay_trigger =
  | TurnElapsed
  | NoNewMentions
  | Contradiction
  | ManualDecay
  | KeeperVerification
  | TaskCycle
  | KnowledgeImport
  | DecayResistance

(** Per-trigger weight used by the Event Bus to accumulate a decay score.
    Sum of concurrent trigger weights >= 0.7 signals a GC sweep.

    Weights reflect the relative impact each event type should have on
    stale-fact scoring. DecayResistance has a negative weight, acting as
    a counter-force against unnecessary decay. *)
val trigger_weight : decay_trigger -> float

(** [apply_decay ?keeper_id triggers score_delta] applies each
    [decay_trigger] to produce a composite stale-factor delta for
    Memory OS fact scoring.

    [score_delta] accumulates the weight of all concurrent triggers,
    clamped to [-1.0, 1.0]. A positive delta reduces fact scores (decay);
    a negative delta (from DecayResistance) preserves them.

    Called by the Event Bus dispatch layer after poll_all. *)
val apply_decay :
  ?keeper_id:string ->
  decay_trigger list ->
  float

(** [stale_factor_delta trigger] returns the per-trigger contribution
    to the stale factor computation. Each trigger contributes its
    weight, scaled by recency of the triggering event. *)
val stale_factor_delta : decay_trigger -> float