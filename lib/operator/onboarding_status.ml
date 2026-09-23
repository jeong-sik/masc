type action = Choose_workspace | Initialize_workspace | Configure_models
  | Configure_sandbox | Start_imp | Inspect_configuration

type condition = Satisfied | Needs_setup | Needs_verification | Invalid

type check_id =
  | Workspace
  | Runtime_configuration
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
  | Runtime_configuration -> "runtime_configuration"
  | Model_connection -> "model_connection"
  | Keeper_declaration -> "keeper_declaration"
  | Sandbox -> "sandbox"
  | Keeper_persistence -> "keeper_persistence"
  | Browser_lane -> "browser_lane"

(* Existing history opens on what every Keeper in the workspace shares: the
   workspace, a runtime.toml the server can load, and Keeper metadata its boot
   admits. The server boots on a runtime.toml it cannot load or cannot find,
   but in setup-required mode with no runtime (the embedded file is written
   only when [.masc/config] is first created), so no Keeper can take a turn
   and the journey's model step is the repair. imp's model binding, declaration and
   sandbox concern the Keeper the journey creates: the server skips an imp it
   cannot load and boots every other Keeper, so a workspace whose history
   belongs to other Keepers opens and reports them beside it. A browser lane
   is a separate surface; its drift is reported the same way. *)
let role = function
  | Workspace | Runtime_configuration | Keeper_persistence -> Required_to_open
  | Model_connection | Keeper_declaration | Sandbox | Browser_lane -> Advisory

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
    [check Runtime_configuration Needs_setup "Choose a model connection."
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
    [check Runtime_configuration Invalid
       (Runtime.to_operator_text ~config_path failure)
       [Inspect_configuration; Configure_models]]
  | Ok (runtimes, default, assignments, _, lanes) ->
    let loaded = check Runtime_configuration Satisfied "runtime.toml loads." [Configure_models] in
    let selected = Runtime_verification.initial_runtime_id
      ~default_runtime_id:default.id ~assignments ~lanes ~keeper_name:"imp" in
    let runtime = Option.bind selected (fun id ->
      List.find_opt (fun (runtime : Runtime.t) -> String.equal runtime.id id) runtimes) in
    match runtime with
    | None ->
      (* A loaded list has validated every assignment, lane candidate and the
         default against its runtimes, so imp always resolves here. Reaching
         this means the list and its validation disagree, which is a runtime.toml
         fault the server shares, not a fact about imp. *)
      selected, None,
      [check Runtime_configuration Invalid
         "runtime.toml loaded, but imp's runtime does not resolve against it."
         [Inspect_configuration; Configure_models]]
    | Some runtime when not runtime.model.tools_support -> selected, Some runtime.model.api_name,
      [loaded; check Model_connection Needs_setup "The selected model has tool calling disabled."
         [Configure_models]]
    | Some runtime -> selected, Some runtime.model.api_name,
      [loaded; check Model_connection Needs_verification
         "A model is configured. Check its current sign-in, response and tool access."
         [Configure_models; Start_imp]]

(* The workspace's Keeper history is readable exactly when the server's boot
   reconcile admits it: every metadata file passes the same
   [validate_current_meta_file_result] (Keeper_store_boot_reconcile), and one
   that does not refuses the whole boot unless the operator accepts the
   quarantine. Judging it any other way opens a TUI on a server that will not
   start. imp is only the Keeper the setup journey creates; a workspace whose
   Keepers were declared by hand never has it, and judging history by imp alone
   sent that workspace back into setup on every bare `masc`. *)
let persistence_check base_path =
  let root = Workspace_utils.masc_root_dir_from ~base_path
    ~cluster_name:(Env_config_core.cluster_name ()) in
  let dir = Filename.concat root Common.keepers_runtime_dirname in
  let listed = if directory_exists dir then Safe_ops.list_dir_safe dir else Ok [] in
  match listed with
  | Error detail -> check Keeper_persistence Invalid
      (detail ^ ". Inspect configuration before proceeding.") [Inspect_configuration]
  | Ok entries ->
    let names =
      entries
      |> List.filter_map Keeper_runtime_root_entry.metadata_keeper_name
      |> List.filter Keeper_config.validate_name
      |> List.sort String.compare in
    let refused = List.filter (fun name ->
        Result.is_error (Keeper_meta_store.validate_current_meta_file_result
          (Filename.concat dir (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name
             Keeper_runtime_root_entry.Metadata)))) names in
    match names, refused with
    | [], _ -> check Keeper_persistence Needs_setup
        "No Keeper has persisted history yet. Prepare imp before opening its conversation." [Start_imp]
    | _ :: _, _ :: _ -> check Keeper_persistence Invalid
        ("Keeper metadata this build cannot read: " ^ String.concat ", " refused
         ^ ". The server refuses to boot until it is repaired or started with --accept-store-quarantine.")
        [Inspect_configuration]
    | _ :: _, [] -> check Keeper_persistence Satisfied
        ("Persisted Keeper history: " ^ String.concat ", " names
         ^ ". This does not verify that any of them is running or that its model and sandbox are ready.")
        []

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

(* The browser tools read the same observation when no browser answers, so an
   operator and a Keeper are told the same cause. *)
let browser_lane_check base_path =
  let observation =
    Browser_lane_launcher.observe ~base_path ~server:(Browser_lane_launcher.current_server ()) in
  let message = Browser_lane_launcher.message observation in
  match Browser_lane_launcher.verdict observation with
  | Browser_lane_launcher.Absent -> []
  | Browser_lane_launcher.Connected | Browser_lane_launcher.Aligned ->
    [check Browser_lane Satisfied message [Inspect_configuration]]
  | Browser_lane_launcher.Unverified ->
    [check Browser_lane Needs_verification message [Inspect_configuration]]
  | Browser_lane_launcher.Misconfigured -> [check Browser_lane Invalid message [Inspect_configuration]]

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
    if satisfied Workspace && satisfied Runtime_configuration && satisfied Keeper_persistence
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
