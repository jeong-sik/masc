(** Pure admission for the dashboard prompt-override request body. *)

let ( let* ) = Result.bind

type t =
  | Set of
      { key : string
      ; value : string
      }
  | Clear of { key : string }

type error =
  | Invalid_json of string
  | Expected_object
  | Missing_key
  | Key_must_be_string
  | Empty_key
  | Key_has_surrounding_whitespace
  | Duplicate_key
  | Missing_action
  | Action_must_be_string
  | Duplicate_action
  | Unsupported_action of string
  | Missing_value
  | Value_must_be_string
  | Duplicate_value

type field =
  | Absent
  | Present of Yojson.Safe.t
  | Duplicate

let field name fields =
  match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
  | [] -> Absent
  | [ value ] -> Present value
  | _ :: _ :: _ -> Duplicate
;;

let key_of_fields fields =
  match field "key" fields with
  | Absent -> Error Missing_key
  | Duplicate -> Error Duplicate_key
  | Present (`String key) ->
    let canonical = String.trim key in
    if String.equal canonical ""
    then Error Empty_key
    else if not (String.equal canonical key)
    then Error Key_has_surrounding_whitespace
    else Ok key
  | Present _ -> Error Key_must_be_string
;;

let action_of_fields fields =
  match field "action" fields with
  | Absent -> Error Missing_action
  | Duplicate -> Error Duplicate_action
  | Present (`String action) -> Ok action
  | Present _ -> Error Action_must_be_string
;;

let value_of_fields fields =
  match field "value" fields with
  | Absent -> Error Missing_value
  | Duplicate -> Error Duplicate_value
  | Present (`String value) -> Ok value
  | Present _ -> Error Value_must_be_string
;;

let decode_json = function
  | `Assoc fields ->
    let* key = key_of_fields fields in
    let* action = action_of_fields fields in
    (match action with
     | "clear" -> Ok (Clear { key })
     | "set" ->
       let* value = value_of_fields fields in
       Ok (Set { key; value })
     | action -> Error (Unsupported_action action))
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _ -> Error Expected_object
;;

let decode body =
  try decode_json (Yojson.Safe.from_string body) with
  | Yojson.Json_error message -> Error (Invalid_json message)
;;

let key = function
  | Set { key; _ } | Clear { key } -> key
;;

let error_message = function
  | Invalid_json message -> "Invalid JSON: " ^ message
  | Expected_object -> "request body must be an object"
  | Missing_key | Empty_key -> "key is required"
  | Key_must_be_string -> "key must be a string"
  | Key_has_surrounding_whitespace -> "key must not contain surrounding whitespace"
  | Duplicate_key -> "duplicate key field"
  | Missing_action -> "action is required"
  | Action_must_be_string -> "action must be a string"
  | Duplicate_action -> "duplicate action field"
  | Unsupported_action action -> Printf.sprintf "unsupported action: %s" action
  | Missing_value -> "value is required for set"
  | Value_must_be_string -> "value must be a string"
  | Duplicate_value -> "duplicate value field"
;;
