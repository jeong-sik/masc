type error = Invalid_workspace of Config_dir_resolver.canonical_base_path_error

type lookup =
  | Not_registered
  | Uninitialized
  | Ready of Skill_catalog_snapshot.t

let workspace base_path =
  Skill_catalog_snapshot_service.workspace_of_base_path ~base_path
  |> Result.map_error (fun error -> Invalid_workspace error)
;;

let refresh_from_runtime_file ~base_path =
  Result.map
    (fun workspace ->
       Skill_catalog_snapshot_service.refresh
         ~workspace
         ~user_home:Config_dir_resolver.initial_env_home
         ~read_config:(fun () ->
           match Runtime.load_config_text () with
           | Ok (_path, config_text) -> Config_text config_text
           | Error detail -> Config_unreadable detail))
    (workspace base_path)
;;

let lookup ~base_path =
  Skill_catalog_snapshot_service.find_workspace_of_base_path ~base_path
  |> Result.map_error (fun error -> Invalid_workspace error)
  |> Result.map (function
    | None -> Not_registered
    | Some workspace ->
      (match Skill_catalog_snapshot_service.current ~workspace with
       | None -> Uninitialized
       | Some snapshot -> Ready snapshot))
;;

let error_to_string = function
  | Invalid_workspace error ->
    Config_dir_resolver.canonical_base_path_error_to_string error
;;
