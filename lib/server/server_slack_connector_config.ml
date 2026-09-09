type error =
  | Unreadable of string
  | Invalid_toml of string
  | Invalid_enabled of string

let error_to_string = function
  | Unreadable path -> "Slack connector configuration cannot be read: " ^ path
  | Invalid_toml path -> "Slack connector configuration is invalid TOML: " ^ path
  | Invalid_enabled path -> "slack.enabled must be a boolean in " ^ path
;;

let load ~path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Env_config_slack.Enabled
  | exception Unix.Unix_error _ -> Error (Unreadable path)
  | _ ->
    (match Safe_ops.read_file_safe path with
     | Error _ -> Error (Unreadable path)
     | Ok contents ->
       (match Otoml.Parser.from_string_result contents with
        | Error _ -> Error (Invalid_toml path)
        | Ok toml ->
          (match Field_resolution.resolve_bool toml [ "slack"; "enabled" ] with
           | Field_resolution.Missing | Field_resolution.Present true ->
             Ok Env_config_slack.Enabled
           | Field_resolution.Present false -> Ok Env_config_slack.Disabled
           | Field_resolution.Type_mismatch _ -> Error (Invalid_enabled path))))
;;

let configure ~config_root =
  let path = Filename.concat config_root Config_dir_resolver.runtime_toml_filename in
  let state =
    match load ~path with
    | Ok state -> state
    | Error error ->
      let detail = error_to_string error in
      Log.Server.error "%s; Slack connector will not start" detail;
      Env_config_slack.Invalid_configuration detail
  in
  Env_config_slack.configure_connector state
;;
