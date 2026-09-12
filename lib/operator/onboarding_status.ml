type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check =
  { id : string
  ; condition : condition
  ; message : string
  ; actions : action list
  }

type t =
  { base_path : string option
  ; checks : check list
  ; selected_runtime : string option
  ; selected_model : string option
  }

let action_name = function
  | Choose_workspace -> "choose_workspace"
  | Initialize_workspace -> "initialize_workspace"
  | Configure_models -> "configure_models"
  | Configure_sandbox -> "configure_sandbox"
  | Start_imp -> "start_imp"
  | Inspect_configuration -> "inspect_configuration"

let condition_name = function
  | Satisfied -> "satisfied"
  | Needs_setup -> "needs_setup"
  | Needs_verification -> "needs_verification"
  | Invalid -> "invalid"

let check id condition message actions = { id; condition; message; actions }

let directory_exists path =
  try Sys.is_directory path with Sys_error _ -> false

let model_checks config_path =
  if not (Sys.file_exists config_path) then
    None, None,
    [check "model_connection" Needs_setup "Choose a model connection for imp."
       [Configure_models]]
  else match Runtime.load_list ~config_path with
  | Error failure ->
    (* The reason reaches the operator now; the condition does not move yet.
       Saving a selection does repair some of these — a stale imp assignment is
       rewritten by runtime-default-set over the staged copy, measured — but the
       branch alone does not say which: a reference failure covers both an
       assignment the rewrite fixes and a lane reference it does not. Splitting
       Invalid from Needs_setup needs that measured per situation, not inferred
       from the constructor. *)
    None, None,
    [check "model_connection" Invalid
       (Runtime.to_operator_text ~config_path failure)
       [Inspect_configuration; Configure_models]]
  | Ok (runtimes, default, assignments, _, lanes) ->
    let selected = Runtime_verification.initial_runtime_id
      ~default_runtime_id:default.id ~assignments ~lanes ~keeper_name:"imp" in
    let runtime = Option.bind selected (fun id ->
      List.find_opt (fun (runtime : Runtime.t) -> String.equal runtime.id id) runtimes) in
    match runtime with
    | None -> selected, None,
      [check "model_connection" Invalid "imp's assigned runtime cannot be resolved."
         [Inspect_configuration; Configure_models]]
    | Some runtime when not runtime.model.tools_support -> selected, Some runtime.model.api_name,
      [check "model_connection" Needs_setup "The selected model has tool calling disabled."
         [Configure_models]]
    | Some runtime -> selected, Some runtime.model.api_name,
      [check "model_connection" Needs_verification
         "A model is configured. Check its current sign-in, response and tool access."
         [Configure_models; Start_imp]]

let persistence_check base_path =
  let root = Workspace_utils.masc_root_dir_from ~base_path
    ~cluster_name:(Env_config_core.cluster_name ()) in
  let path = Filename.concat (Filename.concat root Common.keepers_runtime_dirname)
    (Keeper_runtime_root_entry.keeper_basename ~keeper_name:"imp" Keeper_runtime_root_entry.Metadata) in
  match Keeper_meta_store.read_meta_file_path_read_only ~ownership_root:base_path path with
  | Ok None -> check "keeper_persistence" Needs_setup
      "imp has no persisted history yet. Prepare imp before opening its conversation." [Start_imp]
  | Ok (Some meta) when String.equal meta.name "imp" ->
    check "keeper_persistence" Satisfied
      "imp has persisted history. This does not verify that it is running or that its model and sandbox are ready." [Start_imp]
  | Ok (Some _) | Error _ -> check "keeper_persistence" Invalid
      "imp's persisted history cannot be read as its current metadata. Inspect configuration before proceeding."
      [Inspect_configuration]

let keeper_checks base_path =
  let path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:"imp" in
  if not (Sys.file_exists path) then
    [check "keeper_declaration" Needs_setup "Your first Keeper, imp, has not been created."
       [Initialize_workspace];
     check "sandbox" Needs_setup "Choose imp's isolated workspace." [Configure_sandbox]]
  else match Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
               ~base_path "imp" with
  | Error _ ->
    [check "keeper_declaration" Invalid "imp's declaration needs configuration repair."
       [Inspect_configuration];
     check "sandbox" Needs_setup "Resolve imp's declaration before preparing its sandbox."
       [Inspect_configuration; Configure_sandbox]]
  | Ok _ ->
    [check "keeper_declaration" Satisfied "imp is declared. Its running state is observed separately."
       [Start_imp];
     check "sandbox" Needs_verification
       "Check the selected sandbox service and prepare imp's isolated workspace."
       [Configure_sandbox; Start_imp]]

let inspect ~base_path =
  match base_path with
  | None ->
    { base_path = None; selected_runtime = None; selected_model = None;
      checks = [check "workspace" Needs_setup
        "Welcome. Choose a workspace for you and imp." [Choose_workspace]] }
  | Some raw ->
    let base_path = Env_config.normalize_masc_base_path_input raw in
    let root = Filename.concat base_path Common.masc_dirname in
    if not (directory_exists root) then
      { base_path = Some base_path; selected_runtime = None; selected_model = None;
        checks = [check "workspace" Needs_setup
          "This location does not contain an initialized MASC workspace."
          [Initialize_workspace; Choose_workspace]] }
    else
      let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
      let selected_runtime, selected_model, models = model_checks config_path in
      { base_path = Some base_path; selected_runtime; selected_model;
        checks = check "workspace" Satisfied "Workspace found." [Choose_workspace]
          :: (models @ keeper_checks base_path @ [persistence_check base_path]) }

let optional_string = function None -> `Null | Some value -> `String value

let to_json t =
  `Assoc ["schema", `String "masc.onboarding_status.v1";
    "scope", `String "configuration_observation";
    "base_path", optional_string t.base_path;
    "selected_runtime", optional_string t.selected_runtime;
    "selected_model", optional_string t.selected_model;
    "checks", `List (List.map (fun c -> `Assoc [
      "id", `String c.id; "condition", `String (condition_name c.condition);
      "message", `String c.message;
      "actions", `List (List.map (fun a -> `String (action_name a)) c.actions)]) t.checks)]

let to_text t =
  String.concat "\n"
    ("MASC — you and imp" :: List.map (fun c ->
       Printf.sprintf "[%s] %s: %s" (condition_name c.condition) c.id c.message) t.checks)
