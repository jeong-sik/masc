module StringSet = Set_util.StringSet

(** SSOT for config filenames documented in [docs/TOML-RELOAD-MATRIX.md].
    Consumed by the resolver here and by config loaders elsewhere in the
    codebase. Issue #8414. *)
let tool_policy_toml_filename = "tool_policy.toml"
let runtime_toml_filename = "runtime.toml"

type source =
  | Env
  | Local_masc
  | Invalid_env
  | Missing

type status =
  | Ready
  | Warn
  | Invalid_env_status
  | Missing_status

type path_item = {
  path : string;
  exists : bool;
  source : source;
}

type resolution = {
  status : status;
  warnings : string list;
  config_root : path_item;
  prompts : path_item;
  keepers : path_item;
  personas : path_item;
}

type inputs = {
  cwd : string;
  executable_name : string;
  env_base_path : string option;
  env_config_dir : string option;
  env_personas_dir : string option;
}

let trim_opt = Env_config_core.trim_opt
let existing_dir = Env_config_core.existing_dir
let existing_file = Env_config_core.existing_file

(* RFC-0084 host-config-cleanup-F — typed test-mode predicate.
   Replaces the ad-hoc [test_]-prefix substring classifier with
   the typed [Host_config.test_mode_kind] surface from
   PR-12.  The previous helper accepted an arbitrary executable name
   argument but every caller passed [Sys.executable_name] — the
   typed surface always reads the current binary so the parameter is
   dropped.  See [test_pr_f_test_mode_migration]. *)
let running_under_test_executable () =
  Host_config.is_test_mode
    (Host_config.host ()).test_mode

let test_config_path_override_env = "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"
let test_base_path_override_env = "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE"

let allow_inherited_test_config_paths () =
  Env_config_core.get_bool ~default:false
    test_config_path_override_env

let allow_inherited_test_base_path () =
  Env_config_core.get_bool ~default:false
    test_base_path_override_env

(* RFC-0085 PR-8 — Route path-derived env reads through Host_config.from_env
   so the SSOT lives in lib/host_config/ instead of Env_config_core. *)
let initial_env_base_path = (Host_config.from_env ()).base_path
let initial_env_config_dir = (Host_config.from_env ()).config_dir
let initial_env_personas_dir = (Host_config.from_env ()).personas_dir
let initial_env_home = Sys.getenv_opt "HOME" |> trim_opt

let sanitize_inherited_test_env_opt ~running_under_test_executable ~allow_inherited
    ~initial ~current =
  if running_under_test_executable && not allow_inherited then
    match current, initial with
    | Some current_value, Some initial_value
      when String.equal current_value initial_value -> None
    | _ -> current
  else
    current

let path_equal_or_under ~parent path =
  String.equal path parent
  || (not (String.equal parent "/")
     && String.starts_with ~prefix:(parent ^ "/") path)
  || (String.equal parent "/" && String.starts_with ~prefix:"/" path)

let sanitize_inherited_test_base_path_opt ~running_under_test_executable
    ~allow_inherited ~initial ~current ~home =
  if running_under_test_executable && not allow_inherited then
    match current, initial, home with
    | Some current_value, Some initial_value, Some home
      when String.equal current_value initial_value ->
        let current_base =
          Env_config_core.normalize_masc_base_path_input current_value
        in
        let home_base = Env_config_core.normalize_masc_base_path_input home in
        if home_base <> "" && path_equal_or_under ~parent:home_base current_base
        then None
        else current
    | _ -> current
  else
    current

let current_env_config_dir_opt () =
  sanitize_inherited_test_env_opt
    ~running_under_test_executable:
      (running_under_test_executable ())
    ~allow_inherited:(allow_inherited_test_config_paths ())
    ~initial:initial_env_config_dir
    ~current:((Host_config.from_env ()).config_dir)

let current_env_base_path_opt () =
  sanitize_inherited_test_base_path_opt
    ~running_under_test_executable:
      (running_under_test_executable ())
    ~allow_inherited:(allow_inherited_test_base_path ())
    ~initial:initial_env_base_path
    ~current:((Host_config.from_env ()).base_path)
    ~home:initial_env_home

let current_env_personas_dir_opt () =
  sanitize_inherited_test_env_opt
    ~running_under_test_executable:
      (running_under_test_executable ())
    ~allow_inherited:(allow_inherited_test_config_paths ())
    ~initial:initial_env_personas_dir
    ~current:((Host_config.from_env ()).personas_dir)

let fallback_cwd_from_env () =
  let host = Host_config.from_env () in
  match host.base_path with
  | Some base_path when not (Filename.is_relative base_path) -> base_path
  | _ ->
    (match host.home with
     | Some home when not (Filename.is_relative home) -> home
     | _ -> Filename.get_temp_dir_name ())

let current_working_dir () =
  try Sys.getcwd () with
  | Sys_error _ -> fallback_cwd_from_env ()

let base_path_or_cwd () =
  match (Host_config.from_env ()).base_path with
  | Some path when Filename.is_relative path ->
    Filename.concat (current_working_dir ()) path
  | Some path -> path
  | None -> current_working_dir ()

(** Prefer [absolute_path_from ~cwd] when the caller has an explicit anchor.
    [absolute_path] falls back to the process cwd via [current_working_dir]. *)
let absolute_path path =
  if Filename.is_relative path then Filename.concat (current_working_dir ()) path
  else path

(** Resolve [path] relative to an explicit [cwd]. Absolute paths are returned
    verbatim; this keeps the caller's anchor as the SSOT. *)
let absolute_path_from ~cwd path =
  if Filename.is_relative path then Filename.concat cwd path else path

type canonical_base_path_error =
  | Empty_after_normalization
  | Could_not_derive_absolute of { input : string }

let canonical_base_path_error_to_string = function
  | Empty_after_normalization -> "path is empty after normalization"
  | Could_not_derive_absolute { input } ->
    Printf.sprintf "could not derive an absolute path from %S" input
;;

let canonical_base_path raw =
  let normalized = Env_config_core.normalize_masc_base_path_input raw in
  if String.equal normalized ""
  then Error Empty_after_normalization
  else
    let absolute =
      if Filename.is_relative normalized
      then absolute_path_from ~cwd:(current_working_dir ()) normalized
      else normalized
    in
    let canonical = Env_config_core.normalize_masc_base_path_input absolute in
    if String.equal canonical "" || Filename.is_relative canonical
    then Error (Could_not_derive_absolute { input = raw })
    else Ok canonical
;;

let source_to_string = function
  | Env -> "env"
  | Local_masc -> "local_masc"
  | Invalid_env -> "invalid_env"
  | Missing -> "missing"

let status_to_string = function
  | Ready -> "ready"
  | Warn -> "warn"
  | Invalid_env_status -> "invalid_env"
  | Missing_status -> "missing"

let item_to_json (item : path_item) =
  `Assoc
    [
      ("path", `String item.path);
      ("exists", `Bool item.exists);
      ("source", `String (source_to_string item.source));
    ]

