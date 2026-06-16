(* Fusion — runtime.toml [fusion] 로딩 (구현).
   계약/문서: fusion_config_loader.mli, docs/rfc/RFC-0249 §9 *)

(* base_path 기준 runtime.toml 절대경로. Config_dir_resolver SSOT 재사용
   (MASC_CONFIG_DIR override + <base_path>/.masc/config/ fallback 모두 honored). *)
let runtime_toml_path ~base_path : string =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with
      { inputs with Config_dir_resolver.env_base_path = Some base_path }
  in
  Filename.concat
    resolution.Config_dir_resolver.config_root.Config_dir_resolver.path
    Config_dir_resolver.runtime_toml_filename

let load ~base_path : (Fusion_policy.t, string) result =
  let path = runtime_toml_path ~base_path in
  if not (Sys.file_exists path) then Ok Fusion_config.disabled
  else
    match Otoml.Parser.from_file path with
    | exception Otoml.Parse_error (_, msg) ->
      Error (Printf.sprintf "runtime.toml parse error: %s" msg)
    | exception Sys_error msg -> Error (Printf.sprintf "runtime.toml read error: %s" msg)
    | toml ->
      (match Fusion_config.of_toml toml with
       | Ok policy -> Ok policy
       | Error errs ->
         Error
           (Printf.sprintf
              "fusion config invalid: %s"
              (String.concat "; " (List.map Fusion_config.show_config_error errs))))
