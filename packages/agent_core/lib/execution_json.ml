open Result_syntax

type path_segment =
  | Object_field of string
  | Array_index of int

type validation_reason =
  | Duplicate_object_key
  | Non_finite_float
  | Invalid_integer_literal of string

type validation_error =
  { context : string
  ; path : path_segment list
  ; reason : validation_reason
  }

module String_set = Set.Make (String)

let path_to_string path =
  path
  |> List.map (function
    | Object_field name -> Printf.sprintf "[%S]" name
    | Array_index index -> Printf.sprintf "[%d]" index)
  |> String.concat ""
  |> fun suffix -> "$" ^ suffix
;;

let validation_error_to_string error =
  let reason =
    match error.reason with
    | Duplicate_object_key -> "has a duplicate object key"
    | Non_finite_float -> "contains a non-finite float"
    | Invalid_integer_literal value ->
      Printf.sprintf "contains invalid integer literal %S" value
  in
  Printf.sprintf "%s at %s %s" error.context (path_to_string error.path) reason
;;

let is_finite_number value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false
;;

let validate ~context json =
  let invalid rev_path reason =
    Error { context; path = List.rev rev_path; reason }
  in
  let validate_intlit rev_path value =
    try
      match Yojson.Safe.from_string value with
      | `Int _ | `Intlit _ -> Ok ()
      | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ ->
        invalid rev_path (Invalid_integer_literal value)
    with
    | Yojson.Json_error _ -> invalid rev_path (Invalid_integer_literal value)
  in
  let rec loop = function
    | [] -> Ok ()
    | (rev_path, value) :: rest ->
      (match value with
       | `Null | `Bool _ | `Int _ | `String _ -> loop rest
       | `Intlit value ->
         let* () = validate_intlit rev_path value in
         loop rest
       | `Float value ->
         if is_finite_number value
         then loop rest
         else invalid rev_path Non_finite_float
       | `List values -> enqueue_list rev_path 0 [] values rest
       | `Assoc fields -> enqueue_fields rev_path String_set.empty [] fields rest)
  and enqueue_list rev_path index pending values rest =
    match values with
    | [] -> loop (List.rev_append pending rest)
    | value :: values ->
      enqueue_list
        rev_path
        (index + 1)
        ((Array_index index :: rev_path, value) :: pending)
        values
        rest
  and enqueue_fields rev_path seen pending fields rest =
    match fields with
    | [] -> loop (List.rev_append pending rest)
    | (name, value) :: fields ->
      let field_path = Object_field name :: rev_path in
      if String_set.mem name seen
      then invalid field_path Duplicate_object_key
      else
        enqueue_fields
          rev_path
          (String_set.add name seen)
          ((field_path, value) :: pending)
          fields
          rest
  in
  loop [ [], json ]
;;

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
