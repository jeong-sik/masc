open Result_syntax

let is_finite_number value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false
;;

let validate ~context json =
  let invalid detail = Error (context ^ " is not serializable JSON: " ^ detail) in
  let validate_intlit value =
    try
      match Yojson.Safe.from_string value with
      | `Int _ | `Intlit _ -> Ok ()
      | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ ->
        invalid "Intlit is not an integer JSON literal"
    with
    | Yojson.Json_error detail -> invalid ("invalid Intlit: " ^ detail)
  in
  let rec loop = function
    | [] -> Ok ()
    | value :: rest ->
      (match value with
       | `Null | `Bool _ | `Int _ | `String _ -> loop rest
       | `Intlit value ->
         let* () = validate_intlit value in
         loop rest
       | `Float value ->
         if is_finite_number value
         then loop rest
         else Error (context ^ " contains a non-finite float")
       | `List values -> loop (List.rev_append values rest)
       | `Assoc fields -> loop (List.rev_append (List.map snd fields) rest))
  in
  loop [ json ]
;;

module String_set = Set.Make (String)

let object_fields ~context ~required ~optional = function
  | `Assoc fields ->
    let allowed = String_set.of_list (required @ optional) in
    let rec validate seen = function
      | [] ->
        let missing =
          List.find_opt (fun name -> not (String_set.mem name seen)) required
        in
        (match missing with
         | None -> Ok fields
         | Some name -> Error (Printf.sprintf "%s is missing field %s" context name))
      | (name, _) :: rest ->
        if String_set.mem name seen
        then Error (Printf.sprintf "%s has duplicate field %s" context name)
        else if not (String_set.mem name allowed)
        then Error (Printf.sprintf "%s has unknown field %s" context name)
        else validate (String_set.add name seen) rest
    in
    validate String_set.empty fields
  | _ -> Error (context ^ " must be a JSON object")
;;

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ name)
;;

let string_field name fields =
  let* value = field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("field " ^ name ^ " must be a string")
;;

let int_field name fields =
  let* value = field name fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error ("field " ^ name ^ " must be an int")
;;

let option_string_field name fields =
  let* value = field name fields in
  match value with
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error ("field " ^ name ^ " must be a string or null")
;;

let option_json = function
  | None -> `Null
  | Some value -> value
;;
