type engine = Docker_engine of string | Apple_app_root of string
type engine_fault =
  | Unreachable of string
  | Identity_unreadable of string

let engine_equal left right = match left, right with
  | Docker_engine a, Docker_engine b -> String.equal a b
  | Apple_app_root a, Apple_app_root b -> String.equal a b
  | Docker_engine _, Apple_app_root _ | Apple_app_root _, Docker_engine _ -> false

let engine_to_string = function
  | Docker_engine id -> "docker engine " ^ id
  | Apple_app_root root -> "Apple container service at " ^ root

let engine_to_json = function
  | Docker_engine id -> `Assoc ["kind", `String "docker"; "id", `String id]
  | Apple_app_root root -> `Assoc ["kind", `String "apple_container"; "app_root", `String root]

let engine_of_json = function
  | `Assoc fields ->
      (match List.sort (fun (a, _) (b, _) -> String.compare a b) fields with
       | ["id", `String id; "kind", `String "docker"] when String.trim id <> "" ->
           Ok (Docker_engine id)
       | ["app_root", `String root; "kind", `String "apple_container"] when String.trim root <> "" ->
           Ok (Apple_app_root root)
       | _ -> Error "invalid container engine identity")
  | _ -> Error "invalid container engine identity"
