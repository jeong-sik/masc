type issue = Missing_required_key of string | Incompatible_required_shape of string
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let to_string = function
  | Missing_required_key at -> "missing required key " ^ at
  | Incompatible_required_shape at -> "incompatible required shape at " ^ at

let rec issue ~at schema output =
  match field "anyOf" schema with
  | Some (`List (_ :: _ as alternatives)) ->
    let issues = List.map (fun alternative -> issue ~at alternative output) alternatives in
    if List.exists Option.is_none issues then None else List.find_map Fun.id issues
  | Some _ | None ->
    let type_matches =
      match field "type" schema, output with
      | Some (`String "object"), `Assoc _
      | Some (`String "array"), `List _
      | Some (`String "string"), `String _
      | Some (`String "boolean"), `Bool _
      | Some (`String "integer"), (`Int _ | `Intlit _)
      | Some (`String "number"), (`Int _ | `Intlit _ | `Float _)
      | Some (`String "null"), `Null -> true
      | Some (`String ("object" | "array" | "string" | "boolean" | "integer" | "number" | "null")), _ -> false
      | (Some _ | None), _ -> true
    in
    if not type_matches
    then Some (Incompatible_required_shape at)
    else
      match output with
      | `Assoc fields ->
        let required =
          match field "required" schema with
          | Some (`List keys) ->
            List.filter_map (function `String key -> Some key | _ -> None) keys
          | Some _ | None -> []
        in
        (match List.find_opt (fun key -> not (List.mem_assoc key fields)) required with
         | Some key -> Some (Missing_required_key (at ^ "." ^ key))
         | None ->
           (match field "properties" schema with
            | Some (`Assoc properties) ->
              List.find_map
                (fun (key, property_schema) ->
                   match List.assoc_opt key fields with
                   | None -> None
                   | Some value ->
                     issue ~at:(at ^ "." ^ key) property_schema value)
                properties
            | Some _ | None -> None))
      | _ ->
        if Option.is_some (field "required" schema)
           || Option.is_some (field "properties" schema)
        then Some (Incompatible_required_shape at)
        else None
;;
