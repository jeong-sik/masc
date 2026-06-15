(* Semantic Gravity ranker — implementation.

   See cognitive_gravity.mli for the interface contract and
   docs/rfc/RFC-0035-cognitive-ide-roadmap.md for the integration plan. *)

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

(* ============================================================
   Phase 3a/4: Memory OS scoring — score_fact with recency,
   access, stale_penalty, recency_bonus, valid_until_gate,
   and verification_factor.
   ============================================================ *)

type scored_fact = {
  confidence : float;
  last_accessed : float; (* unix timestamp *)
  access_count : int;
  stale_penalty : float;
  expected_lifetime_cycles : int option;
  valid_until : float option; (* optional TTL; None means no expiry *)
  verification_factor : float; (* confidence in the fact's correctness, 0-1 *)
}

let recency_factor ~now ~last_accessed =
  let age_seconds = now -. last_accessed in
  if age_seconds < 0.0 then 1.0
  else Float.exp (-. age_seconds /. (3600.0 *. 24.0))

let access_factor ~count =
  let rec log_factor c =
    if c <= 0 then 0.0
    else 1.0 +. (0.1 *. Float.log (float_of_int c))
  in
  clamp ~lo:0.0 ~hi:1.0 (log_factor count)

let stale_penalty ~last_accessed ~expected_lifetime_cycles ~now =
  match expected_lifetime_cycles with
  | None -> 0.0
  | Some cycles ->
    let age_seconds = now -. last_accessed in
    let cycle_duration = 3600.0 *. 24.0 *. 7.0 in (* one week per cycle *)
    let age_cycles = age_seconds /. cycle_duration in
    if age_cycles > float_of_int cycles then
      0.5 *. (age_cycles -. float_of_int cycles)
    else 0.0

let recency_bonus ~now ~last_accessed =
  let age_seconds = now -. last_accessed in
  if age_seconds < 3600.0 then 0.1 (* accessed within last hour *)
  else if age_seconds < 86400.0 then 0.05 (* accessed within last day *)
  else 0.0

let valid_until_gate ~valid_until ~now =
  match valid_until with
  | None -> true
  | Some expiry -> now < expiry

let verification_factor_of ~confidence ~access_count =
  (* Higher access count increases confidence in the fact's correctness *)
  let base = confidence in
  let access_boost = 0.1 *. Float.log (1.0 +. float_of_int access_count) in
  clamp ~lo:0.0 ~hi:1.0 (base +. access_boost)

let score_fact ~now fact =
  let recency = recency_factor ~now ~last_accessed:fact.last_accessed in
  let access = access_factor ~count:fact.access_count in
  let stale = stale_penalty ~last_accessed:fact.last_accessed
    ~expected_lifetime_cycles:fact.expected_lifetime_cycles ~now in
  let bonus = recency_bonus ~now ~last_accessed:fact.last_accessed in
  let verification = verification_factor_of ~confidence:fact.confidence
    ~access_count:fact.access_count in
  let gate = valid_until_gate ~valid_until:fact.valid_until ~now in
  let raw_score =
    (0.3 *. fact.confidence)
    +. (0.2 *. recency)
    +. (0.15 *. access)
    +. (0.1 *. bonus)
    -. (0.25 *. stale)
    +. (0.1 *. verification)
  in
  let final_score = if gate then raw_score else -.1.0 in
  {
    confidence = fact.confidence;
    last_accessed = fact.last_accessed;
    access_count = fact.access_count;
    stale_penalty = stale;
    expected_lifetime_cycles = fact.expected_lifetime_cycles;
    valid_until = fact.valid_until;
    verification_factor = verification;
  }, final_score