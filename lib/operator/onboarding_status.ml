type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check_id =
  | Workspace
  | Model_connection
  | Keeper_declaration
  | Sandbox
  | Keeper_persistence
  | Browser_lane

type role = Required_to_open | Advisory

type opening = Open_existing_history | Needs_journey

type check =
  { id : check_id
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

let check_id_name = function
  | Workspace -> "workspace"
  | Model_connection -> "model_connection"
  | Keeper_declaration -> "keeper_declaration"
  | Sandbox -> "sandbox"
  | Keeper_persistence -> "keeper_persistence"
  | Browser_lane -> "browser_lane"

(* imp's history opens on what imp itself needs: a readable workspace, model
   binding, declaration and persisted record. A browser lane is a separate
   surface; a launcher aimed at an old port says nothing about whether imp's
   conversation can be read, so its drift is reported beside the conversation
   instead of sending the operator back to "choose a workspace". *)
let role = function
  | Workspace | Model_connection | Keeper_declaration | Sandbox | Keeper_persistence ->
    Required_to_open
  | Browser_lane -> Advisory

let role_name = function
  | Required_to_open -> "required_to_open"
  | Advisory -> "advisory"

let opening_name = function
  | Open_existing_history -> "open_existing_history"
  | Needs_journey -> "needs_journey"

let check id condition message actions = { id; condition; message; actions }

let directory_exists path =
  try Sys.is_directory path with Sys_error _ -> false

let model_checks config_path =
  if not (Sys.file_exists config_path) then
    None, None,
    [check Model_connection Needs_setup "Choose a model connection for imp."
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
    [check Model_connection Invalid
       (Runtime.to_operator_text ~config_path failure)
       [Inspect_configuration; Configure_models]]
  | Ok (runtimes, default, assignments, _, lanes) ->
    let selected = Runtime_verification.initial_runtime_id
      ~default_runtime_id:default.id ~assignments ~lanes ~keeper_name:"imp" in
    let runtime = Option.bind selected (fun id ->
      List.find_opt (fun (runtime : Runtime.t) -> String.equal runtime.id id) runtimes) in
    match runtime with
    | None -> selected, None,
      [check Model_connection Invalid "imp's assigned runtime cannot be resolved."
         [Inspect_configuration; Configure_models]]
    | Some runtime when not runtime.model.tools_support -> selected, Some runtime.model.api_name,
      [check Model_connection Needs_setup "The selected model has tool calling disabled."
         [Configure_models]]
    | Some runtime -> selected, Some runtime.model.api_name,
      [check Model_connection Needs_verification
         "A model is configured. Check its current sign-in, response and tool access."
         [Configure_models; Start_imp]]

let persistence_check base_path =
  let root = Workspace_utils.masc_root_dir_from ~base_path
    ~cluster_name:(Env_config_core.cluster_name ()) in
  let path = Filename.concat (Filename.concat root Common.keepers_runtime_dirname)
    (Keeper_runtime_root_entry.keeper_basename ~keeper_name:"imp" Keeper_runtime_root_entry.Metadata) in
  match Keeper_meta_store.read_meta_file_path_read_only ~ownership_root:base_path path with
  | Ok None -> check Keeper_persistence Needs_setup
      "imp has no persisted history yet. Prepare imp before opening its conversation." [Start_imp]
  | Ok (Some meta) when String.equal meta.name "imp" ->
    check Keeper_persistence Satisfied
      "imp has persisted history. This does not verify that it is running or that its model and sandbox are ready." [Start_imp]
  | Ok (Some _) | Error _ -> check Keeper_persistence Invalid
      "imp's persisted history cannot be read as its current metadata. Inspect configuration before proceeding."
      [Inspect_configuration]

let keeper_checks base_path =
  let path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:"imp" in
  if not (Sys.file_exists path) then
    [check Keeper_declaration Needs_setup "Your first Keeper, imp, has not been created."
       [Initialize_workspace];
     check Sandbox Needs_setup "Choose imp's isolated workspace." [Configure_sandbox]]
  else match Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
               ~base_path "imp" with
  | Error _ ->
    [check Keeper_declaration Invalid "imp's declaration needs configuration repair."
       [Inspect_configuration];
     check Sandbox Needs_setup "Resolve imp's declaration before preparing its sandbox."
       [Inspect_configuration; Configure_sandbox]]
  | Ok _ ->
    [check Keeper_declaration Satisfied "imp is declared. Its running state is observed separately."
       [Start_imp];
     check Sandbox Needs_verification
       "Check the selected sandbox service and prepare imp's isolated workspace."
       [Configure_sandbox; Start_imp]]

(* install-host.sh writes the launcher as one exec line of shell-quoted words,
   so the check scans whole words, never substrings. A launcher without
   --server resolves the workspace connection port at run time; that is the
   state that cannot drift from the configuration the server itself follows. *)
type launcher_server = No_server_argument | Server_port of int | Unusable_origin

let launcher_server text =
  let rec scan = function
    | "--server" :: origin :: _ ->
        let uri = Uri.of_string origin in
        if Uri.scheme uri = Some "http" then
          match Uri.port uri with
          | Some port when port > 0 && port <= 65535 -> Server_port port
          | Some _ -> Unusable_origin
          | None -> Server_port 80
        else Unusable_origin
    | _ :: rest -> scan rest
    | [] -> No_server_argument
  in
  scan (List.filter (fun word -> word <> "") (String.split_on_char ' ' text))

let browser_lane_check base_path =
  let launcher =
    Filename.concat
      (Filename.concat (Filename.concat base_path Common.masc_dirname) "browser-lane")
      "host/launch"
  in
  let installed = try Sys.file_exists launcher with Sys_error _ -> false in
  if not installed then []
  else
    let text =
      try Ok (In_channel.with_open_bin launcher In_channel.input_all)
      with Sys_error _ -> Error "The browser lane launcher cannot be read."
    in
    let workspace_port =
      match Workspace_connection.read ~base_path with
      | Error error -> Error (Workspace_connection.error_message error)
      | Ok None -> Ok Masc_network_defaults.masc_http_default_port
      | Ok (Some port) -> Ok (Workspace_connection.to_int port)
    in
    let observation =
      match (text, workspace_port) with
      | Error detail, _ | _, Error detail ->
          check Browser_lane Invalid detail [Inspect_configuration]
      | Ok content, Ok expected ->
          (match launcher_server content with
           | Unusable_origin ->
               check Browser_lane Invalid
                 "The browser lane launcher's --server is not an http origin with a usable port."
                 [Inspect_configuration]
           | No_server_argument ->
               check Browser_lane Satisfied
                 (String.concat " "
                    [ "The browser lane launcher resolves the workspace connection port at";
                      "run time. An exported MASC_HTTP_PORT still takes precedence over the" ;
                      "file, which this observation cannot see." ])
                 [Inspect_configuration]
           | Server_port port when port = expected ->
               check Browser_lane Satisfied
                 (Printf.sprintf
                    "The browser lane launcher targets the workspace connection port %d." expected)
                 [Inspect_configuration]
           | Server_port port ->
               check Browser_lane Invalid
                 (Printf.sprintf
                    "The browser lane launcher targets port %d while the workspace connection \
                     port is %d. Re-run connectors/browser/install-host.sh without --server so \
                     the lane follows the workspace."
                    port expected)
                 [Inspect_configuration])
    in
    [observation]

let inspect ~base_path =
  match base_path with
  | None ->
    { base_path = None; selected_runtime = None; selected_model = None;
      checks = [check Workspace Needs_setup
        "Welcome. Choose a workspace for you and imp." [Choose_workspace]] }
  | Some raw ->
    let base_path = Env_config.normalize_masc_base_path_input raw in
    let root = Filename.concat base_path Common.masc_dirname in
    if not (directory_exists root) then
      { base_path = Some base_path; selected_runtime = None; selected_model = None;
        checks = [check Workspace Needs_setup
          "This location does not contain an initialized MASC workspace."
          [Initialize_workspace; Choose_workspace]] }
    else
      let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
      let selected_runtime, selected_model, models = model_checks config_path in
      { base_path = Some base_path; selected_runtime; selected_model;
        checks = check Workspace Satisfied "Workspace found." [Choose_workspace]
          :: (models @ keeper_checks base_path @ [persistence_check base_path]
              @ browser_lane_check base_path) }

let optional_string = function None -> `Null | Some value -> `String value

(* Opening existing history is decided here, once, from typed checks. The
   setup journey reads this answer instead of re-deriving it from the wire
   condition strings, which cannot tell a surface imp needs from one it does not. *)
let opening t =
  let satisfied id =
    List.exists (fun c -> c.id = id && c.condition = Satisfied) t.checks
  in
  let holds_closed c =
    match role c.id, c.condition with
    | Required_to_open, Invalid -> true
    | Required_to_open, (Satisfied | Needs_setup | Needs_verification)
    | Advisory, (Satisfied | Needs_setup | Needs_verification | Invalid) -> false
  in
  match t.base_path with
  | None -> Needs_journey
  | Some _ ->
    if satisfied Workspace && satisfied Keeper_persistence
       && not (List.exists holds_closed t.checks)
    then Open_existing_history
    else Needs_journey

let to_json t =
  `Assoc ["schema", `String "masc.onboarding_status.v1";
    "scope", `String "configuration_observation";
    "base_path", optional_string t.base_path;
    "selected_runtime", optional_string t.selected_runtime;
    "selected_model", optional_string t.selected_model;
    "opening", `String (opening_name (opening t));
    "checks", `List (List.map (fun c -> `Assoc [
      "id", `String (check_id_name c.id); "role", `String (role_name (role c.id));
      "condition", `String (condition_name c.condition);
      "message", `String c.message;
      "actions", `List (List.map (fun a -> `String (action_name a)) c.actions)]) t.checks)]

let to_text t =
  String.concat "\n"
    ("MASC — you and imp" :: List.map (fun c ->
       Printf.sprintf "[%s] %s: %s" (condition_name c.condition) (check_id_name c.id) c.message) t.checks)
