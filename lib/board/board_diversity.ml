(** Board_diversity — echo-chamber reduction via diversity-aware reranking. *)

(** Number of top posts to examine for diversity. *)
let window_size = 10

(** Maximum number of underrepresented-author posts to lift. *)
let max_boost = 2

(** Author-frequency map. *)
module Author_map = Map.Make (struct
  type t = Board_types.Agent_id.t
  let compare = Board_types.Agent_id.compare
end)

(** Count the frequency of each author in the given post list. *)
let author_frequencies (posts : Board_types.post list) =
  List.fold_left
    (fun acc p ->
      Author_map.update p.author (function None -> Some 1 | Some n -> Some (n + 1)) acc)
    Author_map.empty
    posts

(** Returns the index of the first element satisfying [pred], or -1. *)
let find_idx pred lst =
  let rec go i = function
    | [] -> -1
    | x :: _ when pred x -> i
    | _ :: xs -> go (i + 1) xs
  in
  go 0 lst

(** Remove element at index [idx] from a list. *)
let remove_at idx lst =
  let before, after = List.split_n lst idx in
  let after = match after with [] -> [] | _ :: rest -> rest in
  before @ after

(** Insert element at position [idx] (clamped to bounds). *)
let insert_at idx el lst =
  let pos = min idx (List.length lst) in
  let before, after = List.split_n lst pos in
  before @ [el] @ after

(** Detect runs of 3+ consecutive posts by the same author.
    Returns zone positions (0-based index of the 3rd post in each run). *)
let find_dead_zones (posts : Board_types.post list) =
  let rec scan i acc =
    if i >= List.length posts - 2 then List.rev acc
    else
      match List.nth posts i, List.nth posts (i + 1), List.nth posts (i + 2) with
      | a, b, c when
          Board_types.Agent_id.equal a.author b.author
          && Board_types.Agent_id.equal b.author c.author ->
        scan (i + 1) ((i + 2) :: acc)
      | _ -> scan (i + 1) acc
  in
  scan 0 []

(** Diversity deficit for a post: higher = more underrepresented. *)
let diversity_boost ~total freqs (p : Board_types.post) =
  let count = match Author_map.find_opt p.author freqs with None -> 0 | Some c -> c in
  if total = 0 then 0.0
  else 1.0 -. (float_of_int count /. float_of_int total)

(** Select up to [max_boost] boost candidates from posts outside
    the top [window_size].  Returns post objects. *)
let pick_boost_candidates ~total freqs (posts : Board_types.post list) =
  let top_n = min window_size (List.length posts) in
  let remainder = List.drop posts top_n in
  let scored = List.map (fun p -> (p, diversity_boost ~total freqs p)) remainder in
  let sorted = List.sort (fun (_, s1) (_, s2) -> Float.compare s2 s1) scored in
  let rec take acc = function
    | [] -> List.rev acc
    | (p, _) :: _ when List.length acc >= max_boost -> List.rev acc
    | (p, _) :: rest -> take (p :: acc) rest
  in
  take [] sorted

(** Move posts from underrepresented authors into dead zones.

    Strategy: for each dead zone (in order), find the candidate
    with the highest deficit that hasn't been placed yet, remove
    it from its current position, and insert it at the zone. *)
let inject_diversity posts zones candidates =
  let available = ref candidates in
  let result = ref posts in
  List.iter (fun zone ->
    match !available with
    | [] -> ()
    | cand :: rest ->
      available := rest;
      (* Find the candidate in the current result list *)
      let cur_idx = find_idx (fun p -> p == cand) !result in
      if cur_idx >= 0 then begin
        (* Remove candidate from its current position *)
        let without = remove_at cur_idx !result in
        (* Insert at zone.  If removal was before zone, shift zone left by 1 *)
        let adj_zone = if cur_idx < zone then zone - 1 else zone in
        let pos = min adj_zone (List.length without) in
        result := insert_at pos cand without
      end
  ) zones;
  !result

let rerank_for_diversity ~(posts : Board_types.post list)
    ~(sort_by : Board_dispatch.sort_order) : Board_types.post list =
  match sort_by with
  | Hot | Trending ->
    let n = List.length posts in
    if n < 4 then posts
    else
      let freqs = author_frequencies posts in
      let candidates = pick_boost_candidates ~total:n freqs posts in
      if candidates = [] then posts
      else
        let zones = find_dead_zones posts in
        if zones = [] then posts
        else inject_diversity posts zones candidates
  | Recent | Updated | Discussed -> posts