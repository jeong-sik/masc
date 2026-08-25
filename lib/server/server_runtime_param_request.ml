(** Pure admission for dashboard runtime-parameter request bodies. *)

let ( let* ) = Result.bind

type set_request =
  { param_key : string
  ; value : Yojson.Safe.t
  }

type clear_request = { param_key : string }

type error =
  | Invalid_json of string
  | Expected_object
  | Missing_param_key
  | Param_key_must_be_string
  | Empty_param_key
  | Param_key_has_surrounding_whitespace
  | Duplicate_param_key
  | Missing_value
  | Duplicate_value

type field =
  | Absent
  | Present of Yojson.Safe.t
  | Duplicate

let field name fields =
  match
    List.filter_map
      (fun (key, value) -> if String.equal key name then Some value else None)
      fields
  with
  | [] -> Absent
  | [ value ] -> Present value
  | _ :: _ :: _ -> Duplicate
;;

let param_key_of_fields fields =
  match field "param_key" fields with
  | Absent -> Error Missing_param_key
  | Duplicate -> Error Duplicate_param_key
  | Present (`String param_key) ->
    let canonical = String.trim param_key in
    if String.equal canonical ""
    then Error Empty_param_key
    else if not (String.equal canonical param_key)
    then Error Param_key_has_surrounding_whitespace
    else Ok param_key
  | Present _ -> Error Param_key_must_be_string
;;

let decode_json decode_fields = function
  | `Assoc fields -> decode_fields fields
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _ -> Error Expected_object
;;

let decode_body decode_fields body =
  try decode_json decode_fields (Yojson.Safe.from_string body) with
  | Yojson.Json_error message -> Error (Invalid_json message)
;;

let decode_set body =
  decode_body
    (fun fields ->
       let* param_key = param_key_of_fields fields in
       match field "value" fields with
       | Absent -> Error Missing_value
       | Duplicate -> Error Duplicate_value
       | Present value -> Ok { param_key; value })
    body
;;

let decode_clear body =
  decode_body
    (fun fields ->
       let* param_key = param_key_of_fields fields in
       Ok { param_key })
    body
;;

let set_param_key (request : set_request) = request.param_key
let set_value (request : set_request) = request.value
let clear_param_key (request : clear_request) = request.param_key

let error_message = function
  | Invalid_json message -> "Invalid JSON: " ^ message
  | Expected_object -> "request body must be an object"
  | Missing_param_key | Empty_param_key -> "param_key is required"
  | Param_key_must_be_string -> "param_key must be a string"
  | Param_key_has_surrounding_whitespace ->
    "param_key must not contain surrounding whitespace"
  | Duplicate_param_key -> "duplicate param_key field"
  | Missing_value -> "value is required"
  | Duplicate_value -> "duplicate value field"
;;
