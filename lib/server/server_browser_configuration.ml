let load ~base_path =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path in
  let path = Filename.concat resolution.Config_dir_resolver.config_root.path
      Config_dir_resolver.runtime_toml_filename in
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Browser_configuration.none
  | exception Unix.Unix_error (code, _, _) -> Error (Unix.error_message code)
  | _ ->
    match Safe_ops.read_file_safe path with
    | Error detail -> Error detail
    | Ok text ->
      match Otoml.Parser.from_string_result text with
      | Error detail -> Error detail
      | Ok toml -> Browser_configuration.parse toml
;;
