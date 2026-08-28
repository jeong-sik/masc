(** Keeper sandbox configuration contract.

    The deterministic part of sandbox selection lives here: parse the
    keeper's declared profile from TOML, reject obsolete aliases, then
    project that profile to the backend-scoped storage root. *)

type sandbox_profile =
  | Local
  | Docker
  | Micro_vm

exception Invalid_keeper_sandbox_config of string

let sandbox_profile_to_string = function
  | Local -> "local"
  | Docker -> "docker"
  | Micro_vm -> "microvm"

let sandbox_profile_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "local" -> Some Local
  | "docker" -> Some Docker
  | "microvm" -> Some Micro_vm
  | _ -> None

let valid_sandbox_profile_strings =
  List.map sandbox_profile_to_string [ Local; Docker; Micro_vm ]

let default_sandbox_profile = Local

let keeper_toml_path ~base_path ~agent_name =
  let keeper_name = Playground_paths.sanitize_keeper_name agent_name in
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Common.masc_dir_from_base_path ~base_path)
          "config")
       "keepers")
    (keeper_name ^ ".toml")

let load_declared_profile ~path =
  if not (Sys.file_exists path)
  then Ok default_sandbox_profile
  else
    match Safe_ops.read_file_safe path with
    | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
    | Ok content -> (
        match Otoml.Parser.from_string_result content with
        | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
        | Ok toml -> (
            match Otoml.find_opt toml Otoml.get_string [ "keeper"; "sandbox_profile" ] with
            | None -> Ok default_sandbox_profile
            | Some raw -> (
                match sandbox_profile_of_string raw with
                | Some profile -> Ok profile
                | None ->
                    Error
                      (Printf.sprintf
                         "%s: invalid sandbox_profile %S (allowed: %s)"
                         path
                         raw
                         (String.concat ", " valid_sandbox_profile_strings)))))

let sandbox_profile_of_agent ~base_path ~agent_name =
  let path = keeper_toml_path ~base_path ~agent_name in
  match load_declared_profile ~path with
  | Ok profile -> profile
  | Error e -> raise (Invalid_keeper_sandbox_config e)

let host_root_rel_of_profile profile name =
  match profile with
  | Local -> Playground_paths.bundle_root name
  | Docker ->
      Printf.sprintf "%s/docker/%s/"
        Playground_paths.all_playgrounds_prefix
        (Playground_paths.sanitize_keeper_name name)
  (* Its own root for the same reason Docker has one: the guest mounts this
     path, and a keeper that moves between profiles must not find the other
     lane's tree already in place. *)
  | Micro_vm ->
      Printf.sprintf "%s/microvm/%s/"
        Playground_paths.all_playgrounds_prefix
        (Playground_paths.sanitize_keeper_name name)

let host_root_rel_of_agent ~base_path ~agent_name =
  sandbox_profile_of_agent ~base_path ~agent_name
  |> fun profile -> host_root_rel_of_profile profile agent_name

let host_root_abs_of_agent ~base_path ~agent_name =
  Filename.concat
    base_path
    (host_root_rel_of_agent ~base_path ~agent_name)

let container_root_of_agent ~agent_name =
  Filename.concat
    (Env_config_sandbox.Runtime.docker_playground_container_root ())
    (Playground_paths.sanitize_keeper_name agent_name)
