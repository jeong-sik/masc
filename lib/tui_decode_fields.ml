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

let optional_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some other ->
    Error
      (Printf.sprintf
         "field '%s' must be an integer or null (received %s)"
         key
         (Json_util.kind_name other))
;;

let decode_string_name_list json key =
  let* items = optional_list_field json key in
  decode_list key
    (fun item ->
       match item with
       | `String value -> Ok value
       | bad -> field_type_error key "a string" bad)
    items

let decode_bool_field_or json key ~default =
  match member key json with
  | `Bool value -> Ok value
  | `Null -> Ok default
  | bad -> field_type_error key "a bool or null" bad

let required_nonempty_string_field json key =
  let* value = required_string_field json key in
  if String.equal value ""
  then Error (Printf.sprintf "field '%s' must be a non-empty string" key)
  else Ok value

(* Name the fields that disagree. The check is strict on purpose -- a dashboard
   payload whose shape has drifted is refused rather than read around -- but the
   refusal used to say only "unknown, duplicate, or missing fields" for a
   nine-kilobyte object, leaving the operator to diff the payload against the
   decoder by hand. The three lists that settle the verdict are the three lists
   worth printing, so the verdict is made from them instead of from a pair of
   length and set comparisons that then get thrown away.

   The wording follows the copy of this check in [Llm_provider.Types], which
   has printed all three groups since it was written: same keys, same
   brackets, so one reader learns one shape.

   Empty groups are left out rather than drawn as "[]" -- this message goes on
   a terminal row, where the surface cuts it. *)
let require_exact_object_fields context expected = function
  | `Assoc fields ->
    let actual = List.map fst fields in
    let seen = List.sort_uniq String.compare actual in
    let unknown = List.filter (fun f -> not (List.mem f expected)) seen in
    let missing =
      List.filter (fun f -> not (List.mem f seen))
        (List.sort_uniq String.compare expected)
    in
    let duplicate =
      List.filter
        (fun f -> List.length (List.filter (String.equal f) actual) > 1)
        seen
    in
    (match (unknown, missing, duplicate) with
     | [], [], [] -> Ok ()
     | _ ->
         let group label = function
           | [] -> None
           | names ->
               Some (Printf.sprintf "%s=[%s]" label (String.concat ", " names))
         in
         let groups =
           List.filter_map
             (fun part -> part)
             [ group "missing" missing
             ; group "unknown" unknown
             ; group "duplicates" duplicate
             ]
         in
         Error
           (Printf.sprintf "%s fields mismatch (%s)" context
              (String.concat ", " groups)))
  | _ -> Error (context ^ " must be an object")
;;
