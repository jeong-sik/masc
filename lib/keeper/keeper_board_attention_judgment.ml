type decision =
  | Relevant
  | Not_relevant

type t =
  { decision : decision
  ; rationale : string
  }

let schema_name = "keeper_board_attention_judgment"

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