let to_json (resolution : resolution) =
  `Assoc
    [
      ("status", `String (status_to_string resolution.status));
      ( "warnings",
        `List (List.map (fun warning -> `String warning) resolution.warnings) );
      ("config_root", item_to_json resolution.config_root);
      ("prompts", item_to_json resolution.prompts);
      ("keepers", item_to_json resolution.keepers);
      ("personas", item_to_json resolution.personas);
    ]

let config_signature_exists config_dir =
  let runtime_toml = Filename.concat config_dir runtime_toml_filename in
  let tool_policy_toml = Filename.concat config_dir tool_policy_toml_filename in
  let prompts = Filename.concat config_dir "prompts" in
  let keepers = Filename.concat config_dir "keepers" in
  let personas = Filename.concat config_dir "personas" in
  existing_dir config_dir
  && (existing_file runtime_toml
     || existing_file tool_policy_toml
     || existing_dir prompts || existing_dir keepers
     || existing_dir personas)

let rec ancestor_dirs path =
  let dir = absolute_path path in
  let parent = Filename.dirname dir in
  if parent = dir then [ dir ] else dir :: ancestor_dirs parent

let path_from_executable ~cwd executable_name =
  let exe = absolute_path_from ~cwd executable_name in
  if not (Sys.file_exists exe) then None
  else
    ancestor_dirs (Filename.dirname exe)
    |> List.find_map (fun dir ->
           let candidate = Filename.concat dir "config" in
           if config_signature_exists candidate then Some candidate else None)

