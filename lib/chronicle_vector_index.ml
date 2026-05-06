(* Chronicle vector index — implementation.

   See chronicle_vector_index.mli for the interface contract. *)

type vector = float array

type entry = {
  event : Chronicle_event.t;
  embedding : vector;
}

type index = {
  dim : int option;
  entries : entry list;
  (* Insertion order; stable sort under search ties relies on this. *)
}

let empty ?dim () = { dim; entries = [] }

let len idx = List.length idx.entries

let dim idx = idx.dim

let copy_vector v =
  let n = Array.length v in
  let out = Array.make n 0.0 in
  Array.blit v 0 out 0 n;
  out

let add idx entry =
  let n = Array.length entry.embedding in
  match idx.dim with
  | Some d when d <> n ->
    Error
      (Printf.sprintf
         "dimension mismatch: index dim is %d, embedding length is %d" d n)
  | Some _ ->
    let entry' = { entry with embedding = copy_vector entry.embedding } in
    Ok { idx with entries = idx.entries @ [ entry' ] }
  | None ->
    let entry' = { entry with embedding = copy_vector entry.embedding } in
    Ok { dim = Some n; entries = idx.entries @ [ entry' ] }

let add_event idx event embedding =
  add idx { event; embedding }

let to_list idx = idx.entries

let dot_product a b =
  let n = Array.length a in
  let acc = ref 0.0 in
  for i = 0 to n - 1 do
    acc := !acc +. (a.(i) *. b.(i))
  done;
  !acc

let l2_norm v =
  let n = Array.length v in
  let acc = ref 0.0 in
  for i = 0 to n - 1 do
    acc := !acc +. (v.(i) *. v.(i))
  done;
  Float.sqrt !acc

let cosine_similarity a b =
  if Array.length a <> Array.length b then 0.0
  else
    let na = l2_norm a in
    let nb = l2_norm b in
    if na = 0.0 || nb = 0.0 then 0.0 else dot_product a b /. (na *. nb)

let normalize v =
  let n = l2_norm v in
  if n = 0.0 then copy_vector v
  else Array.map (fun x -> x /. n) v

let take n xs =
  let rec aux k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | x :: rest -> aux (k - 1) (x :: acc) rest
  in
  aux n [] xs

let search idx ~query ?limit () =
  (match idx.dim with
   | Some d when Array.length query <> d ->
     invalid_arg
       (Printf.sprintf
          "Chronicle_vector_index.search: query dim %d, index dim %d"
          (Array.length query) d)
   | _ -> ());
  let scored =
    List.map
      (fun entry ->
        (entry.event, cosine_similarity query entry.embedding))
      idx.entries
  in
  let sorted =
    List.stable_sort (fun (_, a) (_, b) -> Float.compare b a) scored
  in
  match limit with
  | None -> sorted
  | Some n -> take n sorted
