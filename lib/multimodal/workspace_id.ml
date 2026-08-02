(* Workspace_id — Cycle 25 / Tier B10.
   See workspace_id.mli for design rationale.

   Internal representation reuses the same UUID v7 shape as
   Shared_types.Artifact_id but is a distinct nominal type so the
   compiler rejects mistaken cross-domain assignment. *)

type t = string

let max_length = 64

let generate = Random_id.uuid_v7

let of_string s =
  if s = "" then Error "Workspace_id.of_string: empty string"
  else if String.length s > max_length then
    Error
      (Printf.sprintf
         "Workspace_id.of_string: length %d exceeds max %d"
         (String.length s) max_length)
  else
    Random_id.parse_uuid_v7 s
    |> Result.map_error (fun error -> "Workspace_id.of_string: " ^ error)

let to_string t = t

let compare = String.compare

let equal = String.equal

let to_json t = `String t

let of_json = function
  | `String s -> of_string s
  | _ -> Error "Workspace_id.of_json: expected string"
