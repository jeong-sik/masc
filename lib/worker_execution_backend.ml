type t =
  | Local
  | Docker

let to_string = function
  | Local -> "local"
  | Docker -> "docker"

let of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "local" -> Some Local
  | "docker" -> Some Docker
  | _ -> None

let to_yojson backend =
  `String (to_string backend)

let of_yojson = function
  | `String value -> (
      match of_string value with
      | Some backend -> Ok backend
      | None ->
          Error
            (Printf.sprintf "unknown worker execution backend: %s" value))
  | _ -> Error "worker execution backend must be a string"
