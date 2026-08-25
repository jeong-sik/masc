type t = Yojson.Safe.t

(* Walks the whole document, not just its top level: a repeated key nested in
   [user.profile] reaches a reader through [object_field] exactly like one at
   the root, so both have to be rejected at the same point. *)
let rec first_repeated_key (json : Yojson.Safe.t) : string option =
  match json with
  | `Assoc fields ->
    let rec scan seen = function
      | [] -> None
      | (key, value) :: rest ->
        if List.exists (String.equal key) seen
        then Some key
        else (
          match first_repeated_key value with
          | Some _ as repeated -> repeated
          | None -> scan (key :: seen) rest)
    in
    scan [] fields
  | `List items -> List.find_map first_repeated_key items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> None
;;

let parse ~context body =
  match Safe_ops.parse_json_safe ~context body with
  | Error _ as error -> error
  | Ok json ->
    (match first_repeated_key json with
     | Some key ->
       Error (Printf.sprintf "%s: response repeats object key %S" context key)
     | None -> Ok json)
;;

(* [List.assoc_opt] returns the first binding for a key. That is the whole
   reason this module exists, and it is safe here only because [parse] has
   already rejected every document in which a key has more than one. *)
let field name (json : t) =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    None
;;

let bool_field name json =
  match field name json with
  | Some (`Bool value) -> Some value
  | Some _ | None -> None
;;

let string_field name json =
  match field name json with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

let int_field name json =
  match field name json with
  | Some (`Int value) -> Some value
  | Some _ | None -> None
;;

let object_field name json =
  match field name json with
  | Some (`Assoc _ as value) -> Some value
  | Some _ | None -> None
;;

let to_yojson json = json
