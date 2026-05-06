(* Intentional Projection — implementation.

   See intentional_projection.mli for the interface contract. *)

type transition =
  { prev : string
  ; next : string
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
;;

let bump (m : model) ~prev ~next : model =
  let rec aux acc = function
    | [] -> List.rev_append acc [ prev, next, 1 ]
    | (p, n, c) :: rest when p = prev && n = next ->
      List.rev_append acc ((p, n, c + 1) :: rest)
    | head :: rest -> aux (head :: acc) rest
  in
  aux [] m
;;

let observe_pairs (m : model) (pairs : transition list) : model =
  List.fold_left (fun acc { prev; next } -> bump acc ~prev ~next) m pairs
;;

let total_after (m : model) prev =
  List.fold_left (fun acc (p, _, c) -> if p = prev then acc + c else acc) 0 m
;;

let validate_smoothing ~caller smoothing =
  let finite =
    match classify_float smoothing with
    | FP_normal | FP_zero | FP_subnormal -> true
    | FP_infinite | FP_nan -> false
  in
  if smoothing < 0.0 || not finite
  then invalid_arg (caller ^ ": smoothing must be finite and non-negative")
;;

let unique_candidates candidates =
  let seen = Hashtbl.create (List.length candidates) in
  List.filter
    (fun candidate ->
       if Hashtbl.mem seen candidate
       then false
       else (
         Hashtbl.add seen candidate ();
         true))
    candidates
;;

let candidate_counts (m : model) ~prev ~candidates =
  let candidates = unique_candidates candidates in
  let counts = Hashtbl.create (List.length candidates) in
  let unique_count = ref 0 in
  List.iter
    (fun candidate ->
       if not (Hashtbl.mem counts candidate)
       then (
         Hashtbl.add counts candidate 0;
         incr unique_count))
    candidates;
  let total = ref 0 in
  List.iter
    (fun (p, n, c) ->
       if p = prev && Hashtbl.mem counts n
       then (
         let next_count = Option.value ~default:0 (Hashtbl.find_opt counts n) + c in
         Hashtbl.replace counts n next_count;
         total := !total + c))
    m;
  counts, !total, !unique_count
;;

let score_from_counts counts ~total ~unique_count ~smoothing ~next =
  match Hashtbl.find_opt counts next with
  | None -> 0.0
  | Some count ->
    let denom = float_of_int total +. (smoothing *. float_of_int unique_count) in
    if denom <= 0.0 then 0.0 else (float_of_int count +. smoothing) /. denom
;;

let score (m : model) ~smoothing ~prev ~candidates ~next =
  validate_smoothing ~caller:"Intentional_projection.score" smoothing;
  match candidates with
  | [] -> 0.0
  | _ ->
    let counts, total, unique_count = candidate_counts m ~prev ~candidates in
    score_from_counts counts ~total ~unique_count ~smoothing ~next
;;

let rank (m : model) ~smoothing ~prev ~candidates =
  validate_smoothing ~caller:"Intentional_projection.rank" smoothing;
  let candidates = unique_candidates candidates in
  let counts, total, unique_count = candidate_counts m ~prev ~candidates in
  let scored =
    List.map
      (fun cand ->
         cand, score_from_counts counts ~total ~unique_count ~smoothing ~next:cand)
      candidates
  in
  List.stable_sort (fun (_, a) (_, b) -> Float.compare b a) scored
;;
