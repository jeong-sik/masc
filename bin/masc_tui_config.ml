(* TUI settings read from the [tui] table of runtime.toml. The server reads the
   rest of that file for its own turn/provider config; the TUI reads only the
   handful of keys it draws, so this stays a small client-side read rather than
   a round-trip through the server. The path is resolved the same way
   keeper_runtime_config resolves it, so both processes read one file. *)

let runtime_toml_path ~base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with { inputs with env_base_path = Some base_path }
  in
  Filename.concat resolution.Config_dir_resolver.config_root.path
    Config_dir_resolver.runtime_toml_filename

let doc_of_path path =
  match Fs_compat.load_file path with
  | exception Sys_error _ -> None
  | content -> ( match Keeper_toml_loader.parse_toml content with
                 | Ok doc -> Some doc
                 | Error _ -> None)

(* The reader's chosen theme name, [tui].theme. Kept pure so a test can hand it
   a parsed doc without a file: every absence -- file gone, table missing, key
   missing -- reads the same as "no stored choice", and the caller then follows
   the terminal exactly as it did before this key existed. *)
let theme_of_doc doc = Keeper_toml_loader.toml_string_opt doc "tui.theme"

let theme ~base_path =
  match doc_of_path (runtime_toml_path ~base_path) with
  | None -> None
  | Some doc -> theme_of_doc doc
