module StringSet = Set.Make (String)

(** SSOT for config filenames documented in [docs/TOML-RELOAD-MATRIX.md].
    Consumed by the resolver here and by config loaders elsewhere in the
    codebase. Issue #8414. *)
let cascade_json_filename = "cascade.json"
let cascade_toml_filename = "cascade.toml"
let tool_policy_toml_filename = "tool_policy.toml"
let keeper_runtime_toml_filename = "keeper_runtime.toml"

type source =
  | Env
  | Local_masc
  | Home_masc
  | Invalid_env
  | Exe_relative
  | Cwd
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
  cascade_authoring : path_item;
  cascade : path_item;
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
  env_home : string option;
}

let trim_opt = Env_config_core.trim_opt
let existing_dir = Env_config_core.existing_dir
let existing_file = Env_config_core.existing_file

let running_under_test_executable executable_name =
  executable_name
  |> Filename.basename
  |> String.lowercase_ascii
  |> String.starts_with ~prefix:"test_"

let test_config_path_override_env = "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE"
let test_base_path_override_env = "MASC_TEST_ALLOW_BASE_PATH_OVERRIDE"

let allow_inherited_test_config_paths () =
  Env_config_core.get_bool ~default:false
    test_config_path_override_env

let allow_inherited_test_base_path () =
  Env_config_core.get_bool ~default:false
    test_base_path_override_env

let initial_env_base_path = Env_config_core.base_path_raw_opt ()
let initial_env_config_dir = Env_config_core.config_dir_opt ()
let initial_env_personas_dir = Env_config_core.personas_dir_opt ()
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
      (running_under_test_executable Sys.executable_name)
    ~allow_inherited:(allow_inherited_test_config_paths ())
    ~initial:initial_env_config_dir
    ~current:(Env_config_core.config_dir_opt ())

let current_env_base_path_opt () =
  sanitize_inherited_test_base_path_opt
    ~running_under_test_executable:
      (running_under_test_executable Sys.executable_name)
    ~allow_inherited:(allow_inherited_test_base_path ())
    ~initial:initial_env_base_path
    ~current:(Env_config_core.base_path_raw_opt ())
    ~home:initial_env_home

let current_env_personas_dir_opt () =
  sanitize_inherited_test_env_opt
    ~running_under_test_executable:
      (running_under_test_executable Sys.executable_name)
    ~allow_inherited:(allow_inherited_test_config_paths ())
    ~initial:initial_env_personas_dir
    ~current:(Env_config_core.personas_dir_opt ())

let current_env_home_opt () =
  sanitize_inherited_test_env_opt
    ~running_under_test_executable:
      (running_under_test_executable Sys.executable_name)
    ~allow_inherited:(allow_inherited_test_config_paths ())
    ~initial:initial_env_home
    ~current:(Sys.getenv_opt "HOME" |> trim_opt)

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let absolute_path_from ~cwd path =
  if Filename.is_relative path then Filename.concat cwd path else path

let source_to_string = function
  | Env -> "env"
  | Local_masc -> "local_masc"
  | Home_masc -> "home_masc"
  | Invalid_env -> "invalid_env"
  | Exe_relative -> "exe_relative"
  | Cwd -> "cwd"
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
      ("cascade_authoring", item_to_json resolution.cascade_authoring);
      ("cascade", item_to_json resolution.cascade);
      ("prompts", item_to_json resolution.prompts);
      ("keepers", item_to_json resolution.keepers);
      ("personas", item_to_json resolution.personas);
    ]

