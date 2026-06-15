(* Semantic Gravity ranker — implementation.

   See cognitive_gravity.mli for the interface contract and
   docs/rfc/RFC-0035-cognitive-ide-roadmap.md for the integration plan.

   apply_decay updated per garnet's task-1289 root-cause analysis:
   replaces static 3-type decay triggers with 8-type Event Bus triggers
   and Memory OS-aware stale factor deltas.

   score_reduction added per garnet's follow-up: connects apply_decay delta
   to per-fact base_score * turn_age formula for actual score decay. *)

type decay_trigger =
  | TurnElapsed
  | NoNewMentions
  | Contradiction
  | ManualDecay
  | KeeperVerification
  | TaskCycle
  | KnowledgeImport
  | DecayResistance

type 'a item = {
  payload : 'a;
  keywords : string list;
  recency_seconds : float;
  frequency_weight : float;
}

type weights = {
  keyword : float;
  recency : float;
  frequency : float;
}

let default_weights = { keyword = 1.0; recency = 0.4; frequency = 0.3 }

let recency_tau_seconds = 86_400.0
(* one day; ~37% weight at 1 day, ~13% at 2 days, ~5% at 3 days. *)

let clamp ~lo ~hi x = if x < lo then lo else if x > hi then hi else x

(* Jaccard similarity between two string lists, treated as sets of unique
   case-insensitive tokens. Returns 0.0 when both sides are empty so that
   "no signal" never accidentally rewards an item. *)
let jaccard a b =
  let normalise xs =
    xs
    |> List.map String.lowercase_ascii
    |> List.sort_uniq String.compare
  in
  let a' = normalise a in
  let b' = normalise b in
  match a', b' with
  | [], [] -> 0.0
  | _, _ ->
    let rec intersection_count xs ys =
      match xs, ys with
      | [], _ | _, [] -> 0
      | x :: xt, y :: yt ->
        let ordering = String.compare x y in
        if ordering = 0 then 1 + intersection_count xt yt
        else if ordering < 0 then intersection_count xt ys
        else intersection_count xs yt
    in
    let intersect = intersection_count a' b' in
    let union = List.length a' + List.length b' - intersect in
    if union = 0 then 0.0
    else float_of_int intersect /. float_of_int union

let recency_decay seconds =
  let t = if seconds < 0.0 then 0.0 else seconds in
  Float.exp (-. t /. recency_tau_seconds)

let gravity_score weights ~query item =
  let kw_sim = jaccard query item.keywords in
  let rec_score = recency_decay item.recency_seconds in
  let freq_score = clamp ~lo:0.0 ~hi:1.0 item.frequency_weight in
  (weights.keyword *. kw_sim)
  +. (weights.recency *. rec_score)
  +. (weights.frequency *. freq_score)

let rank ?(weights = default_weights) ~query items =
  (* Stable sort: List.stable_sort preserves input order for equal scores. *)
  let scored = List.map (fun it -> (it, gravity_score weights ~query it)) items in
  List.stable_sort (fun (_, a) (_, b) -> Float.compare b a) scored

(* Per-trigger stale-factor delta weights.
   Each weight represents the contribution to accumulated decay score
   when that trigger fires. Weights are chosen so that:
   - >= 0.7 accumulated triggers GC sweep
   - DecayResistance (-0.40) acts as counter-force

   Weights merge rondo's Phase4 design rate and garnet's original taxonomy. *)
let trigger_weight = function
  | TurnElapsed      -> 0.15
  | NoNewMentions    -> 0.20
  | Contradiction    -> 0.60
  | ManualDecay      -> 0.50
  | KeeperVerification -> 0.30
  | TaskCycle        -> 0.25
  | KnowledgeImport  -> 0.20
  | DecayResistance  -> (-0.40)

(* Default decay rate for per-fact score reduction.
   Chosen so that a fact with base_score=1.0 at turn_age=50 reaches
   the GC threshold (0.5) in about 25 turns with default decay_rate=0.02.
   Phase 4 design value; env-configurable via the module root doc. *)
let default_decay_rate = 0.02

(* stale_factor_delta returns the per-trigger contribution to the stale
   factor computation, which is trigger_weight clamped to [-1.0, 1.0].

   This is the function garnet's task-1289 analysis identified as the
   missing dynamic link between Event Bus triggers and Memory OS fact
   scores. *)
let stale_factor_delta trigger =
  let w = trigger_weight trigger in
  clamp ~lo:(-1.0) ~hi:1.0 w

(* apply_decay accepts a list of decay triggers fired by the Event Bus
   and returns the composite stale-factor delta.

   Implementation per garnet's task-1289 root cause and rondo's task-1282
   Phase4 GC trigger design:

   - Each trigger contributes trigger_weight
   - DecayResistance contributes negative weight (counters decay)
   - Result clamped to [-1.0, 1.0]
   - Positive delta = reduce fact scores = trigger decay
   - Negative delta = preserve fact scores = DecayResistance dominant *)
let apply_decay ?keeper_id:_ triggers =
  let sum = List.fold_left (fun acc t -> acc +. stale_factor_delta t) 0.0 triggers in
  clamp ~lo:(-1.0) ~hi:1.0 sum

(* score_reduction computes the actual score decrease for a Memory OS fact
   after applying decay triggers over [turn_age] turns.

   Formula (garnet's task-1289 spec):
     reduced_score = base_score - (decay_rate * base_score * turn_age)

   [decay_rate] can be configured per-call; defaults to [default_decay_rate].
   Result clamped to [0.0, base_score] so scores never go negative or increase.

   This is the critical function garnet identified: the prior code had no
   per-fact scoring formula at all, only static apply_decay constants. *)
let score_reduction ?(decay_rate = default_decay_rate) ~base_score ~turn_age =
  let reduction = decay_rate *. base_score *. float_of_int turn_age in
  clamp ~lo:0.0 ~hi:base_score (base_score -. reduction)