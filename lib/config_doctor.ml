type init_state =
  | Initialized
  | Missing_init
  | Invalid_env
  | Shadowed

type status =
  | Ok
  | Warn
  | Error

type inputs = {
  cwd : string;
  executable_name : string;
  base_path_input : string;
  env_masc_base_path : string option;
  env_config_dir : string option;
  env_personas_dir : string option;
  resolution_source : string option;
  repo_config_fallback_enabled : bool;
}

type t = {
  status : status;
  init_state : init_state;
  base_path : string;
  active_config_root : string;
  active_personas_root : string;
  runtime_data_root : string;
  config_root_source : string;
  local_base_config_root : string;
  local_base_config_initialized : bool;
  explicit_config_dir : string option;
  explicit_personas_dir : string option;
  repo_config_seed_path : string option;
  repo_fallback_enabled : bool;
  keeper_runtime_toml_present : bool;
  warnings : string list;
  next_actions : string list;
  persona_tool_preset_conflicts : persona_tool_preset_conflict list;
  catalog_validation : Yojson.Safe.t option;
  sandbox_preflight : Yojson.Safe.t option;
}

and persona_tool_preset_conflict = {
  keeper_name : string;
  persona_name : string;
  toml_path : string;
  persona_path : string;
  toml_tool_preset : string;
  persona_tool_preset : string;
}

type catalog_issue_severity = Cascade_catalog_validator.severity =
  | Catalog_warn
  | Catalog_error

type catalog_issue = Cascade_catalog_validator.issue = {
  profile : string option;
  severity : catalog_issue_severity;
  message : string;
}

let trim_opt = Env_config_core.trim_opt

let init_state_to_string = function
  | Initialized -> "initialized"
  | Missing_init -> "missing_init"
  | Invalid_env -> "invalid_env"
  | Shadowed -> "shadowed"

let status_to_string = function
  | Ok -> "ok"
  | Warn -> "warn"
  | Error -> "error"

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let canonicalize_path ~cwd path =
  let absolute =
    if Filename.is_relative path then Filename.concat cwd path else path
  in
  try Unix.realpath absolute with
  | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> absolute

let local_base_config_root ~base_path =
  Filename.concat
    (Coord_utils.masc_dir_from_base_path ~base_path)
    "config"

let runtime_data_root ~base_path =
  Coord_utils.masc_dir_from_base_path ~base_path

let repo_config_seed_path (inputs : inputs) =
  [
    Config_dir_resolver.path_from_executable
      ~cwd:inputs.cwd inputs.executable_name;
    Config_dir_resolver.path_from_cwd inputs.cwd;
  ]
  |> List.filter_map (fun path_opt ->
         Option.map (canonicalize_path ~cwd:inputs.cwd) path_opt)
  |> dedupe_keep_order
  |> function
  | first :: _ -> Some first
  | [] -> None

let option_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let diagnose_cascade_catalog ~active_config_root =
  let config_path =
    Filename.concat active_config_root Config_dir_resolver.cascade_json_filename
  in
  if not (Env_config_core.existing_file config_path) then
    []
  else
    let profiles = Cascade_catalog_validator.discover_profiles ~config_path in
    let issues = Cascade_catalog_validator.diagnose_catalog ~config_path in
    if issues = [] then
      []
    else
      let error_count =
        issues
        |> List.filter (fun issue -> issue.severity = Catalog_error)
        |> List.length
      in
      let warn_count = List.length issues - error_count in
      {
        profile = None;
        severity = if error_count > 0 then Catalog_error else Catalog_warn;
        message =
          Printf.sprintf
            "Cascade catalog check scanned %d preset(s): %d error, %d \
             warn."
            (List.length profiles)
            error_count
            warn_count;
      }
      :: issues

let cascade_catalog_next_actions ~config_path issues =
  if issues = [] then
    []
  else
    let has_errors =
      List.exists (fun issue -> issue.severity = Catalog_error) issues
    in
    let primary_action =
      if has_errors then
        Printf.sprintf
          "Fix or disable the broken cascade preset entries in %s before \
           assigning keepers to them."
          config_path
      else
        Printf.sprintf
          "Clean up the degraded cascade preset metadata in %s so doctor \
           and runtime see the same routing intent."
          config_path
    in
    [
      primary_action;
      "Rerun `masc-mcp doctor config` after editing cascade.json.";
    ]