let config_signature_exists config_dir =
  let cascade = Filename.concat config_dir cascade_json_filename in
  let cascade_toml = Filename.concat config_dir cascade_toml_filename in
  let prompts = Filename.concat config_dir "prompts" in
  let keepers = Filename.concat config_dir "keepers" in
  let personas = Filename.concat config_dir "personas" in
  existing_dir config_dir
  && ((existing_file cascade || existing_file cascade_toml)
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

let repo_config_fallback_enabled () =
  Env_config_core.get_bool ~default:false "MASC_ALLOW_REPO_CONFIG_FALLBACK"

let disabled_repo_config_fallback_warnings (inputs : inputs) =
  if repo_config_fallback_enabled () then
    []
  else
    let candidates =
      [
        ("cwd", path_from_cwd inputs.cwd);
        ("exe_relative", path_from_executable ~cwd:inputs.cwd inputs.executable_name);
      ]
      |> List.filter_map (fun (label, path_opt) ->
             Option.map (fun path -> (label, path)) path_opt)
    in
    match candidates with
    | [] -> []
    | hits ->
        let rendered =
          hits
          |> List.map (fun (label, path) -> Printf.sprintf "%s:%s" label path)
          |> String.concat ", "
        in
        [
          Printf.sprintf
            "Repo config fallback is disabled by default; set MASC_ALLOW_REPO_CONFIG_FALLBACK=true to use %s"
            rendered;
        ]

let path_from_home_masc (inputs : inputs) =
  match trim_opt inputs.env_home with
  | None -> None
  | Some home ->
      let candidate = Filename.concat (Common.masc_dir_from_base_path ~base_path:home) "config" in
      if config_signature_exists candidate then Some candidate else None

let path_from_local_masc (inputs : inputs) =
  match trim_opt inputs.env_base_path with
  | None -> None
  | Some base_path ->
      let base_path =
        base_path
        |> Env_config_core.normalize_masc_base_path_input
        |> absolute_path_from ~cwd:inputs.cwd
      in
      let candidate = Filename.concat (Common.masc_dir_from_base_path ~base_path) "config" in
      if config_signature_exists candidate then Some candidate else None

let default_missing_root (inputs : inputs) =
  match trim_opt inputs.env_home with
  | Some home -> Filename.concat (Common.masc_dir_from_base_path ~base_path:home) "config"
  | None -> Filename.concat inputs.cwd "config" |> absolute_path_from ~cwd:inputs.cwd

let config_root_resolution (inputs : inputs) =
  let missing path warnings =
    ( { path; exists = false; source = Missing },
      warnings @ disabled_repo_config_fallback_warnings inputs )
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
          match path_from_home_masc inputs with
          | Some path ->
              (* Warn only when MASC_BASE_PATH was set but local resolution
                 still failed — that is the #9896 drift signature (harness
                 subprocess has env set or is meant to, yet Local_masc
                 didn't resolve so we slid into HOME). If env_base_path is
                 empty the user deliberately runs without an explicit base
                 path and HOME is the intended root; no warning needed. *)
              let warnings =
                match trim_opt inputs.env_base_path with
                | None -> []
                | Some _ ->
                    [
                      Printf.sprintf
                        "MASC_BASE_PATH is set but its .masc/config was \
                         not found; falling back to HOME (%s). Check \
                         subprocess env propagation. See #9896."
                        path;
                    ]
              in
              ({ path; exists = true; source = Home_masc }, warnings)
          | None ->
              if repo_config_fallback_enabled () then
                match path_from_cwd inputs.cwd with
                | Some path -> ({ path; exists = true; source = Cwd }, [])
                | None ->
                    match path_from_executable ~cwd:inputs.cwd inputs.executable_name with
                    | Some path -> ({ path; exists = true; source = Exe_relative }, [])
                    | None ->
                        let path = default_missing_root inputs in
                        missing path
                          [
                            Printf.sprintf
                              "Unable to resolve config directory; set MASC_CONFIG_DIR (current fallback candidate: %s)"
                              path;
                          ]
              else
                let path = default_missing_root inputs in
                missing path
                  [
                    Printf.sprintf
                      "Unable to resolve config directory; set MASC_CONFIG_DIR (current fallback candidate: %s)"
                      path;
                  ]

let child_item (root : path_item) name =
  let path = Filename.concat root.path name in
  let exists =
    root.exists
    &&
    if String.equal name cascade_json_filename then
      existing_file path
      || existing_file (Filename.concat root.path cascade_toml_filename)
    else
      existing_dir path
  in
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
    cwd = Sys.getcwd ();
    executable_name = Sys.executable_name;
    env_base_path = current_env_base_path_opt ();
    env_config_dir = current_env_config_dir_opt ();
    env_personas_dir = current_env_personas_dir_opt ();
    env_home = current_env_home_opt ();
  }

