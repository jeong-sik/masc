(* Whether AGENT_CORE_MODEL_CATALOG names a full replacement is one answer,
   [Runtime.exact_output_target_source]: installing the catalog, warning
   about retired config-root catalogs, choosing where the exact targets come
   from, and whether rule 3 applies to runtime.toml all read it there. *)
let replacement_catalog_path ?env () =
  match Runtime.exact_output_target_source ?env () with
  | Runtime.Replacement_catalog_targets { path } -> Some path
  | Runtime.Runtime_binding_targets -> None

let install_runtime_model_catalog_override ~load_catalog ~publish_catalog path =
  let refuse detail =
    raise (Env_config_core.Config_error (Printf.sprintf "catalog %s: %s" path detail)) in
  match load_catalog path with
  | Error detail -> refuse detail
  | Ok catalog ->
    (match Llm_provider.Catalog_snapshot.of_catalogs
        ~models:(Some catalog) ~providers:None with
     | Ok snapshot -> publish_catalog snapshot
     | Error error -> refuse (Llm_provider.Catalog_snapshot.error_to_string error))

let configure_agent_core_model_catalog_env
      ?env
      ?(agent_core_catalog = fun () ->
        Llm_provider.Catalog_snapshot.models (Llm_provider.Catalog_snapshot.current ()))
      ?(load_catalog = Llm_provider.Model_catalog.load_file)
      ?(publish_catalog = Llm_provider.Catalog_snapshot.publish)
      ()
  =
  match replacement_catalog_path ?env () with
  | Some path ->
    install_runtime_model_catalog_override ~load_catalog ~publish_catalog path;
    Log.Misc.info
      "model_catalog: AGENT_CORE_MODEL_CATALOG=%s already configured and loaded"
      path;
    Some path
  | None ->
    (match agent_core_catalog () with
     | Some _ ->
       Log.Misc.info
         "model_catalog: no explicit catalog path resolved; using agent_core ambient \
          model catalog"
     | None ->
       raise (Env_config_core.Config_error "model_catalog: AGENT_CORE embedded model catalog is unavailable"));
    None

type standalone_gate =
  | Routing_only
  | Catalog_required

(* The catalog is selected inside the same call that reads runtime.toml. A
   refused catalog and a [Config_error] the read itself raises both leave as
   [Error], so no caller reads the table after a failed selection. *)
let after_catalog_selection read =
  match
    let (_ : string option) = configure_agent_core_model_catalog_env () in
    read ()
  with
  | result -> result
  | exception Env_config_core.Config_error detail -> Error detail

let init_standalone ~gate ~config_path =
  after_catalog_selection (fun () ->
    match gate with
    | Routing_only -> Runtime.init_default ~config_path
    | Catalog_required -> Runtime.init_default_strict ~config_path)

let load_standalone_config_observation ~runtime_config_path =
  after_catalog_selection (fun () ->
    Runtime.load_config_observation ~runtime_config_path ())

let load_standalone_list ~config_path =
  after_catalog_selection (fun () ->
    Runtime.load_list ~config_path
    |> Result.map_error (Runtime_config_error.to_diagnostic_text ~config_path))
