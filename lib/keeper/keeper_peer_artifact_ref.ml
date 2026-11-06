type t = string

let of_blob (blob : Tool_output.artifact_ref) = blob.sha256

let of_json = function
  | `String sha256 ->
    Tool_output.validate_sha256 sha256
    |> Result.map (fun () -> sha256)
    |> Result.map_error (fun error ->
      "Artifact must be the sha256 an export returned: "
      ^ Tool_output.invalid_sha256_to_string error)
  | `Assoc _ | `List _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ ->
    Error "Artifact must be the sha256 string an export returned"
;;

let to_json sha256 = `String sha256
