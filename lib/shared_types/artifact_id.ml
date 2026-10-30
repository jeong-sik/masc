type t = string

let generate = Random_id.uuid_v7

let of_string s =
  Random_id.parse_uuid_v7 s
  |> Result.map_error (fun error -> "Artifact_id.of_string: " ^ error)

let to_string t = t

let compare = String.compare

let equal = String.equal

let to_json t = `String t

let of_json = function
  | `String s -> of_string s
  | _ -> Error "Artifact_id.of_json: expected string"
