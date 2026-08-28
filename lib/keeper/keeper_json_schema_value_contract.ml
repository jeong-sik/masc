type detail =
  { path : string list
  ; keyword : string
  ; expected : Yojson.Safe.t
  ; actual : Yojson.Safe.t
  }

type error =
  | Unsupported_schema of detail
  | Invalid_schema of detail
  | Value_mismatch of detail

let supported_keywords =
  [ "additionalProperties"; "anyOf"; "const"; "default"; "description"; "enum"
  ; "exclusiveMinimum"; "items"; "maxItems"
  ; "maxLength"; "maxProperties"; "maximum"; "minItems"; "minLength"
  ; "minProperties"; "minimum"; "not"; "oneOf"; "pattern"; "properties"
  ; "required"; "type"
  ]

let json_strings values = `List (List.map (fun value -> `String value) values)
let detail ~path ~keyword ~expected ~actual = { path; keyword; expected; actual }
let invalid ~path ~keyword ~expected ~actual = Error (Invalid_schema (detail ~path ~keyword ~expected ~actual))
let mismatch ~path ~keyword ~expected ~actual = Error (Value_mismatch (detail ~path ~keyword ~expected ~actual))

let error_to_json error =
  let kind, detail =
    match error with
    | Unsupported_schema detail -> "unsupported_schema", detail
    | Invalid_schema detail -> "invalid_schema", detail
    | Value_mismatch detail -> "value_mismatch", detail
  in
  `Assoc
    [ "kind", `String kind; "path", json_strings detail.path
    ; "keyword", `String detail.keyword; "expected", detail.expected
    ; "actual", detail.actual
    ]

let first_duplicate values =
  let rec loop seen = function
    | [] -> None
    | value :: rest -> if List.mem value seen then Some value else loop (value :: seen) rest
  in
  loop [] values

let schema_types = [ "null"; "boolean"; "integer"; "number"; "string"; "array"; "object" ]

let validate_type_declaration ~path = function
  | `String name when List.mem name schema_types -> Ok ()
  | `List values ->
    let names = List.filter_map (function `String name -> Some name | _ -> None) values in
    if values = [] || List.length names <> List.length values
    then invalid ~path ~keyword:"type" ~expected:(json_strings schema_types) ~actual:(`List values)
    else if List.exists (fun name -> not (List.mem name schema_types)) names
            || Option.is_some (first_duplicate names)
    then invalid ~path ~keyword:"type" ~expected:(json_strings schema_types) ~actual:(`List values)
    else Ok ()
  | actual -> invalid ~path ~keyword:"type" ~expected:(json_strings schema_types) ~actual

let nonnegative_int = function `Int value when value >= 0 -> Some value | _ -> None

let bigint_of_intlit literal =
  try
    let value = Z.of_string literal in
    if String.equal literal (Z.to_string value)
       || String.equal literal "-0" && Z.equal value Z.zero
    then Some value else None
  with Invalid_argument _ -> None

let finite_number = function
  | `Int value -> Some (Q.of_int value)
  | `Float value when Float.is_finite value -> Some (Q.of_float value)
  | `Intlit value -> Option.map Q.of_bigint (bigint_of_intlit value)
  | _ -> None

let rec json_equal left right =
  match finite_number left, finite_number right with
  | Some left, Some right -> Q.equal left right
  | Some _, None | None, Some _ -> false
  | None, None ->
    (match left, right with
     | `Null, `Null -> true
     | `Bool left, `Bool right -> Bool.equal left right
     | `String left, `String right -> String.equal left right
     | `List left, `List right ->
       List.length left = List.length right && List.for_all2 json_equal left right
     | `Assoc left, `Assoc right -> json_object_equal left right
     | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _), _ -> false)

and json_object_equal left right =
  let rec remove_field name = function
    | [] -> None
    | (candidate, value) :: rest when String.equal name candidate -> Some (value, rest)
    | field :: rest -> Option.map (fun (value, rest) -> value, field :: rest) (remove_field name rest)
  in
  let rec consume remaining = function
    | [] -> remaining = []
    | (name, value) :: rest ->
      (match remove_field name remaining with
       | Some (candidate, remaining) -> json_equal value candidate && consume remaining rest
       | None -> false)
  in
  consume right left

let first_duplicate_json values =
  let rec loop seen = function
    | [] -> None
    | value :: rest ->
      if List.exists (json_equal value) seen then Some value else loop (value :: seen) rest
  in
  loop [] values

