type fields = (string * Yojson.Safe.t) list

let ( let* ) = Result.bind

let object_fields ~context = function
  | `Assoc fields -> Ok fields
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as other ->
    Error (Printf.sprintf "%s: expected an object, got %s" context (Json_util.kind_name other))
;;

let take ~context key fields =
  match List.partition (fun (name, _) -> String.equal name key) fields with
  | [ (_, value) ], rest -> Ok (value, rest)
  | [], _ -> Error (Printf.sprintf "%s: field %S is missing" context key)
  | _ :: _ :: _, _ -> Error (Printf.sprintf "%s: field %S appears more than once" context key)
;;

let field ~context key decode fields =
  let* value, rest = take ~context key fields in
  match decode value with
  | Ok decoded -> Ok (decoded, rest)
  | Error detail -> Error (Printf.sprintf "%s.%s: %s" context key detail)
;;

let finish ~context = function
  | [] -> Ok ()
  | (name, _) :: _ -> Error (Printf.sprintf "%s: unknown field %S" context name)
;;

let wrong_kind ~expected other =
  Error (Printf.sprintf "expected %s, got %s" expected (Json_util.kind_name other))
;;

let as_string = function
  | `String text -> Ok text
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) as other ->
    wrong_kind ~expected:"a string" other
;;

let as_non_blank json =
  let* text = as_string json in
  if String.equal (String.trim text) "" then Error "must not be blank" else Ok text
;;

let as_int = function
  | `Int number -> Ok number
  | (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) as other ->
    wrong_kind ~expected:"an integer" other
;;

let as_list decode = function
  | `List items ->
    let rec go index decoded = function
      | [] -> Ok (List.rev decoded)
      | item :: rest ->
        (match decode item with
         | Ok value -> go (index + 1) (value :: decoded) rest
         | Error detail -> Error (Printf.sprintf "item %d: %s" index detail))
    in
    go 0 [] items
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) as other ->
    wrong_kind ~expected:"a list" other
;;

let as_nullable decode = function
  | `Null -> Ok None
  | (`Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _) as other ->
    Result.map Option.some (decode other)
;;
