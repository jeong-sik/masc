let table_name = "maintenance"

let retention_days_key = "jsonl_retention_days"

type diagnostic =
  | Toml_syntax of string
  | Unreadable_file of string
  | Not_a_table
  | Unexpected_field of string
  | Retention_days_not_an_integer of string
  | Retention_days_not_positive of int

let diagnostic_to_string = function
  | Toml_syntax msg -> Printf.sprintf "invalid TOML: %s" msg
  | Unreadable_file msg -> Printf.sprintf "cannot read runtime.toml: %s" msg
  | Not_a_table -> Printf.sprintf "[%s] must be a TOML table" table_name
  | Unexpected_field key ->
    Printf.sprintf "[%s]: unknown key %S" table_name key
  | Retention_days_not_an_integer detail ->
    Printf.sprintf "[%s].%s must be an integer; %s" table_name retention_days_key detail
  | Retention_days_not_positive value ->
    Printf.sprintf "[%s].%s must be a positive integer; got %d" table_name retention_days_key
      value

let entries_of_table = function
  | Otoml.TomlTable entries | Otoml.TomlInlineTable entries -> Ok entries
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ -> Error [ Not_a_table ]

let parse_string content =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error [ Toml_syntax msg ]
  | Ok toml ->
    (match Otoml.find_opt toml Fun.id [ table_name ] with
     | None -> Ok None
     | Some table_value ->
       (match entries_of_table table_value with
        | Error _ as error -> error
        | Ok entries ->
          let unexpected =
            List.filter_map
              (fun (key, _) ->
                 if String.equal key retention_days_key then None else Some key)
              entries
          in
          (match unexpected with
           | key :: _ -> Error [ Unexpected_field key ]
           | [] ->
             (match Otoml.find_opt table_value Otoml.get_integer [ retention_days_key ] with
              | None -> Ok None
              | Some days when days > 0 -> Ok (Some days)
              | Some days -> Error [ Retention_days_not_positive days ]
              | exception Otoml.Type_error detail ->
                Error [ Retention_days_not_an_integer detail ]))))

type source =
  | Env
  | Toml
  | Default

let resolve_retention_days ~config_path =
  let env_key = Env_config_core.jsonl_retention_days_env_key in
  match Env_config_core.trim_opt (Env_config_core.raw_value_opt env_key) with
  | Some _ -> (Env_config_core.jsonl_retention_days (), Env, [])
  | None ->
    (* Env is unset, so the getter below answers the documented default;
       the default stays single-sourced there. *)
    let default () = Env_config_core.jsonl_retention_days () in
    (match
       (match Fs_compat.load_file_opt config_path with
        | None -> Ok None
        | Some content -> parse_string content
        | exception Sys_error detail -> Error [ Unreadable_file detail ])
     with
     | Ok None -> (default (), Default, [])
     | Ok (Some days) -> (days, Toml, [])
     | Error diagnostics -> (default (), Default, diagnostics))