let rec validate_schema_at path = function
  | `Assoc fields as schema ->
    (match first_duplicate (List.map fst fields) with
     | Some keyword -> invalid ~path ~keyword ~expected:(`String "unique keyword") ~actual:schema
     | None -> validate_schema_fields path fields)
  | actual -> invalid ~path ~keyword:"schema" ~expected:(`String "object") ~actual

and validate_schema_fields path fields =
  let rec loop = function
    | [] -> Ok ()
    | (keyword, value) :: rest ->
      let result =
        match keyword, value with
        | keyword, _ when not (List.mem keyword supported_keywords) ->
          Error
            (Unsupported_schema
               (detail ~path ~keyword ~expected:(json_strings supported_keywords) ~actual:value))
        | "type", value -> validate_type_declaration ~path value
        | "properties", `Assoc properties ->
          (match first_duplicate (List.map fst properties) with
           | Some field -> invalid ~path ~keyword:"properties" ~expected:(`String "unique fields") ~actual:(`String field)
           | None -> validate_named_schemas (path @ [ "properties" ]) properties)
        | "required", `List values -> validate_string_set ~path ~keyword values
        | "additionalProperties", `Bool _ -> Ok ()
        | "additionalProperties", schema -> validate_schema_at (path @ [ keyword ]) schema
        | "items", schema | "not", schema -> validate_schema_at (path @ [ keyword ]) schema
        | ("oneOf" | "anyOf"), `List (_ :: _ as schemas) ->
          validate_schemas (path @ [ keyword ]) schemas
        | "enum", `List (_ :: _ as values) when Option.is_none (first_duplicate_json values) -> Ok ()
        | "const", _ | "default", _ -> Ok ()
        | ("minimum" | "maximum" | "exclusiveMinimum"), value when Option.is_some (finite_number value) -> Ok ()
        | ("minLength" | "maxLength" | "minItems" | "maxItems" | "minProperties" | "maxProperties"), value
          when Option.is_some (nonnegative_int value) -> Ok ()
        | "pattern", `String pattern ->
          (match Re.Pcre.re_result pattern with
           | Ok _ -> Ok ()
           | Error _ -> invalid ~path ~keyword ~expected:(`String "valid PCRE pattern") ~actual:value)
        | "description", `String _ -> Ok ()
        | keyword, actual -> invalid ~path ~keyword ~expected:(`String "valid keyword value") ~actual
      in
      (match result with Ok () -> loop rest | Error _ as error -> error)
  in
  loop fields

and validate_named_schemas path = function
  | [] -> Ok ()
  | (name, schema) :: rest ->
    (match validate_schema_at (path @ [ name ]) schema with
     | Ok () -> validate_named_schemas path rest
     | Error _ as error -> error)

and validate_schemas path schemas =
  let rec loop index = function
    | [] -> Ok ()
    | schema :: rest ->
      (match validate_schema_at (path @ [ string_of_int index ]) schema with
       | Ok () -> loop (index + 1) rest
       | Error _ as error -> error)
  in
  loop 0 schemas

and validate_string_set ~path ~keyword values =
  let strings = List.filter_map (function `String value -> Some value | _ -> None) values in
  if List.length strings = List.length values && Option.is_none (first_duplicate strings)
  then Ok ()
  else invalid ~path ~keyword ~expected:(`String "unique string array") ~actual:(`List values)

let validate_schema schema = validate_schema_at [] schema

let value_type = function
  | `Null -> "null" | `Bool _ -> "boolean" | `String _ -> "string"
  | `List _ -> "array" | `Assoc _ -> "object"
  | `Int _ | `Intlit _ -> "integer"
  | `Float value when Float.is_finite value && Float.is_integer value -> "integer"
  | `Float value when Float.is_finite value -> "number"
  | `Float _ -> "non_json_number"

let type_matches declared value =
  let actual = value_type value in
  String.equal declared actual || String.equal declared "number" && String.equal actual "integer"

let declared_types = function
  | `String name -> [ name ]
  | `List values -> List.filter_map (function `String name -> Some name | _ -> None) values
  | _ -> []

let utf8_length text =
  let rec loop index count =
    if index >= String.length text then count
    else
      let decoded = String.get_utf_8_uchar text index in
      loop (index + Uchar.utf_decode_length decoded) (count + 1)
  in
  loop 0 0

