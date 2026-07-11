(** Keeper sandbox configuration contract.

    This neutral module owns the canonical profile type, codec, default, and
    backend-scoped storage projection. Keeper TOML resolution is owned by
    [Keeper_types_profile]; this module never reparses a manifest. *)

type sandbox_profile =
  | Local
  | Docker

let sandbox_profile_to_string = function
  | Local -> "local"
  | Docker -> "docker"

let sandbox_profile_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "local" -> Some Local
  | "docker" -> Some Docker
  | _ -> None

let all_sandbox_profiles = [ Local; Docker ]

let valid_sandbox_profile_strings =
  List.map sandbox_profile_to_string all_sandbox_profiles

let default_sandbox_profile = Docker

let host_root_rel_of_profile profile name =
  match profile with
  | Local -> Playground_paths.bundle_root name
  | Docker ->
      Printf.sprintf "%s/docker/%s/"
        Playground_paths.all_playgrounds_prefix
        (Playground_paths.sanitize_keeper_name name)
