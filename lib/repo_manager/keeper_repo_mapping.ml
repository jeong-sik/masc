let ( let* ) = Result.bind

let mappings_toml_path base_path =
  Config_dir_resolver.keeper_repo_mappings_toml_path ~base_path
;;

let mapping_of_toml toml keeper_id =
  let path field = [ "mapping"; keeper_id; field ] in
  let* repository_ids =
    Otoml.Helpers.find_strings_result toml (path "repositories")
  in
  Ok (Repo_manager_types.make_keeper_repo_mapping ~keeper_id ~repository_ids)
;;

let toml_of_mapping (mapping : Repo_manager_types.keeper_repo_mapping) =
  Otoml.TomlTable
    [ ( "repositories"
      , Otoml.TomlArray
          (List.map (fun repository_id -> Otoml.TomlString repository_id)
             mapping.repository_ids) )
    ]
;;

let log_mapping_file_warning path message =
  Log.Misc.warn
    "[KeeperRepoMapping] mapping file %s unreadable (%s)"
    path
    message
;;

let load_file_content path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))
;;

let read_mapping_file ~base_path =
  Eio_guard.run_in_systhread (fun () ->
    let path = mappings_toml_path base_path in
    match load_file_content path with
    | content -> Ok (Some content)
    | exception Sys_error _ when not (Sys.file_exists path) -> Ok None
    | exception Sys_error message ->
      log_mapping_file_warning path message;
      Error message
    | exception End_of_file ->
      let message = "unexpected end of mapping file" in
      log_mapping_file_warning path message;
      Error message)
;;

let toml_table_fields table =
  try Some (Otoml.get_table table) with
  | Otoml.Type_error _ -> None
;;

let parse_mapping_content content =
  match Otoml.Parser.from_string_result content with
  | Error message -> Error message
  | Ok toml ->
    (match Otoml.find_opt toml Fun.id [ "mapping" ] with
     | None -> Ok []
     | Some mapping ->
       (match toml_table_fields mapping with
        | None -> Error "mapping field must be a table"
        | Some fields ->
          let rec loop parsed = function
            | [] -> Ok (List.rev parsed)
            | (keeper_id, value) :: rest ->
              if Repo_manager_types.is_toml_table value
              then (
                let mapping_toml =
                  Otoml.TomlTable
                    [ "mapping", Otoml.TomlTable [ keeper_id, value ] ]
                in
                match mapping_of_toml mapping_toml keeper_id with
                | Ok mapping -> loop (mapping :: parsed) rest
                | Error message -> Error message)
              else Error (Printf.sprintf "mapping.%s must be a table" keeper_id)
          in
          loop [] fields))
;;

let load_all ~base_path =
  let* content = read_mapping_file ~base_path in
  match content with
  | None -> Ok []
  | Some content -> parse_mapping_content content
;;

let save_all ~base_path mappings =
  let path = mappings_toml_path base_path in
  let table =
    List.map
      (fun (mapping : Repo_manager_types.keeper_repo_mapping) ->
        mapping.keeper_id, toml_of_mapping mapping)
      mappings
  in
  let toml = Otoml.TomlTable [ "mapping", Otoml.TomlTable table ] in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path (Otoml.Printer.to_string toml)
;;

let save_mapping
    ~base_path
    (mapping : Repo_manager_types.keeper_repo_mapping)
  =
  let mapping =
    Repo_manager_types.make_keeper_repo_mapping
      ~keeper_id:mapping.keeper_id
      ~repository_ids:mapping.repository_ids
  in
  let path = mappings_toml_path base_path in
  try
    Fs_compat.mkdir_p (Filename.dirname path);
    File_lock_eio.with_lock path (fun () ->
      let* mappings = load_all ~base_path in
      let other_mappings =
        List.filter
          (fun (existing : Repo_manager_types.keeper_repo_mapping) ->
            not (String.equal existing.keeper_id mapping.keeper_id))
          mappings
      in
      save_all ~base_path (mapping :: other_mappings))
  with
  | File_lock_eio.Flock_timeout { path; attempts; _ } ->
    Error
      (Printf.sprintf
         "timed out acquiring keeper repo mapping lock %s after %d attempts"
         path
         attempts)
  | Sys_error message -> Error message
;;
