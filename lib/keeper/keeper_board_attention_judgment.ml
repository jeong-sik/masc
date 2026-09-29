type decision =
  | Relevant
  | Not_relevant
[@@deriving enumerate]

type t =
  { decision : decision
  ; rationale : string
  }

let decision_to_string = function
  | Relevant -> "relevant"
  | Not_relevant -> "not_relevant"
;;

let decision_tokens = List.map decision_to_string all_of_decision

(* Read back through the same labels the tokens are written with, so a label
   exists in one place. *)
let decision_of_string raw =
  List.find_opt
    (fun decision -> String.equal (decision_to_string decision) raw)
    all_of_decision
;;

let to_yojson verdict =
  `Assoc
    [ "decision", `String (decision_to_string verdict.decision)
    ; "rationale", `String verdict.rationale
    ]
;;

let of_yojson = function
  | `Assoc [ ("decision", `String decision); ("rationale", `String rationale) ]
  | `Assoc [ ("rationale", `String rationale); ("decision", `String decision) ] ->
    (match decision_of_string decision with
     | None -> Error (Printf.sprintf "unknown board-attention decision %S" decision)
     | Some decision ->
       let rationale = String.trim rationale in
       if String.equal rationale ""
       then Error "board-attention rationale must not be empty"
       else Ok { decision; rationale })
  | `Assoc _ ->
    Error "board-attention verdict fields must be exactly decision and rationale"
  | _ -> Error "board-attention verdict must be an object"
;;

type batch_item =
  { candidate_id : string
  ; verdict : t
  }

(* Shape diagnostics for a rejected batch answer. The parser stays exactly as
   strict as before; only the error now names what the answer carried, so a
   quarantine can tell a missing field from an extra one from a repeated one
   without keeping the answer. Only key NAMES are quoted, each clipped and
   escaped by [%S]; a value never reaches the message. *)
let shape_name_cap = 8
let shape_name_max_bytes = 32

let shape_name name =
  let clipped =
    if String.length name <= shape_name_max_bytes
    then name
    else String.sub name 0 shape_name_max_bytes ^ "..."
  in
  Printf.sprintf "%S" clipped
;;

let shape_names names =
  let shown = List.filteri (fun position _ -> position < shape_name_cap) names in
  let hidden = List.length names - List.length shown in
  let tail = if hidden > 0 then Printf.sprintf "; +%d more" hidden else "" in
  "[" ^ String.concat "; " (List.map shape_name shown) ^ tail ^ "]"
;;

let expected_batch_item_keys = [ "candidate_id"; "decision"; "rationale" ]

let batch_item_shape_error ~index fields =
  let keys = List.map fst fields in
  let occurrences key = List.length (List.filter (String.equal key) keys) in
  let missing =
    List.filter (fun key -> occurrences key = 0) expected_batch_item_keys
  in
  let extra =
    List.sort_uniq
      String.compare
      (List.filter (fun key -> not (List.mem key expected_batch_item_keys)) keys)
  in
  let repeated =
    List.filter (fun key -> occurrences key > 1) expected_batch_item_keys
  in
  Printf.sprintf
    "board-attention batch item fields must be exactly candidate_id, decision and rationale (item=%d missing=%s extra=%s repeated=%s)"
    index
    (shape_names missing)
    (shape_names extra)
    (shape_names repeated)
;;

let batch_item_of_yojson ~index = function
  | `Assoc fields ->
    let keys = List.sort compare (List.map fst fields) in
    if keys <> expected_batch_item_keys
    then Error (batch_item_shape_error ~index fields)
    else
      (match
         ( List.assoc_opt "candidate_id" fields
         , List.assoc_opt "decision" fields
         , List.assoc_opt "rationale" fields )
       with
       | Some (`String candidate_id), Some (`String decision), Some (`String rationale) ->
         (match decision_of_string decision with
          | None -> Error (Printf.sprintf "unknown board-attention decision %S" decision)
          | Some decision ->
            let candidate_id = String.trim candidate_id in
            let rationale = String.trim rationale in
            if String.equal candidate_id ""
            then Error "board-attention batch item candidate_id must not be empty"
            else if String.equal rationale ""
            then Error "board-attention rationale must not be empty"
            else Ok { candidate_id; verdict = { decision; rationale } })
       | _ -> Error "board-attention batch item fields must be strings")
  | _ -> Error "board-attention batch item must be an object"
;;

let batch_of_yojson = function
  | `Assoc [ ("verdicts", `List items) ] ->
    let rec decode acc index = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match batch_item_of_yojson ~index item with
         | Ok decoded -> decode (decoded :: acc) (index + 1) rest
         | Error _ as error -> error)
    in
    decode [] 0 items
  | `Assoc fields ->
    Error
      (Printf.sprintf
         "board-attention batch verdict must be an object with exactly one field: verdicts (keys=%s)"
         (shape_names (List.map fst fields)))
  | _ -> Error "board-attention batch verdict must be an object"
;;