let rec validate_value path schema value =
  match schema with
  | `Assoc fields ->
    let member keyword = List.assoc_opt keyword fields in
    let ( let* ) result next = match result with Ok () -> next () | Error _ as error -> error in
    let* () =
      match member "type" with
      | None -> Ok ()
      | Some declaration ->
        let expected = declared_types declaration in
        if List.exists (fun declared -> type_matches declared value) expected
        then Ok () else mismatch ~path ~keyword:"type" ~expected:declaration ~actual:value
    in
    let* () = match member "enum" with Some (`List values) when not (List.exists (json_equal value) values) -> mismatch ~path ~keyword:"enum" ~expected:(`List values) ~actual:value | _ -> Ok () in
    let* () = match member "const" with Some expected when not (json_equal expected value) -> mismatch ~path ~keyword:"const" ~expected ~actual:value | _ -> Ok () in
    let* () = validate_object_keywords path fields value in
    let* () = validate_array_keywords path fields value in
    let* () = validate_string_keywords path fields value in
    let* () = validate_number_keywords path fields value in
    let* () = validate_logic_keywords path fields value in
    Ok ()
  | _ -> mismatch ~path ~keyword:"schema" ~expected:schema ~actual:value

and validate_object_keywords path schema_fields = function
  | `Assoc value_fields as value ->
    (match first_duplicate (List.map fst value_fields) with
     | Some name -> mismatch ~path:(path @ [ name ]) ~keyword:"properties" ~expected:(`String "unique object fields") ~actual:value
     | None ->
       let required = match List.assoc_opt "required" schema_fields with Some (`List xs) -> List.filter_map (function `String x -> Some x | _ -> None) xs | _ -> [] in
       (match List.find_opt (fun name -> not (List.mem_assoc name value_fields)) required with
        | Some name -> mismatch ~path:(path @ [ name ]) ~keyword:"required" ~expected:(`String name) ~actual:value
        | None ->
          let properties = match List.assoc_opt "properties" schema_fields with Some (`Assoc xs) -> xs | _ -> [] in
          let rec fields = function
            | [] -> validate_count path schema_fields "minProperties" "maxProperties" (List.length value_fields) value
            | (name, child) :: rest ->
              (match List.assoc_opt name properties with
               | Some schema -> (match validate_value (path @ [ name ]) schema child with Ok () -> fields rest | Error _ as error -> error)
               | None ->
                 (match List.assoc_opt "additionalProperties" schema_fields with
                  | Some (`Bool false) -> mismatch ~path:(path @ [ name ]) ~keyword:"additionalProperties" ~expected:(`Bool false) ~actual:child
                  | Some (`Assoc _ as schema) -> (match validate_value (path @ [ name ]) schema child with Ok () -> fields rest | Error _ as error -> error)
                  | _ -> fields rest))
          in fields value_fields))
  | _ -> Ok ()

and validate_array_keywords path schema_fields = function
  | `List values as value ->
    let rec items index = function
      | [] -> validate_count path schema_fields "minItems" "maxItems" (List.length values) value
      | item :: rest ->
        (match List.assoc_opt "items" schema_fields with
         | Some schema -> (match validate_value (path @ [ string_of_int index ]) schema item with Ok () -> items (index + 1) rest | Error _ as error -> error)
         | None -> items (index + 1) rest)
    in items 0 values
  | _ -> Ok ()

and validate_string_keywords path fields = function
  | `String text as value ->
    (match validate_count path fields "minLength" "maxLength" (utf8_length text) value with
     | Error _ as error -> error
     | Ok () ->
       (match List.assoc_opt "pattern" fields with
        | Some (`String pattern) ->
          let regex = Re.Pcre.re pattern |> Re.compile in
          if Re.execp regex text then Ok () else mismatch ~path ~keyword:"pattern" ~expected:(`String pattern) ~actual:value
        | _ -> Ok ()))
  | _ -> Ok ()

and validate_number_keywords path fields value =
  match finite_number value with
  | None ->
    if List.mem (value_type value) [ "integer"; "number"; "non_json_number" ]
    then
      (match List.find_opt (fun keyword -> List.mem_assoc keyword fields)
               [ "minimum"; "maximum"; "exclusiveMinimum" ] with
       | Some keyword -> mismatch ~path ~keyword ~expected:(List.assoc keyword fields) ~actual:value
       | None -> Ok ())
    else Ok ()
  | Some actual ->
    let rec bounds = function
      | [] -> Ok ()
      | (keyword, accepts) :: rest ->
        (match Option.bind (List.assoc_opt keyword fields) finite_number with
         | Some expected when not (accepts (Q.compare actual expected)) -> mismatch ~path ~keyword ~expected:(List.assoc keyword fields) ~actual:value
         | _ -> bounds rest)
    in
    bounds
      [ "minimum", (fun compared -> compared >= 0)
      ; "maximum", (fun compared -> compared <= 0)
      ; "exclusiveMinimum", (fun compared -> compared > 0)
      ]

and validate_count path fields minimum maximum actual value =
  match Option.bind (List.assoc_opt minimum fields) nonnegative_int with
  | Some expected when actual < expected -> mismatch ~path ~keyword:minimum ~expected:(`Int expected) ~actual:value
  | _ ->
    (match Option.bind (List.assoc_opt maximum fields) nonnegative_int with
     | Some expected when actual > expected -> mismatch ~path ~keyword:maximum ~expected:(`Int expected) ~actual:value
     | _ -> Ok ())

and validate_logic_keywords path fields value =
  let accepts schema = match validate_value path schema value with Ok () -> true | Error _ -> false in
  match List.assoc_opt "oneOf" fields with
  | Some (`List schemas) when List.length (List.filter accepts schemas) <> 1 -> mismatch ~path ~keyword:"oneOf" ~expected:(`List schemas) ~actual:value
  | _ ->
    (match List.assoc_opt "anyOf" fields with
     | Some (`List schemas) when not (List.exists accepts schemas) -> mismatch ~path ~keyword:"anyOf" ~expected:(`List schemas) ~actual:value
     | _ ->
       (match List.assoc_opt "not" fields with
        | Some schema when accepts schema -> mismatch ~path ~keyword:"not" ~expected:schema ~actual:value
        | _ -> Ok ()))

let validate ~schema value =
  match validate_schema schema with
  | Error _ as error -> error
  | Ok () -> validate_value [] schema value