let path_from_cwd cwd =
  let candidate = Filename.concat cwd "config" |> absolute_path_from ~cwd in
  if config_signature_exists candidate then Some candidate else None

let base_path_config_root ~cwd base_path =
  let base_path =
    base_path
    |> Env_config_core.normalize_masc_base_path_input
    |> absolute_path_from ~cwd
  in
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "config"

let path_from_local_masc (inputs : inputs) =
  match trim_opt inputs.env_base_path with
  | None -> None
  | Some base_path ->
      let candidate = base_path_config_root ~cwd:inputs.cwd base_path in
      if config_signature_exists candidate then Some candidate else None

let default_missing_root (inputs : inputs) =
  match trim_opt inputs.env_base_path with
  | Some base_path -> base_path_config_root ~cwd:inputs.cwd base_path
  | None ->
      let cwd = absolute_path_from ~cwd:inputs.cwd inputs.cwd in
      Filename.concat (Common.masc_dir_from_base_path ~base_path:cwd) "config"

let config_root_resolution (inputs : inputs) =
  let missing path warnings =
    ({ path; exists = false; source = Missing }, warnings)
  in
  match trim_opt inputs.env_config_dir with
  | Some raw ->
      let path = absolute_path_from ~cwd:inputs.cwd raw in
      if existing_dir path then
        ( { path; exists = true; source = Env },
          [] )
      else
        ( { path; exists = false; source = Invalid_env },
          [ Printf.sprintf
              "MASC_CONFIG_DIR is set but does not point to a directory: %s"
              path ] )
  | None ->
      match path_from_local_masc inputs with
      | Some path -> ({ path; exists = true; source = Local_masc }, [])
      | None ->
          let path = default_missing_root inputs in
          missing path
            [
              Printf.sprintf
                "Unable to resolve config directory; set MASC_CONFIG_DIR or initialize the base-path config root: %s"
                path;
            ]

let child_item (root : path_item) name =
  let path = Filename.concat root.path name in
  let exists = root.exists && existing_dir path in
  { path; exists; source = root.source }

let file_item (root : path_item) name =
  let path = Filename.concat root.path name in
  let exists = root.exists && existing_file path in
  { path; exists; source = root.source }

let personas_item (inputs : inputs) root =
  match trim_opt inputs.env_personas_dir with
  | Some raw ->
      let path = absolute_path_from ~cwd:inputs.cwd raw in
      if existing_dir path then
        ({ path; exists = true; source = Env }, [])
      else
        ( { path; exists = false; source = Invalid_env },
          [ Printf.sprintf
              "MASC_PERSONAS_DIR is set but does not point to a directory: %s"
              path ] )
  | None -> (child_item root "personas", [])

let inputs_from_env () =
  {
    cwd = current_working_dir ();
    executable_name = Sys.executable_name;
    env_base_path = current_env_base_path_opt ();
    env_config_dir = current_env_config_dir_opt ();
    env_personas_dir = current_env_personas_dir_opt ();
  }

