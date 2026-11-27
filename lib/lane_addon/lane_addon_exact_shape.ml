type issue = Missing_required_key of string | Incompatible_required_shape of string
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let to_string = function
  | Missing_required_key at -> "missing required key " ^ at
  | Incompatible_required_shape at -> "incompatible required shape at " ^ at

let number_of_json = function
  | `Int n -> Some (float_of_int n)
  | `Float f when Float.is_finite f -> Some f
  | `Intlit s ->
    (match float_of_string_opt s with
     | Some f when Float.is_finite f -> Some f
     | Some _ | None -> None)
  | `Float _ | `Null | `Bool _ | `String _ | `Assoc _ | `List _ | `Tuple _
  | `Variant _ -> None
;;

let nonneg_int_field name schema =
  match field name schema with
  | Some (`Int n) when n >= 0 -> Some n
  | Some (`Intlit s) ->
    (match int_of_string_opt s with Some n when n >= 0 -> Some n | _ -> None)
  | Some _ | None -> None
;;

let check_scalar_constraints ~at schema output =
  let enum_ok =
    match field "enum" schema with
    | Some (`List allowed) -> List.exists (( = ) output) allowed
    | Some _ | None -> true
  in
  let const_ok =
    match field "const" schema with
    | Some expected -> output = expected
    | None -> true
  in
  if not (enum_ok && const_ok)
  then Some (Incompatible_required_shape at)
  else
    match output with
    | `String s ->
      let len = String_util.utf8_length s in
      let min_ok =
        match nonneg_int_field "minLength" schema with
        | Some min_len -> len >= min_len
        | None -> true
      in
      let max_ok =
        match nonneg_int_field "maxLength" schema with
        | Some max_len -> len <= max_len
        | None -> true
      in
      if min_ok && max_ok then None else Some (Incompatible_required_shape at)
    | `Int _ | `Intlit _ | `Float _ ->
      (match number_of_json output with
       | None -> Some (Incompatible_required_shape at)
       | Some v ->
         let min_ok =
           match Option.bind (field "minimum" schema) number_of_json with
           | Some lo -> Float.compare v lo >= 0
           | None -> true
         in
         let max_ok =
           match Option.bind (field "maximum" schema) number_of_json with
           | Some hi -> Float.compare v hi <= 0
           | None -> true
         in
         let ex_min_ok =
           match Option.bind (field "exclusiveMinimum" schema) number_of_json with
           | Some lo -> Float.compare v lo > 0
           | None -> true
         in
         let ex_max_ok =
           match Option.bind (field "exclusiveMaximum" schema) number_of_json with
           | Some hi -> Float.compare v hi < 0
           | None -> true
         in
         if min_ok && max_ok && ex_min_ok && ex_max_ok
         then None
         else Some (Incompatible_required_shape at))
    | `Null | `Bool _ | `Assoc _ | `List _ | `Tuple _ | `Variant _ -> None
;;

let matches_single_type type_name output =
  match type_name, output with
  | "object", `Assoc _
  | "array", `List _
  | "string", `String _
  | "boolean", `Bool _
  | "integer", (`Int _ | `Intlit _)
  | "number", (`Int _ | `Intlit _ | `Float _)
  | "null", `Null -> true
  | ("object" | "array" | "string" | "boolean" | "integer" | "number" | "null"), _ -> false
  | _, _ -> true
;;

let rec issue ~at schema output =
  match field "anyOf" schema with
  | Some (`List (_ :: _ as alternatives)) ->
    let issues = List.map (fun alternative -> issue ~at alternative output) alternatives in
    if List.exists Option.is_none issues then None else List.find_map Fun.id issues
  | Some _ | None ->
    let explicit_type = field "type" schema in
    let type_matches =
      match explicit_type with
      | Some (`String t) -> matches_single_type t output
      | Some (`List types) ->
        (* An array type with no string entries is malformed JSON Schema (reject);
           unknown string type names remain forward-compatible via matches_single_type. *)
        (match List.filter_map (function `String t -> Some t | _ -> None) types with
         | [] -> false
         | names -> List.exists (fun t -> matches_single_type t output) names)
      | Some _ | None -> true
    in
    if not type_matches
    then Some (Incompatible_required_shape at)
    else
      match check_scalar_constraints ~at schema output with
      | Some _ as err -> err
      | None ->
        (match output with
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
              let properties =
                match field "properties" schema with
                | Some (`Assoc properties) -> Some properties
                | Some _ | None -> None
              in
              let additional_forbidden =
                field "additionalProperties" schema = Some (`Bool false)
              in
              let allowed_properties =
                match properties with
                | Some props -> Some (List.map fst props)
                | None ->
                  if Option.is_none (field "patternProperties" schema)
                  then Some []
                  else None
              in
              let extra_key_issue =
                match additional_forbidden, allowed_properties with
                | true, Some allowed ->
                  List.find_map
                    (fun (key, _) ->
                       if List.mem key allowed
                       then None
                       else Some (Incompatible_required_shape (at ^ "." ^ key)))
                    fields
                | false, _ | true, None -> None
              in
              (match extra_key_issue with
               | Some _ as err -> err
               | None ->
                 (match properties with
                  | Some properties ->
                    List.find_map
                      (fun (key, property_schema) ->
                         match List.assoc_opt key fields with
                         | None -> None
                         | Some value ->
                           issue ~at:(at ^ "." ^ key) property_schema value)
                      properties
                  | None -> None)))
         | `List elements ->
           if Option.is_none explicit_type
              && (Option.is_some (field "required" schema)
                  || Option.is_some (field "properties" schema))
           then Some (Incompatible_required_shape at)
           else
             let len = List.length elements in
             let min_ok =
               match nonneg_int_field "minItems" schema with
               | Some min_items -> len >= min_items
               | None -> true
             in
             let max_ok =
               match nonneg_int_field "maxItems" schema with
               | Some max_items -> len <= max_items
               | None -> true
             in
             if not (min_ok && max_ok)
             then Some (Incompatible_required_shape at)
             else
               (match field "items" schema with
                | Some (`Assoc _ as item_schema) ->
                  let rec check_items idx = function
                    | [] -> None
                    | elem :: rest ->
                      (match
                         issue
                           ~at:(Printf.sprintf "%s[%d]" at idx)
                           item_schema
                           elem
                       with
                       | Some _ as err -> err
                       | None -> check_items (idx + 1) rest)
                  in
                  check_items 0 elements
                | Some _ | None -> None)
         | _ ->
           if Option.is_none explicit_type
              && (Option.is_some (field "required" schema)
                  || Option.is_some (field "properties" schema)
                  || Option.is_some (field "items" schema))
           then Some (Incompatible_required_shape at)
           else None)
;;