let resolve_with inputs =
  let config_root, root_warnings = config_root_resolution inputs in
  let cascade_authoring = file_item config_root cascade_toml_filename in
  let cascade = child_item config_root cascade_json_filename in
  let prompts = child_item config_root "prompts" in
  let keepers = child_item config_root "keepers" in
  let personas, persona_warnings = personas_item inputs config_root in
  let missing_child_warnings =
    (* RFC-0058 §9: [cascade.toml] is the SSOT; the [cascade.json] sibling
       is no longer read from disk.  Key the missing-child warning off the
       authoring file so a [.json]-only directory surfaces as degraded
       instead of silently passing as Ready. *)
    [ ("cascade.toml", cascade_authoring.exists)
    ; ("prompts", prompts.exists)
    ; ("keepers", keepers.exists)
    ; ("personas", personas.exists)
    ]
    |> List.filter_map (fun (label, exists) ->
           if exists then None
           else
             Some
               (Printf.sprintf "Resolved config child is missing: %s" label))
  in
  let degraded_legacy_json_warnings =
    (* Operator left a stale [cascade.json] in place after migrating off
       it.  We do not read it, but a present-but-unread file is a
       footgun; surface it as a warning so the dashboard / startup log
       call it out. *)
    if (not cascade_authoring.exists)
       && existing_file (Filename.concat config_root.path cascade_json_filename)
    then
      [ "Found cascade.json but no cascade.toml; cascade.json is no longer \
         read (RFC-0058 §9). Rename or convert it to cascade.toml." ]
    else []
  in
  let warnings =
    root_warnings @ persona_warnings @ missing_child_warnings
    @ degraded_legacy_json_warnings
  in
  let status =
    match config_root.source with
    | Invalid_env -> Invalid_env_status
    | Missing -> Missing_status
    | Env | Local_masc | Home_masc | Exe_relative | Cwd ->
        if warnings = [] then Ready else Warn
  in
  {
    status;
    warnings;
    config_root;
    cascade_authoring;
    cascade;
    prompts;
    keepers;
    personas;
  }

let _cached_resolution : resolution option ref = ref None

let resolve () =
  match !_cached_resolution with
  | Some r -> r
  | None ->
      let r = resolve_with (inputs_from_env ()) in
      _cached_resolution := Some r;
      r

let reset () =
  _cached_resolution := None

(* RFC-0058 §9: the on-disk cascade source is [cascade.toml]; the legacy
   [cascade.json] sibling is materialized in memory by
   [Cascade_toml_materializer] and never read from disk. Callers feed the
   returned path through that materializer, which accepts either suffix,
   so returning the [.toml] path is consistent with the actual source of
   truth. *)
let cascade_path_opt () =
  let resolution = resolve () in
  match resolution.config_root.source with
  | Env | Local_masc | Home_masc | Exe_relative | Cwd
    when resolution.cascade_authoring.exists ->
      Some resolution.cascade_authoring.path
  | Env | Local_masc | Home_masc | Exe_relative | Cwd
  | Invalid_env | Missing ->
      None

let cascade_path_candidate () =
  (resolve ()).cascade_authoring.path

let cascade_toml_path_candidate () =
  Filename.concat (resolve ()).config_root.path cascade_toml_filename

let prompts_dir () =
  (resolve ()).prompts.path

let keepers_dir () =
  (resolve ()).keepers.path

let personas_dir_opt () =
  let resolution = resolve () in
  match resolution.config_root.source with
  | Env | Local_masc | Home_masc | Exe_relative | Cwd
    when resolution.personas.exists ->
      Some resolution.personas.path
  | Env | Local_masc | Home_masc | Exe_relative | Cwd
  | Invalid_env | Missing ->
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
  let primary =
    match resolution.config_root.source with
    | Invalid_env | Missing -> []
    | Env | Local_masc | Home_masc | Exe_relative | Cwd ->
      if resolution.personas.exists then [ resolution.personas.path ] else []
  in
  let explicit_personas_dir_override = trim_opt inputs.env_personas_dir in
  (* Persona resolution is intentionally single-source:
     - MASC_PERSONAS_DIR when explicitly set
     - otherwise the resolved config root's personas/
     Hidden secondary searches (~/.masc/personas, $MASC_BASE_PATH/.masc/personas)
     make the dashboard/config panel lie about the actual source of truth. *)
  match explicit_personas_dir_override with
  | Some _ -> dedupe_paths primary
  | None -> dedupe_paths primary

let personas_dirs () =
  let resolution = resolve () in
  let inputs = inputs_from_env () in
  personas_dirs_with inputs resolution

let keeper_toml_path_opt name =
  let path = Filename.concat (keepers_dir ()) (name ^ ".toml") in
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
