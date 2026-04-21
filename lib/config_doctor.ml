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
}

type catalog_issue_severity =
  | Catalog_warn
  | Catalog_error

type catalog_issue = {
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

let contains_substring ~needle s =
  let needle_len = String.length needle in
  let s_len = String.length s in
  if needle_len = 0 || needle_len > s_len then
    false
  else
    let limit = s_len - needle_len in
    let rec loop i =
      if i > limit then
        false
      else if String.sub s i needle_len = needle then
        true
      else
        loop (i + 1)
    in
    loop 0

let has_suffix ~suffix s =
  let suffix_len = String.length suffix in
  let s_len = String.length s in
  s_len > suffix_len
  && String.sub s (s_len - suffix_len) suffix_len = suffix

let is_provider_unavailable_error msg =
  contains_substring ~needle:"unavailable" msg

let split_provider_model (s : string) : (string * string) option =
  match String.index_opt s ':' with
  | None -> None
  | Some idx ->
      if idx = 0 || idx >= String.length s - 1 then
        None
      else
        let provider_name =
          String.sub s 0 idx |> String.trim |> String.lowercase_ascii
        in
        let model_id =
          String.sub s (idx + 1) (String.length s - idx - 1)
          |> String.trim
        in
        if model_id = "" then None else Some (provider_name, model_id)

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

let discover_cascade_profiles = function
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (key, value) ->
             match value with
             | `List _ when has_suffix ~suffix:"_models" key ->
                 let suffix_len = String.length "_models" in
                 Some (String.sub key 0 (String.length key - suffix_len))
             | _ -> None)
      |> List.sort_uniq String.compare
  | _ -> []

let model_ids_of_specs (specs : string list) : string list =
  specs
  |> Cascade_config.expand_auto_models
  |> List.filter_map (fun spec ->
         match split_provider_model spec with
         | Some (_, model_id) when model_id <> "" -> Some model_id
         | _ -> None)
  |> List.sort_uniq String.compare

let format_spec_errors specs =
  specs
  |> List.map (fun (spec, msg) -> Printf.sprintf "%S (%s)" spec msg)
  |> String.concat ", "

let priority_tier_issue ~profile configured_specs raw_tiers =
  let configured_model_ids = model_ids_of_specs configured_specs in
  if configured_model_ids = [] then
    Some
      {
        severity = Catalog_error;
        message =
          Printf.sprintf
            "Cascade preset %s uses priority_tier but has no configured \
             models to validate."
            profile;
      }
  else
    let normalized =
      raw_tiers
      |> List.filter_map (fun tier ->
             let tier_model_ids =
               model_ids_of_specs tier
               |> List.filter (fun model_id ->
                      List.mem model_id configured_model_ids)
             in
             if tier_model_ids = [] then None else Some tier_model_ids)
    in
    if normalized = [] then
      Some
        {
          severity = Catalog_error;
          message =
            Printf.sprintf
              "Cascade preset %s uses priority_tier, but every tier \
               collapses after model-id normalization; runtime will fall \
               back to failover."
              profile;
        }
    else if List.length normalized < List.length raw_tiers then
      Some
        {
          severity = Catalog_warn;
          message =
            Printf.sprintf
              "Cascade preset %s uses priority_tier, but %d/%d tier(s) \
               collapse after model-id normalization."
              profile
              (List.length raw_tiers - List.length normalized)
              (List.length raw_tiers);
        }
    else
      None

let diagnose_cascade_profile ~config_path ~profile =
  let model_specs =
    Cascade_config_loader.load_profile_weighted ~config_path ~name:profile
    |> List.map (fun (entry : Cascade_config_loader.weighted_entry) ->
           entry.model)
  in
  let invalid_specs =
    model_specs
    |> Cascade_config.expand_auto_models
    |> List.filter_map (fun spec ->
           match Cascade_config.parse_model_string_exn spec with
           | Ok _ -> None
           | Error msg when is_provider_unavailable_error msg -> None
           | Error msg -> Some (spec, msg))
  in
  let invalid_model_issue =
    if invalid_specs = [] then
      None
    else
      Some
        {
          severity = Catalog_error;
          message =
            Printf.sprintf
              "Cascade preset %s has %d hard-invalid model spec(s): %s"
              profile
              (List.length invalid_specs)
              (format_spec_errors invalid_specs);
        }
  in
  let strategy_cfg =
    Cascade_config_loader.resolve_strategy_config ~config_path ~name:profile
  in
  let strategy_issue =
    match strategy_cfg.kind with
    | None -> None
    | Some raw_kind -> (
        match Cascade_strategy.parse_kind raw_kind with
        | Error msg ->
            Some
              {
                severity = Catalog_error;
                message =
                  Printf.sprintf
                    "Cascade preset %s has unknown strategy %S: %s"
                    profile raw_kind msg;
              }
        | Ok Cascade_strategy.Priority_tier -> (
            match strategy_cfg.tiers with
            | None ->
                Some
                  {
                    severity = Catalog_error;
                    message =
                      Printf.sprintf
                        "Cascade preset %s uses priority_tier without a \
                         valid non-empty <name>_tiers configuration."
                        profile;
                  }
            | Some raw_tiers ->
                priority_tier_issue ~profile model_specs raw_tiers)
        | Ok _ -> None)
  in
  [ invalid_model_issue; strategy_issue ]
  |> List.filter_map (fun issue -> issue)

let diagnose_cascade_catalog ~active_config_root =
  let config_path =
    Filename.concat active_config_root Config_dir_resolver.cascade_json_filename
  in
  if not (Env_config_core.existing_file config_path) then
    []
  else
    match Cascade_config_loader.load_json config_path with
    | Error msg ->
        [
          {
            severity = Catalog_error;
            message =
              Printf.sprintf
                "Cascade catalog %s could not be loaded: %s"
                config_path msg;
          };
        ]
    | Ok json ->
        let profiles = discover_cascade_profiles json in
        let issues =
          profiles
          |> List.concat_map (fun profile ->
                 diagnose_cascade_profile ~config_path ~profile)
        in
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
    |> fun base_actions -> base_actions @ cascade_actions
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
  }

let analyze ~base_path_input ~default_base_path () =
  current_inputs ~base_path_input ~default_base_path ()
  |> analyze_with

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
