(** Keeper_memory_os_edges — see .mli. Associative layer of the Memory OS. *)

open Keeper_memory_os_types

type relation =
  | Relates
  | Unknown of string

let relation_of_string = function
  | "relates" -> Relates
  | other -> Unknown other
;;

let relation_to_string = function
  | Relates -> "relates"
  | Unknown s -> s
;;

type edge =
  { src : string
  ; dst : string
  ; relation : relation
  ; trace_id : string
  ; created_at : float
  ; schema_version : string
  }

type association =
  { a_src : string
  ; a_dst : string
  ; a_relation : relation
  ; weight : int
  ; first_seen : float
  ; last_seen : float
  }

(* ---------- JSON codec ---------- *)

(* Local assoc-field accessors, matching the per-module convention in
   keeper_librarian.ml (the types module keeps its own private and does not
   export them). *)
let json_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String s) -> Some s
  | Some (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
  | None -> None
;;

let json_float_field key fields =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int i) -> Some (float_of_int i)
  | Some (`Assoc _ | `Bool _ | `Intlit _ | `List _ | `Null | `String _) | None -> None
;;

let edge_to_json (e : edge) : Yojson.Safe.t =
  `Assoc
    [ "src", `String e.src
    ; "dst", `String e.dst
    ; "relation", `String (relation_to_string e.relation)
    ; "trace_id", `String e.trace_id
    ; "created_at", `Float e.created_at
    ; "schema_version", `String e.schema_version
    ]
;;

let edge_of_json (json : Yojson.Safe.t) : edge option =
  match json with
  | `Assoc fields ->
    (match
       ( json_string_field "src" fields
       , json_string_field "dst" fields
       , json_string_field "relation" fields
       , json_float_field "created_at" fields )
     with
     | Some src, Some dst, Some relation, Some created_at ->
       Some
         { src
         ; dst
         ; (* Parse-once at the read boundary: a legacy/forward relation string
              with no arm maps to [Unknown] rather than failing the line. *)
           relation = relation_of_string relation
         ; (* DET-OK: absent provenance trace_id defaults to empty for legacy
              edges; it is metadata, not an identity field. *)
           trace_id = Option.value (json_string_field "trace_id" fields) ~default:""
         ; created_at
         ; schema_version =
             (* DET-OK: default to current schema for forward compatibility. *)
             Option.value (json_string_field "schema_version" fields) ~default:schema_version
         }
     | (Some _, Some _, Some _, None)
     | (Some _, Some _, None, _)
     | (Some _, None, _, _)
     | (None, _, _, _) -> None)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

(* ---------- Producer ---------- *)

let co_occurrence_edges (episode : episode) : edge list =
  let keys =
    episode.claims
    |> List.map (fun (f : fact) -> normalize_claim f.claim)
    (* Distinct + sorted: deduplicates within-episode repeats and gives every
       emitted pair canonical order ([src] < [dst]) for free, since pairs are
       drawn left-to-right from a sorted list. *)
    |> List.sort_uniq String.compare
  in
  let rec pairs = function
    | [] | [ _ ] -> []
    | x :: rest -> List.map (fun y -> x, y) rest @ pairs rest
  in
  pairs keys
  |> List.map (fun (src, dst) ->
    { src
    ; dst
    ; relation = Relates
    ; trace_id = episode.trace_id
    ; created_at = episode.created_at
    ; schema_version
    })
;;

(* ---------- Aggregation ---------- *)

module Assoc_key = struct
  type t = string * string * string

  let compare = compare
end

module Assoc_map = Map.Make (Assoc_key)

let aggregate (edges : edge list) : association list =
  let folded =
    List.fold_left
      (fun acc (e : edge) ->
         let key = e.src, e.dst, relation_to_string e.relation in
         match Assoc_map.find_opt key acc with
         | None ->
           Assoc_map.add
             key
             { a_src = e.src
             ; a_dst = e.dst
             ; a_relation = e.relation
             ; weight = 1
             ; first_seen = e.created_at
             ; last_seen = e.created_at
             }
             acc
         | Some a ->
           Assoc_map.add
             key
             { a with
               weight = a.weight + 1
             ; first_seen = Float.min a.first_seen e.created_at
             ; last_seen = Float.max a.last_seen e.created_at
             }
             acc)
      Assoc_map.empty
      edges
  in
  Assoc_map.fold (fun _ a acc -> a :: acc) folded []
  |> List.sort (fun a b ->
    match String.compare a.a_src b.a_src with
    | 0 ->
      (match String.compare a.a_dst b.a_dst with
       | 0 -> String.compare (relation_to_string a.a_relation) (relation_to_string b.a_relation)
       | c -> c)
    | c -> c)
;;

(* ---------- Spreading activation ---------- *)

let activation_boosts ~alpha ~associations ~(base : (string * float) list) =
  if alpha <= 0.0
  then []
  else (
    let base_tbl = Hashtbl.create (List.length base * 2 + 1) in
    List.iter (fun (k, s) -> Hashtbl.replace base_tbl k s) base;
    (* Undirected neighbour index: each association lends both directions. *)
    let nbr : (string, (string * float) list) Hashtbl.t = Hashtbl.create 256 in
    let add a b w =
      let cur = match Hashtbl.find_opt nbr a with Some l -> l | None -> [] in
      Hashtbl.replace nbr a ((b, w) :: cur)
    in
    List.iter
      (fun a ->
         let w = float_of_int a.weight in
         add a.a_src a.a_dst w;
         add a.a_dst a.a_src w)
      associations;
    List.filter_map
      (fun (k, _base_score) ->
         match Hashtbl.find_opt nbr k with
         | None -> None
         | Some neighbours ->
           (* Weighted average over neighbours that are themselves recalled, so a
              fact linked to strongly-scored facts is lifted in proportion to the
              association strength; absent neighbours contribute nothing. *)
           let num, den =
             List.fold_left
               (fun (num, den) (n, w) ->
                  match Hashtbl.find_opt base_tbl n with
                  | Some base_n -> num +. (w *. base_n), den +. w
                  | None -> num, den)
               (0.0, 0.0)
               neighbours
           in
           if den <= 0.0 then None else Some (k, alpha *. (num /. den)))
      base)
;;