let resolve_with inputs =
  let config_root, root_warnings = config_root_resolution inputs in
  let prompts = child_item config_root "prompts" in
  let keepers = child_item config_root "keepers" in
  let personas, persona_warnings = personas_item inputs config_root in
  let missing_child_warnings =
    [ ("prompts", prompts.exists)
    ; ("keepers", keepers.exists)
    ; ("personas", personas.exists)
    ]
    |> List.filter_map (fun (label, exists) ->
           if exists then None
           else
             Some
               (Printf.sprintf "Resolved config child is missing: %s" label))
  in
  let warnings =
    root_warnings @ persona_warnings @ missing_child_warnings
  in
  let status =
    match config_root.source with
    | Invalid_env -> Invalid_env_status
    | Missing -> Missing_status
    | Env | Local_masc ->
        if warnings = [] then Ready else Warn
  in
  {
    status;
    warnings;
    config_root;
    prompts;
    keepers;
    personas;
  }

let cached_resolution : resolution option ref = ref None

let resolve () =
  match !cached_resolution with
  | Some r -> r
  | None ->
      let r = resolve_with (inputs_from_env ()) in
      cached_resolution := Some r;
      r

let reset () =
  cached_resolution := None

let prompts_dir () =
  (resolve ()).prompts.path

let keepers_dir () =
  (resolve ()).keepers.path

let inputs_for_base_path ~base_path =
  {
    cwd = base_path;
    executable_name = Sys.executable_name;
    env_base_path = Some base_path;
    env_config_dir = current_env_config_dir_opt ();
    env_personas_dir = current_env_personas_dir_opt ();
  }

let resolve_for_base_path ~base_path =
  resolve_with (inputs_for_base_path ~base_path)

let keepers_dir_for_base_path ~base_path =
  (resolve_for_base_path ~base_path).keepers.path

let keeper_runtime_store_of_dirname =
  Common.keeper_runtime_store_of_dirname

let personas_dir_opt () =
  let resolution = resolve () in
  match resolution.config_root.source with
  | Env | Local_masc when resolution.personas.exists ->
      Some resolution.personas.path
  | Env | Local_masc | Invalid_env | Missing ->
      None

let dedupe_paths paths =
  let rec go seen acc = function
    | [] -> List.rev acc
    | p :: rest ->
      if StringSet.mem p seen then go seen acc rest
      else go (StringSet.add p seen) (p :: acc) rest
  in
  go StringSet.empty [] paths

let personas_dirs_with inputs resolution =
  (* Mirror [personas_dir_opt]'s invariant: when the resolver is Missing or
     Invalid_env, never expose a personas path even if [resolution.personas.exists]
     happens to be true (e.g. [default_missing_root] pointing at a repo-local
     config/ tree). Without this gate, callers can silently load personas from
     a fallback root the resolver explicitly disowned. *)
  let explicit_personas_dir_override = trim_opt inputs.env_personas_dir in
  (* Persona resolution is intentionally single-source:
     - MASC_PERSONAS_DIR when explicitly set (bypasses config-root gating;
       operator-declared persona roots stand on their own — a user may
       legitimately want personas without a full MASC config directory)
     - otherwise the resolved config root's personas/
     Hidden secondary searches (secondary personas roots, base-path-root personas)
     make the dashboard/config panel lie about the actual source of truth. *)
  match explicit_personas_dir_override with
  | Some _ ->
    (* The env override path is captured in [resolution.personas] by
       [personas_item] when MASC_PERSONAS_DIR is set; honor its exists
       flag regardless of [config_root.source].  If the env path is
       invalid the source comes back as [Invalid_env] and we still
       suppress to keep the no-silent-fallback contract. *)
    (match resolution.personas.source with
     | Env when resolution.personas.exists -> [ resolution.personas.path ]
     | _ -> [])
  | None ->
    let primary =
      match resolution.config_root.source with
      | Invalid_env | Missing -> []
      | Env | Local_masc ->
        if resolution.personas.exists then [ resolution.personas.path ] else []
    in
    dedupe_paths primary

let personas_dirs_for_base_path ~base_path =
  let inputs = inputs_for_base_path ~base_path in
  let resolution = resolve_with inputs in
  personas_dirs_with inputs resolution

