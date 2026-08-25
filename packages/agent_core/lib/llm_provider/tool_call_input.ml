type parse_error =
  | Invalid_json of string
  | Not_object

let validate_object = function
  | `Assoc _ as input -> Ok input
  | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    Error Not_object
;;

let parse_object raw =
  match Yojson.Safe.from_string raw with
  | input -> validate_object input
  | exception Yojson.Json_error message -> Error (Invalid_json message)
;;
