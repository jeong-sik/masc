type error =
  | Unsupported_keyword of string
  | Unsupported_type of string
  | Invalid_schema

let ( let* ) = Result.bind

let schema_keywords =
  [ "type"
  ; "title"
  ; "description"
  ; "properties"
  ; "required"
  ; "additionalProperties"
  ; "enum"
  ; "format"
  ; "minimum"
  ; "maximum"
  ; "items"
  ; "prefixItems"
  ; "minItems"
  ; "maxItems"
  ; "anyOf"
  ]
;;

(* Gemini interprets [oneOf] as [anyOf], so admitting it would erase the
   caller's exclusivity contract. Keep [oneOf] unsupported. *)
let any_of_keywords = [ "anyOf"; "title"; "description" ]

let keywords_for_type = function
  | "object" ->
    [ "type"; "title"; "description"; "properties"; "required"; "additionalProperties" ]
  | "string" -> [ "type"; "title"; "description"; "enum"; "format" ]
  | "number" | "integer" ->
    [ "type"; "title"; "description"; "enum"; "minimum"; "maximum" ]
  | "array" ->
    [ "type"; "title"; "description"; "items"; "prefixItems"; "minItems"; "maxItems" ]
  | "boolean" | "null" -> [ "type"; "title"; "description" ]
  | type_name -> raise_notrace (Invalid_argument type_name)
;;

let assoc_keys_are_unique fields =
  let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
;;

let json_number = function
  | `Int _ | `Intlit _ | `Float _ -> true
  | `Null | `Bool _ | `String _ | `Assoc _ | `List _ -> false
;;

let json_integer = function
  | `Int _ | `Intlit _ -> true
  | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ -> false
;;

let non_null_schema_types =
  [ "string"; "number"; "integer"; "boolean"; "object"; "array" ]
;;

let schema_base_type = function
  | Some (`String type_name)
    when String.equal type_name "null" || List.mem type_name non_null_schema_types ->
    Ok type_name
  | Some (`String type_name) -> Error (Unsupported_type type_name)
  | Some (`List [ `String left; `String right ])
    when String.equal left "null" && List.mem right non_null_schema_types -> Ok right
  | Some (`List [ `String left; `String right ])
    when String.equal right "null" && List.mem left non_null_schema_types -> Ok left
  | Some (`List _) | Some _ | None -> Error Invalid_schema
;;

let rec validate ~path = function
  | `Assoc fields when assoc_keys_are_unique fields ->
    (match List.assoc_opt "anyOf" fields with
     | Some branches -> validate_any_of ~path ~fields branches
     | None ->
       (match
          List.find_opt
            (fun (keyword, _) -> not (List.mem keyword schema_keywords))
            fields
        with
        | Some (keyword, _) -> Error (Unsupported_keyword (path ^ "." ^ keyword))
        | None ->
          (match schema_base_type (List.assoc_opt "type" fields) with
           | Ok type_name ->
             let supported = keywords_for_type type_name in
             (match
                List.find_opt
                  (fun (keyword, _) -> not (List.mem keyword supported))
                  fields
              with
              | Some (keyword, _) -> Error (Unsupported_keyword (path ^ "." ^ keyword))
              | None -> validate_fields ~path ~type_name fields)
           | Error _ as error -> error)))
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error Invalid_schema

and validate_any_of ~path ~fields branches =
  match
    List.find_opt (fun (keyword, _) -> not (List.mem keyword any_of_keywords)) fields
  with
  | Some (keyword, _) -> Error (Unsupported_keyword (path ^ "." ^ keyword))
  | None ->
    let* () =
      match
        List.find_opt
          (function
            | "anyOf", _ -> false
            | ("title" | "description"), `String _ -> false
            | _ -> true)
          fields
      with
      | None -> Ok ()
      | Some _ -> Error Invalid_schema
    in
    (match branches with
     | `List (_ :: _ as schemas) ->
       let rec validate_branches index = function
         | [] -> Ok ()
         | schema :: rest ->
           let* () = validate ~path:(Printf.sprintf "%s.anyOf[%d]" path index) schema in
           validate_branches (index + 1) rest
       in
       validate_branches 0 schemas
     | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List []
       -> Error Invalid_schema)

and validate_fields ~path ~type_name fields =
  let rec validate_all = function
    | [] -> Ok ()
    | field :: rest ->
      let* () = validate_field ~path ~type_name field in
      validate_all rest
  in
  validate_all fields

and validate_field ~path ~type_name = function
  | "type", (`String _ | `List _) -> Ok ()
  | ("title" | "description"), `String _ -> Ok ()
  | "properties", `Assoc properties
    when String.equal type_name "object" && assoc_keys_are_unique properties ->
    let rec validate_properties = function
      | [] -> Ok ()
      | (name, schema) :: rest ->
        let* () = validate ~path:(path ^ ".properties." ^ name) schema in
        validate_properties rest
    in
    validate_properties properties
  | "required", `List names
    when String.equal type_name "object"
         && List.for_all
              (function
                | `String _ -> true
                | _ -> false)
              names -> Ok ()
  | "additionalProperties", `Bool _ when String.equal type_name "object" -> Ok ()
  | "additionalProperties", schema when String.equal type_name "object" ->
    validate ~path:(path ^ ".additionalProperties") schema
  | "enum", `List values
    when values <> []
         && String.equal type_name "string"
         && List.for_all
              (function
                | `String _ -> true
                | _ -> false)
              values -> Ok ()
  | "enum", `List values
    when values <> []
         && String.equal type_name "number"
         && List.for_all json_number values -> Ok ()
  | "enum", `List values
    when values <> []
         && String.equal type_name "integer"
         && List.for_all json_integer values -> Ok ()
  | "format", `String _ when String.equal type_name "string" -> Ok ()
  | ("minimum" | "maximum"), value
    when (String.equal type_name "number" || String.equal type_name "integer")
         && json_number value -> Ok ()
  | "items", schema when String.equal type_name "array" ->
    validate ~path:(path ^ ".items") schema
  | "prefixItems", `List schemas when String.equal type_name "array" ->
    let rec validate_prefix_items index = function
      | [] -> Ok ()
      | schema :: rest ->
        let* () =
          validate ~path:(Printf.sprintf "%s.prefixItems[%d]" path index) schema
        in
        validate_prefix_items (index + 1) rest
    in
    validate_prefix_items 0 schemas
  | ("minItems" | "maxItems"), `Int value
    when String.equal type_name "array" && value >= 0 -> Ok ()
  | _ -> Error Invalid_schema
;;