let personas_dirs () =
  let resolution = resolve () in
  let inputs = inputs_from_env () in
  personas_dirs_with inputs resolution

let keeper_toml_path_opt name =
  let path = Filename.concat (keepers_dir ()) (name ^ ".toml") in
  if existing_file path then Some path else None

let keeper_toml_path_opt_for_base_path ~base_path name =
  let path =
    Filename.concat (keepers_dir_for_base_path ~base_path) (name ^ ".toml")
  in
  if existing_file path then Some path else None

let warnings () =
  (resolve ()).warnings

let last_logged_signature : string option ref = ref None

let log_warnings ?(context = "ConfigDir") () =
  let resolution = resolve () in
  let signature =
    String.concat "\n"
      ((status_to_string resolution.status) :: resolution.warnings)
  in
  if resolution.warnings <> [] && !last_logged_signature <> Some signature then begin
    List.iter (fun warning ->
        Log.warn ~ctx:context "%s" warning)
      resolution.warnings;
    last_logged_signature := Some signature
  end

(* Track the last resolution signature we info-logged so startup banner is
   idempotent across repeated [log_resolution] calls (bootstrap + per-query). *)
let last_logged_resolution_signature : string option ref = ref None

(** Emit a single info-level line stating the resolved config root source and
    path. When [MASC_CONFIG_DIR] is set, also note whether a [<base_path>/.masc/config]
    overlay is being silently shadowed — this is a footgun operators commonly
    hit when they write to an overlay and then wonder why changes are ignored.

    The message is a SSOT surface for "which config is actually active right
    now?"; downstream tooling should read it instead of re-guessing via env
    vars. *)
let log_resolution ?(context = "ConfigDir") () =
  let inputs = inputs_from_env () in
  let resolution = resolve () in
  let item = resolution.config_root in
  let source = source_to_string item.source in
  let shadow_note =
    match item.source with
    | Env ->
      (match path_from_local_masc inputs with
       | Some overlay_path when overlay_path <> item.path ->
         Printf.sprintf
           " (MASC_CONFIG_DIR shadows local_masc overlay at %s; \
            unset MASC_CONFIG_DIR to prefer the overlay)"
           overlay_path
       | _ -> "")
    | _ -> ""
  in
  let signature =
    Printf.sprintf "source=%s path=%s%s" source item.path shadow_note
  in
  if !last_logged_resolution_signature <> Some signature then begin
    Log.info ~ctx:context "resolved: %s" signature;
    last_logged_resolution_signature := Some signature
  end

(* RFC-0121 — .masc/<sub> sub-directory accessors.

   Layout SSOT: callers stop computing base_path plus .masc child paths
   and instead route through these helpers. The directory structure decision
   ([auth], [credentials], [runtime/agent], etc.) lives in this single module
   so that future relocations need a single edit + a CI gate to enforce. *)

let masc_root ~base_path =
  Common.masc_dir_from_base_path ~base_path

let auth_dir ~base_path =
  Common.auth_dir_from_base_path ~base_path

let credentials_dir ~base_path =
  Filename.concat (masc_root ~base_path) "credentials"

let agent_runtime_dir ~base_path =
  Filename.concat (masc_root ~base_path) "runtime/agent"

let repos_dir ~base_path =
  Filename.concat (masc_root ~base_path) "repos"

let tmp_dir ~base_path =
  Filename.concat (masc_root ~base_path) "tmp"

let locks_dir ~base_path =
  Filename.concat (masc_root ~base_path) "locks"

let data_dir ~base_path =
  Filename.concat base_path "data"

let repositories_toml_basename = "repositories.toml"

let repositories_toml_path ~base_path =
  Filename.concat (masc_root ~base_path)
    (Filename.concat "config" repositories_toml_basename)

let keeper_repo_mappings_toml_path ~base_path =
  Filename.concat (masc_root ~base_path) "config/keeper_repo_mappings.toml"
