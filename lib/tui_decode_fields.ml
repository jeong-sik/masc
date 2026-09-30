let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null

let required_member json key =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field '%s'" key)

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a string (received %s)" key
           (Json_util.kind_name other))

let required_nullable_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be an int or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_float_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a float or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_string_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a string or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_bool_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a bool or null (received %s)" key
           (Json_util.kind_name other))

let require_null_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be null (received %s)" key
           (Json_util.kind_name other))
let required_bool_field json key =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | bad ->
      Error
        (Printf.sprintf "field '%s' must be a bool (received %s)" key
           (Json_util.kind_name bad))

let require_string_list json key =
  match member key json with
  | `List items ->
      List.mapi
        (fun idx item ->
          match item with
          | `String value -> Ok value
          | bad ->
              Error
                (Printf.sprintf
                   "field '%s[%d]' must be a string (received %s)" key idx
                   (Json_util.kind_name bad)))
        items
      |> List.fold_left
           (fun acc item ->
             let* parsed = acc in
             let* value = item in
             Ok (value :: parsed))
           (Ok [])
      |> Result.map List.rev
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an array (received %s)" key
           (Json_util.kind_name other))
let missing_field key =
  Error (Printf.sprintf "missing required field '%s'" key)

let field_type_error key expected value =
  Error
    (Printf.sprintf "field '%s' must be %s (received %s)" key expected
       (Json_util.kind_name value))

let required_string_field json key =
  match member key json with
  | `String value -> Ok value
  | `Null -> missing_field key
  | bad -> field_type_error key "a string" bad

let optional_string_field json key =
  match member key json with
  | `String value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a string or null" bad

let required_nullable_nonblank_string_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> missing_field key
  | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (Printf.sprintf "field '%s' must not be blank" key)
  | Some bad -> field_type_error key "a non-empty string or null" bad

let optional_bool_field json key =
  match member key json with
  | `Bool value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a boolean or null" bad

(* Absent reads as [None] here: the exact-lane run summary omits its
   completion fields entirely while a run is still running, rather than
   sending null. *)
let optional_float_field json key =
  match member key json with
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (Float.of_int value))
  | `Null -> Ok None
  | bad -> field_type_error key "a float or null" bad

let required_int_field json key =
  match member key json with
  | `Int value -> Ok value
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "field '%s' has invalid int %S" key raw))
  | `Null -> missing_field key
  | bad -> field_type_error key "an int" bad

let int_field_or json key ~default =
  match member key json with
  | `Null -> Ok default
  | _ -> required_int_field json key
let required_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> missing_field key
  | bad -> field_type_error key "an array" bad

let optional_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | bad -> field_type_error key "an array" bad

let required_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> missing_field key
  | bad -> field_type_error key "an object" bad

let optional_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | bad -> field_type_error key "an object" bad

let decode_list label decode items =
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> (
        match decode item with
        | Ok decoded -> loop (idx + 1) (decoded :: acc) rest
        | Error err -> Error (Printf.sprintf "%s[%d]: %s" label idx err))
  in
  loop 0 [] items
let required_nonnegative_int_field json key =
  let* value = required_int_field json key in
  if value < 0
  then Error (Printf.sprintf "field '%s' must be non-negative" key)
  else Ok value
