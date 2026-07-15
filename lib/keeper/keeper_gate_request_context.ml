let history_evidence history_messages =
  let count =
    match history_messages with
    | `List messages -> List.length messages
    | _ -> 0
  in
  let sha256 =
    history_messages
    |> Yojson.Safe.to_string
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  `Assoc
    [ "schema", `String "masc.keeper_gate.history_evidence.v1"
    ; "included", `Bool false
    ; "count", `Int count
    ; "sha256", `String sha256
    ]
;;

let text_evidence ~schema text =
  `Assoc
    [ "schema", `String schema
    ; "included", `Bool false
    ; "bytes", `Int (String.length text)
    ; ( "sha256"
      , `String Digestif.SHA256.(digest_string text |> to_hex) )
    ]
;;

let project_text_field ~field ~evidence_field ~schema fields =
  match List.assoc_opt field fields with
  | Some (`String text) ->
    fields
    |> List.remove_assoc field
    |> List.remove_assoc evidence_field
    |> List.cons (evidence_field, text_evidence ~schema text)
  | Some _ | None -> fields
;;

let project = function
  | `Assoc fields as context ->
    (match List.assoc_opt "initial" fields with
     | Some (`Assoc initial_fields) ->
       (match List.assoc_opt "history_messages" initial_fields with
        | Some history_messages ->
          let projected_initial =
            initial_fields
            |> List.remove_assoc "history_messages"
            |> List.remove_assoc "history_messages_evidence"
            |> List.cons
                 ( "history_messages_evidence"
                 , history_evidence history_messages )
            |> project_text_field
                 ~field:"base_system_prompt"
                 ~evidence_field:"base_system_prompt_evidence"
                 ~schema:"masc.keeper_gate.system_prompt_evidence.v1"
            |> project_text_field
                 ~field:"turn_system_prompt"
                 ~evidence_field:"turn_system_prompt_evidence"
                 ~schema:"masc.keeper_gate.system_prompt_evidence.v1"
          in
          `Assoc
            (("initial", `Assoc projected_initial)
             :: List.remove_assoc "initial" fields)
        | None ->
          let projected_initial =
            initial_fields
            |> project_text_field
                 ~field:"base_system_prompt"
                 ~evidence_field:"base_system_prompt_evidence"
                 ~schema:"masc.keeper_gate.system_prompt_evidence.v1"
            |> project_text_field
                 ~field:"turn_system_prompt"
                 ~evidence_field:"turn_system_prompt_evidence"
                 ~schema:"masc.keeper_gate.system_prompt_evidence.v1"
          in
          if Yojson.Safe.equal (`Assoc initial_fields) (`Assoc projected_initial)
          then context
          else
            `Assoc
              (("initial", `Assoc projected_initial)
               :: List.remove_assoc "initial" fields))
     | Some _ | None -> context)
  | context -> context
;;
