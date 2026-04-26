type t =
  | Local_playground
  | Docker

let to_string = function
  | Local_playground -> "local_playground"
  | Docker -> "docker"
;;

let of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "local_playground" | "local" -> Some Local_playground
  | "docker" -> Some Docker
  | _ -> None
;;

let to_yojson backend = `String (to_string backend)

let of_yojson = function
  | `String value ->
    (match of_string value with
     | Some backend -> Ok backend
     | None -> Error (Printf.sprintf "unknown worker execution backend: %s" value))
  | _ -> Error "worker execution backend must be a string"
;;
