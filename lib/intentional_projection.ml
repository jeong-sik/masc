(* Intentional Projection — implementation.

   See intentional_projection.mli for the interface contract and
   docs/rfc/RFC-0035-cognitive-ide-roadmap.md for the integration plan. *)

type transition = {
  prev : string;
  next : string;
}

(* Sparse representation: an association list of (prev, next, count).
   Suitable for the small models we expect (a few hundred transitions
   per session). Conversion to a Hashtbl is a follow-up if profiling
   ever shows it matters. *)
type model = (string * string * int) list

let empty : model = []

let pairs_of_sequence actions =
  let rec aux = function
    | [] | [ _ ] -> []
    | a :: (b :: _ as rest) -> { prev = a; next = b } :: aux rest
  in
  aux actions

let bump (m : model) ~prev ~next : model =
  let rec aux acc = function
    | [] -> List.rev_append acc [ (prev, next, 1) ]
    | (p, n, c) :: rest when p = prev && n = next ->
      List.rev_append acc ((p, n, c + 1) :: rest)
    | head :: rest -> aux (head :: acc) rest
  in
  aux [] m

let observe_pairs (m : model) (pairs : transition list) : model =
  List.fold_left
    (fun acc { prev; next } -> bump acc ~prev ~next)
    m pairs

let count_after (m : model) ~prev ~next =
  List.fold_left
    (fun acc (p, n, c) -> if p = prev && n = next then acc + c else acc)
    0 m

let total_after (m : model) prev =
  List.fold_left (fun acc (p, _, c) -> if p = prev then acc + c else acc) 0 m

let score (m : model) ~smoothing ~prev ~candidates ~next =
  match candidates with
  | [] -> 0.0
  | _ ->
    let total = total_after m prev in
    let count = count_after m ~prev ~next in
    let n_cands = List.length candidates in
    let denom =
      float_of_int total +. (smoothing *. float_of_int n_cands)
    in
    if denom <= 0.0 then 0.0
    else (float_of_int count +. smoothing) /. denom

let rank (m : model) ~smoothing ~prev ~candidates =
  let scored =
    List.map
      (fun cand ->
        (cand, score m ~smoothing ~prev ~candidates ~next:cand))
      candidates
  in
  List.stable_sort (fun (_, a) (_, b) -> Float.compare b a) scored
