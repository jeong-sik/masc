(** Tool input validation — strict deterministic schema checking.

    Validates tool call arguments against declared parameter schemas.
    @since 0.100.0 *)

type actual =
  | Missing
  | Received of string

type field_error =
  { path : string
  ; expected : string
  ; actual : actual
  }

type validation_result =
  | Valid of Yojson.Safe.t
  | Invalid of field_error list

(* ── Type description ────────────────────────────────────── *)

let describe_json_value = function
  | `Null -> "null"
  | `Bool b -> Printf.sprintf "boolean(%b)" b
  | `Int i -> Printf.sprintf "integer(%d)" i
  | `Float f -> Printf.sprintf "number(%g)" f
  | `String s ->
    let preview = if String.length s > 20 then String.sub s 0 20 ^ "..." else s in
    Printf.sprintf "string(\"%s\")" preview
  | `List _ -> "array"
  | `Assoc _ -> "object"
  | `Intlit s -> Printf.sprintf "integer(%s)" s
;;

let string_of_param_type = Types.param_type_to_string

(* ── Type checking ───────────────────────────────────────── *)

let matches_type (expected : Types.param_type) (value : Yojson.Safe.t) : bool =
  match expected, value with
  | Types.String, `String _ -> true
  | Types.Integer, `Int _ -> true
  | Types.Integer, `Intlit _ -> true
  | Types.Number, `Float _ -> true
  | Types.Number, `Int _ -> true (* int is a valid number *)
  | Types.Number, `Intlit _ -> true
  | Types.Boolean, `Bool _ -> true
  | Types.Array, `List _ -> true
  | Types.Object, `Assoc _ -> true
  | _ -> false
;;

let matches_json_schema_type type_name = function
  | `Null -> String.equal type_name "null"
  | `String _ -> String.equal type_name "string"
  | `Int _ | `Intlit _ ->
    String.equal type_name "integer" || String.equal type_name "number"
  | `Float value ->
    String.equal type_name "number"
    || (String.equal type_name "integer"
        && Float.is_finite value
        && Float.is_integer value)
  | `Bool _ -> String.equal type_name "boolean"
  | `List _ -> String.equal type_name "array"
  | `Assoc _ -> String.equal type_name "object"
;;

let property_type_names = function
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String type_name) -> Some [ type_name ]
     | Some (`List values) ->
       Some
         (List.filter_map
            (function
              | `String value -> Some value
              | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
                None)
            values)
     | None | Some _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

type canonical_number =
  { negative : bool
  ; significand : string
  ; exponent : int
  }

let canonical_decimal value =
  let decimal_digits value =
    (not (String.equal value ""))
    && String.for_all (fun char -> char >= '0' && char <= '9') value
  in
  let decimal_exponent value =
    let digits =
      if String.length value > 0 && (Char.equal value.[0] '+' || Char.equal value.[0] '-')
      then String.sub value 1 (String.length value - 1)
      else value
    in
    if decimal_digits digits then int_of_string_opt value else None
  in
  let length = String.length value in
  let negative, unsigned =
    if length > 0 && Char.equal value.[0] '-'
    then true, String.sub value 1 (length - 1)
    else false, value
  in
  let exponent_index =
    match String.index_opt unsigned 'e', String.index_opt unsigned 'E' with
    | None, None -> Some None
    | Some index, None | None, Some index -> Some (Some index)
    | Some _, Some _ -> None
  in
  match exponent_index with
  | None -> None
  | Some exponent_index ->
    let mantissa, exponent =
      match exponent_index with
      | None -> Some unsigned, Some 0
      | Some index ->
        let mantissa = String.sub unsigned 0 index in
        let raw_exponent =
          String.sub unsigned (index + 1) (String.length unsigned - index - 1)
        in
        Some mantissa, decimal_exponent raw_exponent
    in
    (match mantissa, exponent with
     | Some mantissa, Some exponent ->
       let whole, fraction, has_decimal_point =
         match String.index_opt mantissa '.' with
         | None -> Some mantissa, Some "", false
         | Some index ->
           let whole = String.sub mantissa 0 index in
           let fraction =
             String.sub mantissa (index + 1) (String.length mantissa - index - 1)
           in
           if String.contains fraction '.'
           then None, None, true
           else Some whole, Some fraction, true
       in
       (match whole, fraction with
        | Some whole, Some fraction
          when (not (String.equal whole ""))
               && ((not has_decimal_point) || not (String.equal fraction ""))
               && decimal_digits whole
               && (String.equal fraction "" || decimal_digits fraction)
               && (String.length whole = 1 || not (Char.equal whole.[0] '0')) ->
          let digits = whole ^ fraction in
          let rec first_nonzero index =
            if index = String.length digits
            then None
            else if Char.equal digits.[index] '0'
            then first_nonzero (index + 1)
            else Some index
          in
          (match first_nonzero 0 with
           | None -> Some { negative = false; significand = "0"; exponent = 0 }
           | Some first ->
             let rec last_nonzero index =
               if Char.equal digits.[index] '0' then last_nonzero (index - 1) else index
             in
             let last = last_nonzero (String.length digits - 1) in
             let trailing_zeroes = String.length digits - last - 1 in
             Some
               { negative
               ; significand = String.sub digits first (last - first + 1)
               ; exponent = exponent - String.length fraction + trailing_zeroes
               })
        | Some _, Some _ | None, None | None, Some _ | Some _, None -> None)
     | None, None | None, Some _ | Some _, None -> None)
;;

let canonical_number = function
  | `Int value -> canonical_decimal (string_of_int value)
  | `Intlit value -> canonical_decimal value
  | `Float value when Float.is_finite value ->
    canonical_decimal (Yojson.Safe.to_string (`Float value))
  | `Float _ | `Null | `Bool _ | `String _ | `Assoc _ | `List _ -> None
;;

let numeric_equal left right =
  match canonical_number left, canonical_number right with
  | Some left, Some right -> left = right
  | None, None | None, Some _ | Some _, None -> false
;;

let rec json_semantic_equal left right =
  match left, right with
  | (`Int _ | `Intlit _ | `Float _), (`Int _ | `Intlit _ | `Float _) ->
    numeric_equal left right
  | `Null, `Null -> true
  | `Bool left, `Bool right -> Bool.equal left right
  | `String left, `String right -> String.equal left right
  | `List left, `List right -> List.equal json_semantic_equal left right
  | `Assoc left, `Assoc right ->
    List.length left = List.length right
    && List.for_all
         (fun (name, left_value) ->
            match List.assoc_opt name right with
            | Some right_value -> json_semantic_equal left_value right_value
            | None -> false)
         left
  | ( (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _)
    , (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) )
    -> false
;;

let property_matches property value =
  match property with
  | `Bool allowed -> allowed
  | `Assoc fields ->
    let type_matches =
      match property_type_names property with
      | None -> true
      | Some type_names ->
        List.exists (fun type_name -> matches_json_schema_type type_name value) type_names
    in
    let const_matches =
      match List.assoc_opt "const" fields with
      | None -> true
      | Some expected -> json_semantic_equal expected value
    in
    let enum_matches =
      match List.assoc_opt "enum" fields with
      | None -> true
      | Some (`List values) -> List.exists (json_semantic_equal value) values
      | Some _ -> false
    in
    type_matches && const_matches && enum_matches
  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> true
;;

let expected_property_type property =
  match property_type_names property with
  | Some (_ :: _ as type_names) -> String.concat " or " type_names
  | Some [] | None -> "declared schema"
;;

let authoritative_schema_parts = function
  | `Assoc fields ->
    let required =
      match List.assoc_opt "required" fields with
      | Some (`List values) ->
        List.filter_map
          (function
            | `String value -> Some value
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> None)
          values
      | None | Some _ -> []
    in
    let properties =
      match List.assoc_opt "properties" fields with
      | Some (`Assoc values) -> values
      | None | Some _ -> []
    in
    required, properties
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> [], []
;;

let validate_authoritative input_schema input =
  match input with
  | `Assoc fields ->
    let required, properties = authoritative_schema_parts input_schema in
    let names =
      List.map fst properties
      @ List.filter (fun name -> not (List.mem_assoc name properties)) required
    in
    let errors =
      List.filter_map
        (fun name ->
           let path = "/" ^ name in
           let property = List.assoc_opt name properties in
           match List.assoc_opt name fields, property with
           | None, _ when List.mem name required ->
             Some
               { path
               ; expected =
                   Option.fold ~none:"required" ~some:expected_property_type property
               ; actual = Missing
               }
           | None, _ -> None
           | Some value, Some property when not (property_matches property value) ->
             Some
               { path
               ; expected = expected_property_type property
               ; actual = Received (describe_json_value value)
               }
           | Some _, _ -> None)
        names
    in
    if errors = [] then Valid input else Invalid errors
  | other ->
    Invalid
      [ { path = "/"; expected = "object"; actual = Received (describe_json_value other) }
      ]
;;

(* ── Validation ──────────────────────────────────────────── *)

let validate (schema : Types.tool_schema) (input : Yojson.Safe.t) : validation_result =
  match schema.input_schema with
  | Some input_schema -> validate_authoritative input_schema input
  | None ->
    let params = schema.parameters in
    (match input with
     | `Assoc fields ->
       let errors =
         List.filter_map
           (fun (p : Types.tool_param) ->
              let path = "/" ^ p.name in
              match List.assoc_opt p.name fields with
              | None when p.required ->
                Some
                  { path; expected = string_of_param_type p.param_type; actual = Missing }
              | None -> None
              | Some value when matches_type p.param_type value -> None
              | Some value ->
                Some
                  { path
                  ; expected = string_of_param_type p.param_type
                  ; actual = Received (describe_json_value value)
                  })
           params
       in
       if errors = [] then Valid input else Invalid errors
     | other ->
       Invalid
         [ { path = "/"
           ; expected = "object"
           ; actual = Received (describe_json_value other)
           }
         ])
;;

(* ── Error formatting ────────────────────────────────────── *)

let format_errors ~tool_name errors =
  let lines =
    List.map
      (fun e ->
         let actual =
           match e.actual with
           | Missing -> "missing"
           | Received description -> description
         in
         Printf.sprintf "- %s: expected %s, got %s" e.path e.expected actual)
      errors
  in
  Printf.sprintf
    "Tool '%s' parameter errors:\n%s\nFix the parameters and try again."
    tool_name
    (String.concat "\n" lines)
;;

(** Samchon-style inline error feedback: show the LLM's own JSON
    with error annotations, so the retry prompt gives surgical guidance.

    Output example:
    {[
      Your call to "read_file":
      {"op": "find", "pattern": "*.ml"}

      Errors (fix these and call again):
        "name": MISSING (required: string)
        "op": wrong type — expected: integer, got: string("find")
    ]}
*)
let format_errors_inline ~tool_name ~(args : Yojson.Safe.t) errors =
  let json_str = Yojson.Safe.to_string args in
  let error_lines =
    List.map
      (fun e ->
         let field_name =
           match String.index_opt e.path '/' with
           | Some i -> String.sub e.path (i + 1) (String.length e.path - i - 1)
           | None -> e.path
         in
         match e.actual with
         | Missing ->
           Printf.sprintf "  \"%s\": MISSING (required: %s)" field_name e.expected
         | Received description ->
           Printf.sprintf
             "  \"%s\": wrong type — expected: %s, got: %s"
             field_name
             e.expected
             description)
      errors
  in
  Printf.sprintf
    "Your call to \"%s\":\n%s\n\nErrors (fix these and call again):\n%s"
    tool_name
    json_str
    (String.concat "\n" error_lines)
;;
