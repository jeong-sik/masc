let ref_prefix = "#/$defs/"

(* A [$ref] costs its own bytes, so a shape is only worth hoisting when the
   copies it removes outweigh the references that replace them plus the one
   definition left behind. Measured against the live surface rather than
   guessed: the threshold changes nothing there -- Execute's four shapes clear
   it by 645 bytes at the narrowest -- but it keeps the transform from growing
   a schema that repeats something tiny. *)
let profitable ~body_bytes ~ref_bytes ~occurrences =
  occurrences >= 2 && (body_bytes * (occurrences - 1)) - (ref_bytes * occurrences) > 0
;;

let rec canonical (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map (fun (key, value) -> key, canonical value) fields
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List items -> `List (List.map canonical items)
  | other -> other
;;

let canonical_string json = Yojson.Safe.to_string (canonical json)

(* What counts as a shape worth naming: an object schema that declares
   properties. A [$ref] can stand anywhere a schema can, but naming scalars or
   bare type declarations would trade bytes for indirection. *)
let is_named_shape (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields, List.assoc_opt "properties" fields with
     | Some (`String "object"), Some (`Assoc _) -> true
     | _ -> false)
  | _ -> false
;;

module String_map = Map.Make (String)

let count_shapes root =
  let counts = ref String_map.empty in
  let bump key =
    counts
      := String_map.update
           key
           (function
             | None -> Some 1
             | Some n -> Some (n + 1))
           !counts
  in
  let rec walk ~is_root (json : Yojson.Safe.t) =
    (match json with
     | _ when is_root -> ()
     | json when is_named_shape json -> bump (canonical_string json)
     | _ -> ());
    match json with
    | `Assoc fields -> List.iter (fun (_, value) -> walk ~is_root:false value) fields
    | `List items -> List.iter (walk ~is_root:false) items
    | _ -> ()
  in
  walk ~is_root:true root;
  !counts
;;

(* Names are derived from the canonical text in sorted order, so the same
   schema collapses to the same bytes on every run and a diff of the wire
   payload stays readable. *)
let assign_names selected =
  List.sort String.compare selected
  |> List.mapi (fun index body -> body, Printf.sprintf "shape%d" index)
  |> List.to_seq
  |> String_map.of_seq
;;

let reference name = `Assoc [ "$ref", `String (ref_prefix ^ name) ]

let rec substitute names ~is_root (json : Yojson.Safe.t) : Yojson.Safe.t =
  let replaced =
    if is_root
    then None
    else if is_named_shape json
    then String_map.find_opt (canonical_string json) names
    else None
  in
  match replaced with
  | Some name -> reference name
  | None ->
    (match json with
     | `Assoc fields ->
       `Assoc
         (List.map (fun (key, value) -> key, substitute names ~is_root:false value) fields)
     | `List items -> `List (List.map (substitute names ~is_root:false) items)
     | other -> other)
;;

let collapse (schema : Yojson.Safe.t) : Yojson.Safe.t =
  match schema with
  | `Assoc fields when List.mem_assoc "$defs" fields || List.mem_assoc "$ref" fields ->
    (* Already written against a definition table. Rewriting one is a different
       job from naming repeats in a schema that has none, and this transform
       does not claim to do it. *)
    schema
  | `Assoc fields ->
    let counts = count_shapes schema in
    let selected =
      String_map.bindings counts
      |> List.filter (fun (body, occurrences) ->
        profitable
          ~body_bytes:(String.length body)
          ~ref_bytes:(String.length (Yojson.Safe.to_string (reference "shape00")))
          ~occurrences)
      |> List.map fst
    in
    if selected = []
    then schema
    else (
      let names = assign_names selected in
      let definitions =
        String_map.bindings names
        |> List.map (fun (body, name) ->
          (* The body keeps its own repeats as references, so a shape nested
             inside another named shape is stored once, not once per host. *)
          name, substitute names ~is_root:true (Yojson.Safe.from_string body))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      in
      let rewritten =
        match substitute names ~is_root:true (`Assoc fields) with
        | `Assoc rewritten_fields -> rewritten_fields
        | _ -> fields
      in
      `Assoc (rewritten @ [ "$defs", `Assoc definitions ]))
  | other -> other
;;
