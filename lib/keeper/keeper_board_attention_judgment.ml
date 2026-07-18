type decision =
  | Relevant
  | Not_relevant

type t =
  { decision : decision
  ; rationale : string
  }

let batch_schema_name = "keeper_board_attention_judgment_batch"

let decision_to_string = function
  | Relevant -> "relevant"
  | Not_relevant -> "not_relevant"
;;

let decision_tokens = [ decision_to_string Relevant; decision_to_string Not_relevant ]

let decision_of_string = function
  | "relevant" -> Some Relevant
  | "not_relevant" -> Some Not_relevant
  | _ -> None
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

let batch_item_to_yojson item =
  `Assoc
    [ "candidate_id", `String item.candidate_id
    ; "decision", `String (decision_to_string item.verdict.decision)
    ; "rationale", `String item.verdict.rationale
    ]
;;

let batch_item_of_yojson = function
  | `Assoc fields ->
    let keys = List.sort compare (List.map fst fields) in
    if keys <> [ "candidate_id"; "decision"; "rationale" ]
    then Error "board-attention batch item fields must be exactly candidate_id, decision and rationale"
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

let batch_to_yojson items =
  `Assoc [ "verdicts", `List (List.map batch_item_to_yojson items) ]
;;

let batch_of_yojson = function
  | `Assoc [ ("verdicts", `List items) ] ->
    let rec decode acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match batch_item_of_yojson item with
         | Ok decoded -> decode (decoded :: acc) rest
         | Error _ as error -> error)
    in
    decode [] items
  | `Assoc _ ->
    Error "board-attention batch verdict must be an object with exactly one field: verdicts"
  | _ -> Error "board-attention batch verdict must be an object"
;;
