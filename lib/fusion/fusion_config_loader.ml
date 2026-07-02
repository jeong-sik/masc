(* Fusion — runtime.toml [fusion] 로딩 (구현).
   계약/문서: fusion_config_loader.mli, docs/rfc/RFC-0252 §9 *)

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

let runtime_id_of_model_in_preset model_id = model_id

let model_declares_structured_output (cfg : Runtime_schema.config) runtime_id :
  (unit, string) result =
  match
    List.find_opt
      (fun (b : Runtime_schema.binding) -> String.equal (Runtime_schema.binding_key b) runtime_id)
      cfg.bindings
  with
  | None -> Error (Printf.sprintf "runtime %S not found" runtime_id)
  | Some binding ->
    (match Runtime_schema.model_of_id cfg binding.Runtime_schema.model_id with
     | None -> Error (Printf.sprintf "model for runtime %S not found" runtime_id)
     | Some spec ->
       (match spec.Runtime_schema.capabilities with
        | Some caps when caps.Runtime_schema.supports_structured_output -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "runtime %S uses model %S, which does not declare supports-structured-output"
               runtime_id
               spec.Runtime_schema.id)))

let validate_preset_structured_output cfg (preset : Fusion_policy.Validated_preset.t) :
  (unit, string) result =
  let p = Fusion_policy.Validated_preset.preset preset in
  let panel_runtime_ids =
    List.concat_map (fun (g : Fusion_policy.panel_group) -> g.models) p.panels
  in
  let judge_runtime_ids = p.judge :: List.map (fun (j : Fusion_policy.judge_spec) -> j.jmodel) p.judges in
  let runtime_ids = panel_runtime_ids @ judge_runtime_ids in
  List.fold_left
    (fun acc id ->
       match acc with
       | Error _ -> acc
       | Ok () ->
         if String.equal id "" then Ok () else model_declares_structured_output cfg id)
    (Ok ())
    runtime_ids

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
       | Error errs ->
         Error
           (Printf.sprintf
              "fusion config invalid: %s"
              (String.concat "; " (List.map Fusion_config.show_config_error errs)))
       | Ok policy ->
         if not policy.Fusion_policy.enabled
         then Ok policy
         else (
           match Runtime_toml.parse_file path with
           | Error errs ->
             Error
               (Printf.sprintf
                  "runtime.toml parse error: %s"
                  (String.concat "; " (List.map Runtime_toml.show_parse_error errs)))
           | Ok cfg ->
             let presets = policy.Fusion_policy.presets in
             (match
                List.fold_left
                  (fun acc preset ->
                     match acc with
                     | Error _ -> acc
                     | Ok () -> validate_preset_structured_output cfg preset)
                  (Ok ())
                  presets
              with
              | Error msg -> Error (Printf.sprintf "fusion preset invalid: %s" msg)
              | Ok () -> Ok policy)))
