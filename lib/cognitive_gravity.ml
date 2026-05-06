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

(* Jaccard similarity between two string lists, treated as multisets of
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
    let set_a = a' in
    let set_b = b' in
    let intersect =
      List.filter (fun k -> List.mem k set_b) set_a |> List.length
    in
    let union =
      List.sort_uniq String.compare (set_a @ set_b) |> List.length
    in
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
  List.stable_sort (fun (_, a) (_, b) -> compare b a) scored
