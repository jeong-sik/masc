module Bundle = World_configuration_bundle

type error =
  | Invalid_base_path of Config_dir_resolver.canonical_base_path_error
  | Config_root_unavailable of string
  | Read_failed of { path : string; detail : string }
  | Configuration_lock_failed of string
  | Invalid_bundle of Bundle.error

type receipt =
  { bundle : Bundle.t
  ; lock_warnings : Runtime.config_lock_warning list
  }

let ( let* ) = Result.bind

let error_to_string = function
  | Invalid_base_path error -> Config_dir_resolver.canonical_base_path_error_to_string error
  | Config_root_unavailable path -> "world config root is unavailable: " ^ path
  | Read_failed { path; detail } -> "world configuration read failed at " ^ path ^ ": " ^ detail
  | Configuration_lock_failed detail -> "world configuration lock failed: " ^ detail
  | Invalid_bundle error -> Bundle.error_to_string error

let read_error path error =
  Read_failed { path; detail = Fs_compat.owned_regular_file_read_error_to_string error }

let read_optional ~ownership_root path =
  Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root path
  |> Result.map (Option.map (fun (file : Fs_compat.owned_regular_file_contents) -> file.content))
  |> Result.map_error (read_error path)

let read_keepers ~config_root ~keepers_dir =
  let* names = Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
    ~ownership_root:config_root keepers_dir
    |> Result.map_error (read_error keepers_dir) in
  let names = match names with None -> [] | Some names -> List.sort String.compare names in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | filename :: rest ->
      if Filename.check_suffix filename Config_dir_resolver.keeper_toml_suffix then
        let path = Filename.concat keepers_dir filename in
        let* content = read_optional ~ownership_root:config_root path in
        (match content with
         | None -> Error (Read_failed { path; detail = "listed Keeper declaration disappeared" })
         | Some content ->
           let name = Filename.remove_extension filename in
           loop ((name, content) :: acc) rest)
      else loop acc rest
  in
  loop [] names

let capture ~base_path =
  let* base_path = Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error (fun error -> Invalid_base_path error) in
  let resolved = Config_dir_resolver.resolve_for_base_path ~base_path in
  let config_root = resolved.config_root.path in
  if not resolved.config_root.exists then Error (Config_root_unavailable config_root)
  else
    let runtime_path = Filename.concat config_root Config_dir_resolver.runtime_toml_filename in
    let override_root = Config_dir_resolver.masc_root ~base_path in
    let override_path = Filename.concat override_root Prompt_override_persistence.filename in
    let captured = Runtime.with_config_lock_observed ~runtime_config_path:runtime_path (fun () ->
      Prompt_registry.with_override_snapshot (fun () ->
        let* runtime = read_optional ~ownership_root:config_root runtime_path in
        let* overrides = read_optional ~ownership_root:override_root override_path in
        let* keepers = read_keepers ~config_root ~keepers_dir:resolved.keepers.path in
        Ok (runtime, overrides, keepers))) in
    match captured with
    | Error detail -> Error (Configuration_lock_failed detail)
    | Ok { Runtime.value = Error error; _ } -> Error error
    | Ok { Runtime.value = Ok (runtime, overrides, keepers); warnings } ->
      let* bundle = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
        Bundle.make ~origin:{ base_path; config_root } ~runtime ~overrides ~keepers)
        |> Result.map_error (fun error -> Invalid_bundle error) in
      Ok { bundle; lock_warnings = warnings }
