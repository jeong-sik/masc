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

(* Existing history opens on a readable workspace, model binding, declaration
   and persisted record. A browser lane is a separate surface; a launcher aimed
   at an old port says nothing about whether a conversation can be read, so its
   drift is reported beside it instead of sending the operator back to "choose
   a workspace". *)
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

type persisted_record = Readable of string | Unreadable of string

(* A metadata file counts as history only when it decodes strictly and names
   the Keeper its file is named for. [None] is a file that vanished between the
   listing and the read. *)
let persisted_record ~base_path dir entry =
  match Keeper_runtime_root_entry.metadata_keeper_name entry with
  | Some name when Keeper_config.validate_name name ->
    (match Keeper_meta_store.read_meta_file_path_read_only ~ownership_root:base_path
             (Filename.concat dir entry) with
     | Ok None -> None
     | Ok (Some meta) when String.equal meta.name name -> Some (Readable name)
     | Ok (Some _) | Error _ -> Some (Unreadable name))
  | Some _ | None -> None

(* The front door opens a workspace that already holds Keeper history, whoever
   those Keepers are. imp is the Keeper the setup journey creates; a workspace
   whose Keepers were declared by hand persists other names and never imp, so
   judging history by imp alone sent it back into setup on every bare `masc`. *)
let persistence_check base_path =
  let root = Workspace_utils.masc_root_dir_from ~base_path
    ~cluster_name:(Env_config_core.cluster_name ()) in
  let dir = Filename.concat root Common.keepers_runtime_dirname in
  let listed =
    if not (directory_exists dir) then Ok []
    else match Sys.readdir dir with
      | entries -> Ok (List.sort String.compare (Array.to_list entries))
      | exception Sys_error detail -> Error detail
  in
  match listed with
  | Error detail -> check Keeper_persistence Invalid
      ("Keeper history cannot be listed: " ^ detail ^ ". Inspect configuration before proceeding.")
      [Inspect_configuration]
  | Ok entries ->
    let records = List.filter_map (persisted_record ~base_path dir) entries in
    let readable = List.filter_map (function Readable n -> Some n | Unreadable _ -> None) records in
    let unreadable = List.filter_map (function Unreadable n -> Some n | Readable _ -> None) records in
    let names = String.concat ", " in
    match readable, unreadable with
    | [], [] -> check Keeper_persistence Needs_setup
        "No Keeper has persisted history yet. Prepare imp before opening its conversation." [Start_imp]
    | [], _ :: _ -> check Keeper_persistence Invalid
        ("No Keeper history can be read as current metadata (" ^ names unreadable
         ^ "). Inspect configuration before proceeding.")
        [Inspect_configuration]
    | _ :: _, [] -> check Keeper_persistence Satisfied
        ("Persisted Keeper history: " ^ names readable
         ^ ". This does not verify that any of them is running or that its model and sandbox are ready.")
        []
    | _ :: _, _ :: _ -> check Keeper_persistence Satisfied
        ("Persisted Keeper history: " ^ names readable
         ^ ". Metadata that cannot be read as current, left unopened: " ^ names unreadable
         ^ ". This does not verify that any Keeper is running or that its model and sandbox are ready.")
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
