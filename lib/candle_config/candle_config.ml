(* See candle_config.mli. *)

type t =
  | Off
  | Enabled
  | Disabled of { reason : string }

let table_fields = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Some fields
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> None
;;

let of_toml_string text =
  match Otoml.Parser.from_string_result text with
  | Error message ->
    Disabled { reason = Printf.sprintf "candle.toml is not valid TOML: %s" message }
  | Ok toml ->
    (match table_fields toml with
     | None -> Disabled { reason = "candle.toml is not a table" }
     | Some [] -> Enabled
     | Some ((key, _) :: _) ->
       Disabled
         { reason =
             Printf.sprintf "candle.toml has the key %S, which this build does not know" key
         })
;;

(* [Sys.file_exists] answers false for every failed stat, not only for a file
   that is not there, so an enabled Candle would turn off without a word when
   the config directory stopped being searchable. Only ENOENT is absence. *)
let load_file ~path =
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Off
  | exception Unix.Unix_error (error, _, _) ->
    Disabled
      { reason =
          Printf.sprintf "candle.toml could not be examined: %s" (Unix.error_message error)
      }
  | (_ : Unix.stats) ->
    (match In_channel.with_open_bin path In_channel.input_all with
     | text -> of_toml_string text
     | exception Sys_error detail ->
       Disabled { reason = Printf.sprintf "candle.toml could not be read: %s" detail })
;;

let load ~base_path =
  load_file ~path:(Config_dir_resolver.candle_toml_path_for_base_path ~base_path)
;;

let to_string = function
  | Off -> "candle off (no candle.toml)"
  | Enabled -> "candle enabled"
  | Disabled { reason } -> Printf.sprintf "candle disabled: %s" reason
;;
