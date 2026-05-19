type t =
  | Local_playground
  | Docker

let to_string = function
  | Local_playground -> "local_playground"
  | Docker -> "docker"

let of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "local_playground" | "local" -> Some Local_playground
  | "docker" -> Some Docker
  | _ -> None

let to_yojson backend =
  `String (to_string backend)

let json_kind_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

let of_yojson = function
  | `String value -> (
      match of_string value with
      | Some backend -> Ok backend
      | None ->
          Error
            (Printf.sprintf "unknown worker execution backend: %s" value))
  | other ->
      Error
        (Printf.sprintf
           "worker execution backend must be a string (received %s)"
           (json_kind_name other))