let normalize_tool_preset_opt raw =
  match raw with
  | None -> None
  | Some value ->
      let normalized = String.trim (String.lowercase_ascii value) in
      if normalized = "" then
        None
      else
        Some normalized

let non_empty_trimmed_opt raw =
  match raw with
  | None -> None
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then
        None
      else
        Some trimmed

let persona_tool_preset_conflict_to_warning conflict =
  Printf.sprintf
    "Keeper %s TOML tool_preset %S overrides persona %s tool_preset %S (toml=%s persona=%s)."
    conflict.keeper_name
    conflict.toml_tool_preset
    conflict.persona_name
    conflict.persona_tool_preset
    conflict.toml_path
    conflict.persona_path

let persona_tool_preset_conflict_to_action conflict =
  Printf.sprintf
    "Remove tool_preset from %s unless the override is intentional; TOML wins until fixed."
    conflict.toml_path

let persona_tool_preset_conflict_to_yojson conflict =
  `Assoc
    [
      ("keeper_name", `String conflict.keeper_name);
      ("persona_name", `String conflict.persona_name);
      ("toml_path", `String conflict.toml_path);
      ("persona_path", `String conflict.persona_path);
      ("toml_tool_preset", `String conflict.toml_tool_preset);
      ("persona_tool_preset", `String conflict.persona_tool_preset);
    ]

let discover_persona_tool_preset_conflicts ~active_config_root
    ~active_personas_root =
  let keepers_dir = Filename.concat active_config_root "keepers" in
  if not (Env_config_core.existing_dir keepers_dir) then
    []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".toml")
    |> List.filter_map (fun filename ->
           let toml_path = Filename.concat keepers_dir filename in
           match Safe_ops.read_file_safe toml_path with
           | Error _ -> None
           | Ok content -> (
               match Keeper_toml_loader.parse_toml content with
               | Error _ -> None
               | Ok doc ->
                   let keeper_name =
                     Keeper_toml_loader.toml_string_opt doc "keeper.name"
                     |> non_empty_trimmed_opt
                     |> Option.value
                          ~default:(Filename.chop_suffix filename ".toml")
                   in
                   let persona_name =
                     Keeper_toml_loader.toml_string_opt doc
                       "keeper.persona_name"
                     |> non_empty_trimmed_opt
                     |> Option.value ~default:keeper_name
                   in
                   let toml_tool_preset =
                     Keeper_toml_loader.toml_string_opt doc
                       "keeper.tool_preset"
                     |> normalize_tool_preset_opt
                   in
                   match toml_tool_preset with
                   | None -> None
                   | Some toml_tool_preset ->
                       let persona_path =
                         Filename.concat
                           (Filename.concat active_personas_root persona_name)
                           "profile.json"
                       in
                       if not (Env_config_core.existing_file persona_path) then
                         None
                       else
                         match Safe_ops.read_json_file_logged
                                 ~label:"config_doctor_persona" persona_path
                         with
                         | None -> None
                         | Some json ->
                             let persona_tool_preset =
                               json
                               |> Yojson.Safe.Util.member "keeper"
                               |> Safe_ops.json_string_opt "tool_preset"
                               |> normalize_tool_preset_opt
                             in
                             match persona_tool_preset with
                             | Some persona_tool_preset
                               when persona_tool_preset <> toml_tool_preset ->
                                 Some
                                   {
                                     keeper_name;
                                     persona_name;
                                     toml_path;
                                     persona_path;
                                     toml_tool_preset;
                                     persona_tool_preset;
                                   }
                             | _ -> None))

let current_inputs ~base_path_input ~default_base_path () =
  let normalized_base_path =
    Env_config_core.normalize_masc_base_path_input base_path_input
  in
  let resolution_source =
    match trim_opt (Sys.getenv_opt "MASC_BASE_PATH_RESOLUTION_SOURCE") with
    | Some source -> Some source
    | None ->
        let inherited_env_matches =
          match Sys.getenv_opt Env_config_core.base_path_env_key with
          | Some existing ->
              String.equal
                (Env_config_core.normalize_masc_base_path_input existing)
                normalized_base_path
          | None -> false
        in
        let default_source =
          let normalized_default =
            Env_config_core.normalize_masc_base_path_input default_base_path
          in
          if inherited_env_matches then
            "explicit_env"
          else if String.equal normalized_default normalized_base_path then
            (match Env_config_core.home_dir_opt () with
             | Some home ->
                 let normalized_home =
                   Env_config_core.normalize_masc_base_path_input home
                 in
                 if String.equal normalized_home normalized_default then
                   "implicit_home"
                 else
                   "implicit_repo_root"
             | None -> "implicit_repo_root")
          else
            "explicit_cli"
        in
        Some default_source
  in
  {
    cwd = Sys.getcwd ();
    executable_name = Sys.executable_name;
    base_path_input;
    env_masc_base_path = Env_config_core.base_path_raw_opt ();
    env_config_dir = Config_dir_resolver.current_env_config_dir_opt ();
    env_personas_dir = Config_dir_resolver.current_env_personas_dir_opt ();
    resolution_source;
    repo_config_fallback_enabled = Config_dir_resolver.repo_config_fallback_enabled ();
  }

let analyze_with (inputs : inputs) =
  let base_path =
    inputs.base_path_input
    |> Env_config_core.normalize_masc_base_path_input
    |> canonicalize_path ~cwd:inputs.cwd
  in
  let runtime_data_root = runtime_data_root ~base_path in
  let local_base_config_root =
    local_base_config_root ~base_path |> canonicalize_path ~cwd:inputs.cwd
  in
  let explicit_config_dir =
    inputs.env_config_dir |> Option.map (canonicalize_path ~cwd:inputs.cwd)
  in
  let explicit_personas_dir =
    inputs.env_personas_dir |> Option.map (canonicalize_path ~cwd:inputs.cwd)
  in
  let active_config_root =
    Option.value ~default:local_base_config_root explicit_config_dir
  in
  let active_personas_root =
    match explicit_personas_dir with
    | Some path -> path
    | None -> Filename.concat active_config_root "personas"
  in
  let explicit_config_invalid =
    match explicit_config_dir with
    | Some path -> not (Env_config_core.existing_dir path)
    | None -> false
  in
  let explicit_personas_invalid =
    match explicit_personas_dir with
    | Some path -> not (Env_config_core.existing_dir path)
    | None -> false
  in
  let active_config_initialized =
    Config_dir_resolver.config_signature_exists active_config_root
  in
  let local_base_config_initialized =
    Config_dir_resolver.config_signature_exists local_base_config_root
  in
  let shadowed =
    match explicit_config_dir with
    | Some path ->
        path <> local_base_config_root && local_base_config_initialized
    | None -> false
  in
  let init_state =
    if explicit_config_invalid || explicit_personas_invalid then
      Invalid_env
    else if not active_config_initialized then
      Missing_init
    else if shadowed then
      Shadowed
    else
      Initialized
  in
  let config_root_source =
    match explicit_config_dir with
    | Some _ -> "env"
    | None -> "local_masc"
  in
  let repo_config_seed_path = repo_config_seed_path inputs in
  let keeper_runtime_toml_present =
    Env_config_core.existing_file
      (Filename.concat
         active_config_root
         Config_dir_resolver.keeper_runtime_toml_filename)
  in
  let path_diag =
    Server_base_path_diagnostics.detect
      ~cwd:inputs.cwd
      ~input_base_path:inputs.base_path_input
      ?env_masc_base_path:inputs.env_masc_base_path
      ?resolution_source:inputs.resolution_source
      ~effective_base_path:base_path
      ~effective_masc_root:runtime_data_root
      ()
  in
  let cascade_catalog_issues =
    diagnose_cascade_catalog ~active_config_root
  in
  let persona_tool_preset_conflicts =
    discover_persona_tool_preset_conflicts
      ~active_config_root
      ~active_personas_root
  in
  let cascade_config_path =
    Filename.concat active_config_root Config_dir_resolver.cascade_json_filename
  in
  let warnings =
    [
      (if explicit_config_invalid then
         Some
           (Printf.sprintf
              "MASC_CONFIG_DIR is set but does not point to a directory: %s"
              active_config_root)
       else
         None);
      (if explicit_personas_invalid then
         Some
           (Printf.sprintf
              "MASC_PERSONAS_DIR is set but does not point to a directory: %s"
              active_personas_root)
       else
         None);
      (if not active_config_initialized then
         Some
           (Printf.sprintf
              "Active config root is not initialized: %s"
              active_config_root)
       else
         None);
      (if shadowed then
         Some
           (Printf.sprintf
              "Explicit MASC_CONFIG_DIR shadows the base-path config root: %s -> %s"
              local_base_config_root active_config_root)
       else
         None);
      (if not (Env_config_core.existing_dir active_personas_root) then
         Some
           (Printf.sprintf
              "Active personas root is missing: %s"
              active_personas_root)
       else
         None);
      (match repo_config_seed_path with
       | Some path when path <> active_config_root ->
           Some
             (Printf.sprintf
                "Repo config seed exists at %s; it is bootstrap-only, not the active config root."
                path)
       | _ -> None);
      (if inputs.repo_config_fallback_enabled then
         Some
           "MASC_ALLOW_REPO_CONFIG_FALLBACK=true is enabled; low-level resolver fallback remains available."
       else
         None);
      path_diag.warning;
    ]
    |> List.filter_map (fun warning -> warning)
    |> fun base_warnings ->
    base_warnings
    @ List.map persona_tool_preset_conflict_to_warning
        persona_tool_preset_conflicts
    @ List.map (fun issue -> issue.message) cascade_catalog_issues
    |> dedupe_keep_order
  in
  let cascade_actions =
    cascade_catalog_next_actions
      ~config_path:cascade_config_path
      cascade_catalog_issues
  in
  let next_actions =
    match init_state with
    | Invalid_env ->
        [
          (match explicit_config_dir with
           | Some path ->
               Some
                 (Printf.sprintf
                    "Fix or unset MASC_CONFIG_DIR. Current value is invalid: %s"
                    path)
           | None -> None);
          (match explicit_personas_dir with
           | Some path ->
               Some
                 (Printf.sprintf
                    "Fix or unset MASC_PERSONAS_DIR. Current value is invalid: %s"
                    path)
           | None -> None);
          Some
            (Printf.sprintf
               "For normal startup, keep the active config under %s or point MASC_CONFIG_DIR at a valid config root."
               local_base_config_root);
        ]
        |> List.filter_map (fun action -> action)
    | Missing_init ->
        [
          Some
            (Printf.sprintf
               "Initialize the active config root at %s before relying on this base path."
               active_config_root);
          (match explicit_config_dir with
           | Some _ ->
               Some
                 "If the explicit config root is not intentional, unset MASC_CONFIG_DIR and use the base-path local config instead."
           | None ->
               Some
                 "Supported launchers bootstrap <base-path>/.masc/config automatically; direct binary use should create the same tree.");
          (match repo_config_seed_path with
           | Some path ->
               Some
                 (Printf.sprintf
                    "Do not edit %s expecting live changes; copy or bootstrap it into the active config root."
                    path)
           | None -> None);
        ]
        |> List.filter_map (fun action -> action)
    | Shadowed ->
        [
          Printf.sprintf
            "Keep MASC_CONFIG_DIR=%s only if the shadowing is intentional."
            active_config_root;
          Printf.sprintf
            "Unset MASC_CONFIG_DIR to switch back to the base-path config root: %s"
            local_base_config_root;
        ]
    | Initialized ->
        [
          Printf.sprintf
            "Use %s as the active config root for edits and diagnostics."
            active_config_root;
          (match repo_config_seed_path with
           | Some path when path <> active_config_root ->
               Printf.sprintf
                 "Treat %s as a bootstrap seed only."
                 path
           | _ ->
               "No further action needed.");
        ]
    |> fun base_actions ->
    base_actions
    @ List.map persona_tool_preset_conflict_to_action
        persona_tool_preset_conflicts
    @ cascade_actions
    |> dedupe_keep_order
  in
  let has_catalog_errors =
    List.exists
      (fun issue -> issue.severity = Catalog_error)
      cascade_catalog_issues
  in
  let status =
    match init_state with
    | Invalid_env | Missing_init -> Error
    | Shadowed -> Warn
    | Initialized ->
        if has_catalog_errors then Error
        else if persona_tool_preset_conflicts <> [] then Warn
        else if warnings = [] then Ok else Warn
  in
  {
    status;
    init_state;
    base_path;
    active_config_root;
    active_personas_root;
    runtime_data_root;
    config_root_source;
    local_base_config_root;
    local_base_config_initialized;
    explicit_config_dir;
    explicit_personas_dir;
    repo_config_seed_path;
    repo_fallback_enabled = inputs.repo_config_fallback_enabled;
    keeper_runtime_toml_present;
    warnings;
    next_actions;
    persona_tool_preset_conflicts;
    catalog_validation = None;
    sandbox_preflight = None;
  }

let analyze ~base_path_input ~default_base_path () =
  current_inputs ~base_path_input ~default_base_path ()
  |> analyze_with

type live_catalog_outcome =
  | Live_catalog_valid
  | Live_catalog_partial
  | Live_catalog_serving_last_known_good
  | Live_catalog_invalid

let live_catalog_summary = function
  | Stdlib.Ok (Cascade_catalog_runtime.Validated snapshot) ->
      ( Live_catalog_valid,
        None,
        Cascade_catalog_runtime.state_to_yojson
          (Cascade_catalog_runtime.Validated snapshot) )
  | Stdlib.Ok
      (Cascade_catalog_runtime.Validated_with_rejections _ as state) ->
      ( Live_catalog_partial,
        Some
          "Live cascade catalog validation kept the usable profile subset and rejected some presets.",
        Cascade_catalog_runtime.state_to_yojson state )
  | Stdlib.Ok (Cascade_catalog_runtime.Serving_last_known_good _ as state) ->
      ( Live_catalog_serving_last_known_good,
        Some
          "Live cascade catalog validation rejected the current file; runtime is serving last-known-good.",
        Cascade_catalog_runtime.state_to_yojson state )
  | Stdlib.Error rejection ->
      ( Live_catalog_invalid,
        Some
          "Live cascade catalog validation failed; no validated snapshot is available.",
        `Assoc
          [
            ("status", `String "invalid");
            ("serving_last_known_good", `Bool false);
            ("snapshot", `Null);
            ( "rejected_update",
              Cascade_catalog_runtime.rejection_to_yojson rejection );
          ] )

let analyze_live ~sw ~net ~clock ~fs ~proc_mgr ~base_path_input
    ~default_base_path () =
  let report = analyze ~base_path_input ~default_base_path () in
  Process_eio.init ~cwd_default:Eio.Path.(fs / report.base_path) ~proc_mgr
    ~clock;
  let sandbox_preflight_report =
    Keeper_sandbox_runtime.docker_preflight ~timeout_sec:10.0 ()
  in
  let sandbox_preflight =
    sandbox_preflight_report
    |> Option.map Keeper_sandbox_runtime.docker_preflight_to_yojson
  in
  let sandbox_warning, sandbox_actions, sandbox_preflight_ok =
    match sandbox_preflight_report with
    | Some preflight when not preflight.ok ->
        ( Some (Keeper_sandbox_runtime.docker_preflight_failure_message preflight),
          preflight.next_actions,
          false )
    | Some _ -> (None, [], true)
    | None -> (None, [], true)
  in
  let live_outcome, live_warning, catalog_validation =
    match
      Cascade_catalog_runtime.inspect_active ~sw ~net ~clock ()
      |> live_catalog_summary
    with
    | outcome, warning, validation -> (outcome, warning, validation)
  in
  let warnings =
    [ report.warnings;
      (match live_warning with
       | None -> []
       | Some warning -> [ warning ]);
      (match sandbox_warning with
       | None -> []
       | Some warning -> [ warning ]) ]
    |> List.concat
  in
  let next_actions =
    let catalog_actions =
      if
        match live_outcome with
        | Live_catalog_serving_last_known_good | Live_catalog_invalid -> true
        | Live_catalog_valid | Live_catalog_partial -> false
      then
        [
          "Fix the active cascade catalog candidates/strategy and rerun `masc-mcp doctor config`.";
        ]
      else
        []
    in
    report.next_actions @ catalog_actions @ sandbox_actions
    |> dedupe_keep_order
  in
  let status =
    match report.init_state, report.status, live_outcome, sandbox_preflight_ok with
    | (Invalid_env | Missing_init), _, _, _ -> Error
    | _, _, (Live_catalog_serving_last_known_good | Live_catalog_invalid), _ ->
        Error
    | _, _, Live_catalog_partial, _ -> Warn
    | _, Error, Live_catalog_valid, _ -> Error
    | _, Warn, Live_catalog_valid, _ -> Warn
    | _, Ok, Live_catalog_valid, false -> Warn
    | _, Ok, Live_catalog_valid, true -> Ok
  in
  {
    report with
    status;
    warnings;
    next_actions;
    catalog_validation = Some catalog_validation;
    sandbox_preflight;
  }

let to_yojson (report : t) =
  `Assoc
    [
      ("status", `String (status_to_string report.status));
      ("init_state", `String (init_state_to_string report.init_state));
      ("base_path", `String report.base_path);
      ("active_config_root", `String report.active_config_root);
      ("active_personas_root", `String report.active_personas_root);
      ("runtime_data_root", `String report.runtime_data_root);
      ("config_root_source", `String report.config_root_source);
      ("local_base_config_root", `String report.local_base_config_root);
      ("local_base_config_initialized", `Bool report.local_base_config_initialized);
      (option_field "explicit_config_dir" report.explicit_config_dir);
      (option_field "explicit_personas_dir" report.explicit_personas_dir);
      (option_field "repo_config_seed_path" report.repo_config_seed_path);
      ("repo_fallback_enabled", `Bool report.repo_fallback_enabled);
      ("keeper_runtime_toml_present", `Bool report.keeper_runtime_toml_present);
      ("warnings", `List (List.map (fun value -> `String value) report.warnings));
      ("next_actions", `List (List.map (fun value -> `String value) report.next_actions));
      ( "persona_tool_preset_conflicts",
        `List
          (List.map persona_tool_preset_conflict_to_yojson
             report.persona_tool_preset_conflicts) );
      ( "catalog_validation",
        match report.catalog_validation with
        | Some value -> value
        | None -> `Null );
      ( "sandbox_preflight",
        match report.sandbox_preflight with
        | Some value -> value
        | None -> `Null );
      (* Sandbox configuration SSOT snapshot (#10426 P2d).  Operators can
         read [raw.<section>.<key>] for per-setting provenance
         (env vs default vs load_bearing_floor) and [derived.*] for the
         post-cross-cutting-rule values Docker actually sees. *)
      ( "sandbox_config", Env_config_sandbox.effective_config_json () );
    ]

let render_text (report : t) =
  let buf = Buffer.create 1024 in
  let add_line line =
    Buffer.add_string buf line;
    Buffer.add_char buf '\n'
  in
  add_line "MASC Config Doctor";
  add_line
    (Printf.sprintf "status: %s" (status_to_string report.status));
  add_line
    (Printf.sprintf "init_state: %s" (init_state_to_string report.init_state));
  add_line (Printf.sprintf "base_path: %s" report.base_path);
  add_line
    (Printf.sprintf "runtime_data_root: %s" report.runtime_data_root);
  add_line
    (Printf.sprintf "active_config_root: %s (%s)"
       report.active_config_root report.config_root_source);
  add_line
    (Printf.sprintf "active_personas_root: %s" report.active_personas_root);
  add_line
    (Printf.sprintf "local_base_config_root: %s (initialized=%s)"
       report.local_base_config_root
       (if report.local_base_config_initialized then "yes" else "no"));
  add_line
    (Printf.sprintf "explicit_config_dir: %s"
       (Option.value ~default:"(unset)" report.explicit_config_dir));
  add_line
    (Printf.sprintf "explicit_personas_dir: %s"
       (Option.value ~default:"(unset)" report.explicit_personas_dir));
  add_line
    (Printf.sprintf "repo_config_seed_path: %s"
       (Option.value ~default:"(not found)" report.repo_config_seed_path));
  add_line
    (Printf.sprintf "repo_fallback_enabled: %s"
       (if report.repo_fallback_enabled then "yes" else "no"));
  add_line
    (Printf.sprintf "keeper_runtime.toml: %s"
       (if report.keeper_runtime_toml_present then "present" else "missing"));
  if report.persona_tool_preset_conflicts <> [] then begin
    add_line "";
    add_line "persona_tool_preset_conflicts:";
    List.iter
      (fun conflict ->
         add_line
           (Printf.sprintf "- keeper=%s persona=%s toml=%s persona_profile=%s"
              conflict.keeper_name
              conflict.persona_name
              conflict.toml_path
              conflict.persona_path))
      report.persona_tool_preset_conflicts
  end;
  (match report.catalog_validation with
   | Some validation ->
       add_line "";
       add_line "catalog_validation:";
       add_line (Yojson.Safe.pretty_to_string validation)
   | None -> ());
  (match report.sandbox_preflight with
   | Some preflight ->
       add_line "";
       add_line "sandbox_preflight:";
       add_line (Yojson.Safe.pretty_to_string preflight)
   | None -> ());
  if report.warnings <> [] then begin
    add_line "";
    add_line "warnings:";
    List.iter
      (fun warning -> add_line (Printf.sprintf "- %s" warning))
      report.warnings
  end;
  if report.next_actions <> [] then begin
    add_line "";
    add_line "next_actions:";
    List.iter
      (fun action -> add_line (Printf.sprintf "- %s" action))
      report.next_actions
  end;
  Buffer.contents buf |> String.trim

let exit_code (report : t) =
  match report.status with
  | Ok -> 0
  | Warn | Error -> 1
