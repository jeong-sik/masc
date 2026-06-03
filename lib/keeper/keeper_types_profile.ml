(** Keeper_types_profile — keeper profile defaults, persona loading,
    and directory path helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency).

    TOML parsing, loading, and merging live in
    [Keeper_types_profile_toml] (included below). *)

include Keeper_config
let keeper_debug = Env_config.KeeperRuntime.debug

include Keeper_types_profile_sandbox

type 'a context = {
  config: Workspace.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net: [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type tool_result = Tool_result.result

let tool_result_payload body =
  match Tool_result.structured_payload_of_message body with
  | Some json -> json
  | None -> `String body
;;

let tool_result_ok ?(tool_name = "") body : tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time:(Time_compat.now ())
    ~data:(tool_result_payload body)
    ()
;;

let tool_result_error
      ?(tool_name = "")
      ?(class_ = Tool_result.Runtime_failure)
      body
  : tool_result
  =
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time:(Time_compat.now ())
    ~data:(tool_result_payload body)
    body
;;

let tool_result_with_tool_name ~tool_name : tool_result -> tool_result = function
  | Ok payload -> Ok { payload with tool_name }
  | Error payload -> Error { payload with tool_name }
;;

let tool_result_body = Tool_result.message
let tool_result_success = Tool_result.is_success

let schemas = Keeper_schema.schemas

(* Configuration: see Keeper_config *)
include Keeper_config

let short_preview ?(max_len = 220) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else String_util.utf8_prefix ~max_bytes:max_len s ^ "..."

let take = List.take

(* Delegated to Keeper_fs — single fiber-safe ensure_dir implementation. *)
let ensure_dir = Keeper_fs.ensure_dir

(* ── TOML parsing, normalizers, merge, discover ──────────────────── *)
include Keeper_types_profile_toml

(* ── Persona defaults loading ──────────────────────────────────────────── *)

let load_persona_defaults ~name : keeper_profile_defaults option =
  let persona_dir_opt () =
    try
      Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
      Config_dir_resolver.personas_dir_opt ()
    with
    | Sys_error _ -> None
    | exn ->
      Log.Keeper.warn
        "load_persona_defaults personas_dir_opt unexpected: %s"
        (Printexc.to_string exn);
      None
  in
  match persona_dir_opt () with
  | None -> None
  | Some root ->
      let profile_path =
        Filename.concat (Filename.concat root name) "profile.json"
      in
      if not (Fs_compat.file_exists profile_path)
      then None
      else
        (match
           Safe_ops.read_json_file_logged ~label:"load_persona_defaults" profile_path
         with
         | None -> None
         | Some json ->
             let instructions =
               let agent_md_path =
                 Filename.concat (Filename.concat root name) "AGENT.md"
               in
               if Fs_compat.file_exists agent_md_path
               then
                 (match Safe_ops.read_file_safe agent_md_path with
                  | Error _ -> None
                  | Ok content ->
                      let trimmed = String.trim content in
                      if String.length trimmed = 0 then None else Some trimmed)
               else None
             in
             let keeper_json = Json_util.assoc_member_opt "keeper" json in
             let keeper_str key =
               match keeper_json with
               | Some (`Assoc fields) ->
                 (match List.assoc_opt key fields with
                  | Some (`String s) -> Some s
                  | _ -> None)
               | _ -> None
             in
             Some
               {
                 empty_keeper_profile_defaults with
                 persona_name = Some name;
                 instructions;
                 will = keeper_str "will";
                 needs = keeper_str "needs";
                 desires = keeper_str "desires";
                 social_model = keeper_str "social_model";
               })
;;

(* ── Runtime defaults loading ──────────────────────────────────────────── *)

let load_runtime_defaults ~name : keeper_profile_defaults option =
  let runtime_dir_opt () =
    try
      Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
      match Config_dir_resolver.current_env_config_dir_opt () with
      | None -> None
      | Some dir -> Some (Filename.concat dir "runtimes")
    with
    | Sys_error _ -> None
    | exn ->
      Log.Keeper.warn
        "load_runtime_defaults runtime_dir_opt unexpected: %s"
        (Printexc.to_string exn);
      None
  in
  match runtime_dir_opt () with
  | None -> None
  | Some root ->
      let path = Filename.concat root (name ^ ".json") in
      if not (Fs_compat.file_exists path)
      then None
      else
        (match
           Safe_ops.read_json_file_logged ~label:"load_runtime_defaults" path
         with
         | None -> None
         | Some json ->
             let bool_ key = Safe_ops.json_bool_opt key json in
             let int_ key = Safe_ops.json_int_opt key json in
             let str key = Safe_ops.json_string_opt key json in
             let strs key =
               match Safe_ops.json_string_list key json with
               | [] -> None
               | xs -> Some xs
             in
             Some
               {
                 empty_keeper_profile_defaults with
                 sandbox_profile =
                   Option.bind (str "sandbox_profile") sandbox_profile_of_string;
                 sandbox_image = str "sandbox_image";
                 network_mode =
                   Option.bind (str "network_mode") network_mode_of_string;
                 tool_access = strs "tool_access";
                 tool_denylist = strs "tool_denylist";
                 proactive_enabled = bool_ "proactive_enabled";
                 proactive_idle_sec = int_ "proactive_idle_sec";
                 proactive_cooldown_sec = int_ "proactive_cooldown_sec";
                 max_turns_per_call = int_ "max_turns_per_call";
                 max_turns_per_call_scheduled_autonomous =
                   int_ "max_turns_per_call_scheduled_autonomous";
                 always_approve = bool_ "always_approve";
                 autoboot_enabled = bool_ "autoboot_enabled";
                 shards = strs "shards";
                 allowed_paths = strs "allowed_paths";
               })
;;

(* ── JSON workspace-seq helpers ───────────────────────────────────────── *)

let workspace_seq_map_to_json (items : (string * int) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (workspace_id, seq) -> (workspace_id, `Int seq)) items)

let workspace_seq_map_of_json (json : Yojson.Safe.t) : (string * int) list =
  match json with
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (workspace_id, value) ->
             if not (validate_name workspace_id) then
               None
             else
               match value with
               | `Int seq -> Some (workspace_id, seq)
               | `Intlit raw ->
                   Some (workspace_id, Safe_ops.int_of_string_with_default ~default:0 raw)
               | _ -> None)
  | _ -> []


include Keeper_types_profile_defaults

type persona_summary = Keeper_types_profile_persona.persona_summary =
  { persona_name : string
  ; display_name : string
  ; role : string option
  ; trait : string option
  ; profile_path : string
  ; has_keeper_defaults : bool
  }

let operator_todo_placeholder_marker =
  Keeper_types_profile_persona.operator_todo_placeholder_marker
;;

let string_has_operator_todo_placeholder =
  Keeper_types_profile_persona.string_has_operator_todo_placeholder
;;

let json_has_operator_todo_placeholder =
  Keeper_types_profile_persona.json_has_operator_todo_placeholder
;;

let json_operator_todo_placeholder_paths =
  Keeper_types_profile_persona.json_operator_todo_placeholder_paths
;;

let reject_placeholder_persona_profile =
  Keeper_types_profile_persona.reject_placeholder_persona_profile
;;

let operator_todo_placeholder_fields =
  Keeper_types_profile_persona.operator_todo_placeholder_fields

let persona_operator_todo_placeholder_fields
    (summary : persona_summary)
    (defaults : keeper_profile_defaults) =
  operator_todo_placeholder_fields
    [
      ("name", Some summary.display_name);
      ("role", summary.role);
      ("trait", summary.trait);
      ("keeper.goal", defaults.goal);
      ("keeper.short_goal", defaults.short_goal);
      ("keeper.mid_goal", defaults.mid_goal);
      ("keeper.long_goal", defaults.long_goal);
      ("keeper.will", defaults.will);
      ("keeper.needs", defaults.needs);
      ("keeper.desires", defaults.desires);
      ("keeper.instructions", defaults.instructions);
    ]

let keeper_toml_path_opt name =
  Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
  Config_dir_resolver.keeper_toml_path_opt name

let load_keeper_profile_defaults_from_persona name : keeper_profile_defaults =
  match persona_profile_path_opt name with
  | None -> empty_keeper_profile_defaults
  | Some path -> (
      match Safe_ops.read_json_file_logged ~label:"load_keeper_profile_defaults" path with
      | None -> empty_keeper_profile_defaults
      | Some json ->
          if
            reject_placeholder_persona_profile
              ~label:"load_keeper_profile_defaults" ~path json
          then empty_keeper_profile_defaults
          else
          let keeper_json =
            match Json_util.assoc_member_opt "keeper" json with
            | Some v -> v
            | None -> `Null
          in
          let per_provider_timeout_state, per_provider_timeout =
            per_provider_timeout_of_json_field
              ~source:(Printf.sprintf "persona profile %s" path)
              ~field:"per_provider_timeout"
              keeper_json
          in
          (* persona⊥{model,runtime}: persona profiles do not own a
             runtime/model selection — that lives in runtime.toml
             ([[runtime.assignments]]), keyed by keeper name.  A [model] key in
             persona JSON is ignored (mirrors the keeper TOML parser, which
             rejects [keeper.model]).  Warn so an operator sees the stale key is
             no longer honored. *)
          (match Safe_ops.json_string_opt "model" keeper_json with
           | Some raw ->
               Log.Keeper.warn
                 "persona profile %s has a [model] key (%s); ignored — \
                  keeper->runtime assignment lives in \
                  runtime.toml [[runtime.assignments]]"
                 path raw
           | None -> ());
          match keeper_json with
          | `Assoc _ ->
              let base_defaults =
                {
                  id = Some (Ids.Keeper_id.generate ~name ~path);
                  manifest_path = Some path;
                  persona_name = Some name;
                  goal = Safe_ops.json_string_opt "goal" keeper_json;
                  short_goal =
                    normalize_goal_horizon_opt
                      (Safe_ops.json_string_opt "short_goal" keeper_json);
                  mid_goal =
                    normalize_goal_horizon_opt
                      (Safe_ops.json_string_opt "mid_goal" keeper_json);
                  long_goal =
                    normalize_goal_horizon_opt
                      (Safe_ops.json_string_opt "long_goal" keeper_json);
                  will = Safe_ops.json_string_opt "will" keeper_json;
                  needs = Safe_ops.json_string_opt "needs" keeper_json;
                  desires = Safe_ops.json_string_opt "desires" keeper_json;
                  instructions = Safe_ops.json_string_opt "instructions" keeper_json;
                  autoboot_enabled = None;
                  mention_targets = Safe_ops.json_string_list "mention_targets" keeper_json;
                  proactive_enabled = Safe_ops.json_bool_opt "proactive_enabled" keeper_json;
                  proactive_idle_sec = Safe_ops.json_int_opt "proactive_idle_sec" keeper_json;
                  proactive_cooldown_sec = Safe_ops.json_int_opt "proactive_cooldown_sec" keeper_json;
                  shards =
                    (match Safe_ops.json_string_list "shards" keeper_json with
                     | [] -> None
                     | xs -> Some xs);
                  (* Persona profiles are not allowed to own execution allowlists.
                     Keep these in keeper TOML / runtime config only. *)
                  allowed_paths = None;
                  sandbox_profile = None;
                  sandbox_image = None;
                  network_mode = None;
                  tool_access = None;
                  tool_denylist =
                    normalize_name_list_opt
                      (Safe_ops.json_string_list "tool_denylist" keeper_json);
                  active_goal_ids = None;
                  telemetry_feedback_enabled =
                    Safe_ops.json_bool_opt "telemetry_feedback_enabled" keeper_json;
                  telemetry_feedback_window_hours =
                    Safe_ops.json_int_opt "telemetry_feedback_window_hours" keeper_json;
                  per_provider_timeout_state;
                  per_provider_timeout;
                  always_approve =
                    Safe_ops.json_bool_opt "always_approve" keeper_json;
                  max_turns_per_call =
                    Safe_ops.json_int_opt "max_turns_per_call" keeper_json;
                  max_turns_per_call_scheduled_autonomous =
                    Safe_ops.json_int_opt
                      "max_turns_per_call_scheduled_autonomous" keeper_json;
                  social_model =
                    (match
                       normalize_social_model_opt
                         (Safe_ops.json_string_opt "social_model" keeper_json)
                     with
                    | Some _ as normalized -> normalized
                    | None -> (
                        match
                          Safe_ops.json_string_opt "social_model" keeper_json
                        with
                        | Some raw ->
                            Log.Keeper.warn
                              "persona profile %s has invalid social_model '%s'; ignoring"
                              path raw;
                            None
                        | None -> None));
                  (* oas_env lives only in keeper TOML, not persona JSON —
                     persona profiles are a design-time artifact whereas
                     transport env is an ops-time toggle. *)
                  oas_env = [];
                  (* Persona JSON has no [keeper] TOML; nothing to flag. *)
                  unknown_toml_keys = [];
                  persona_ref = Safe_ops.json_string_opt "persona_ref" keeper_json;
                  runtime_ref = Safe_ops.json_string_opt "runtime_ref" keeper_json;
                }
              in
              begin
                match base_defaults.persona_ref with
                | None -> base_defaults
                | Some persona_name ->
                    match load_persona_defaults ~name:persona_name with
                    | None -> base_defaults
                    | Some persona_defaults ->
                        merge_keeper_profile_defaults
                          ~agent_name:""
                          ~base:persona_defaults
                          ~overlay:base_defaults
              end
          | _ -> { empty_keeper_profile_defaults with manifest_path = Some path })


let resolved_persona_name ~keeper_name
    (defaults : keeper_profile_defaults) : string =
  match defaults.persona_name with
  | Some name when String.trim name <> "" -> name
  | _ -> keeper_name

let load_keeper_profile_defaults_result_uncached name :
    (keeper_profile_defaults, string) result =
  (* Priority: TOML config/keepers/<name>.toml > persona profile.json.
     If TOML sets [persona_name], load that persona first and treat TOML as a
     thin overlay instead of duplicating the full keeper profile. *)
  let result =
    match keeper_toml_path_opt name with
    | Some toml_path ->
      (match load_keeper_toml toml_path with
       | Ok (_name, defaults) -> (
           match defaults.persona_name with
           | Some persona_name ->
               let persona_defaults =
                 load_keeper_profile_defaults_from_persona persona_name
               in
               Ok
                 (merge_keeper_profile_defaults ~agent_name:name
                    ~base:persona_defaults ~overlay:defaults)
           | None -> Ok defaults)
       | Error e -> Error e)
    | None ->
      Ok (load_keeper_profile_defaults_from_persona name)
  in
  (* Runtime overlay: if the resolved config has runtime_ref, load the
     runtime file and merge it as base (keeper config wins on conflict). *)
  match result with
  | Error _ -> result
  | Ok defaults ->
      match defaults.runtime_ref with
      | None -> result
      | Some runtime_name ->
          match load_runtime_defaults ~name:runtime_name with
          | None -> result
          | Some runtime_defaults ->
              Ok
                (merge_keeper_profile_defaults ~agent_name:name
                   ~base:runtime_defaults ~overlay:defaults)

(* Classify a [load_keeper_toml] failure message into a low-cardinality
   label suitable for Prometheus. The raw error string embeds user input
   (invalid enum values etc.) and would blow up metric cardinality. *)
let classify_toml_failure_reason (err : string) : string =
  let err_lc = String.lowercase_ascii err in
  let contains needle =
    let nl = String.length needle in
    let hl = String.length err_lc in
    if nl = 0 then true
    else if nl > hl then false
    else
      let rec loop i =
        if i + nl > hl then false
        else if String.sub err_lc i nl = needle then true
        else loop (i + 1)
      in
      loop 0
  in
  if contains "invalid network_mode" then "invalid_network_mode"
  else if contains "invalid sandbox_profile" then "invalid_sandbox_profile"
    else if contains "invalid" then "invalid_enum"
  else if contains "unknown" || contains "unexpected field" then "unknown_field"
  else if contains "parse" || contains "syntax" || contains "expected" then
    "parse_error"
  else "other"

type keeper_toml_config_error = {
  keeper_name : string;
  path : string;
  error : string;
  reason : string;
}

type keeper_toml_unknown_keys = {
  keeper_name : string;
  path : string;
  unknown_keys : string list;
}

let keeper_toml_config_error_to_json
    ({ keeper_name; path; error; reason } : keeper_toml_config_error)
    : Yojson.Safe.t =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("path", `String path);
      ("reason", `String reason);
      ("error", `String error);
      ("terminal_reason", `String "config_parse_failed");
      ("severity", `String "error");
      ("blocking", `Bool true);
      ("operator_action_required", `Bool true);
      ("next_action", `String "fix_keeper_toml_config");
    ]

let keeper_toml_unknown_keys_to_json
    ({ keeper_name; path; unknown_keys } : keeper_toml_unknown_keys)
    : Yojson.Safe.t =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("path", `String path);
      ("unknown_key_count", `Int (List.length unknown_keys));
      ("unknown_keys", `List (List.map (fun key -> `String key) unknown_keys));
      ("terminal_reason", `String "config_unknown_keys");
      ("severity", `String "error");
      ("blocking", `Bool true);
      ("operator_action_required", `Bool true);
      ("next_action", `String "remove_unknown_keeper_toml_keys");
    ]

let keeper_name_of_toml_path path =
  Filename.basename path |> Filename.remove_extension

let keeper_toml_unknown_keys_of_path path =
  match Safe_ops.read_file_safe path with
  | Error _ -> None
  | Ok content -> (
      match Keeper_toml_loader.parse_toml content with
      | Error _ -> None
      | Ok doc -> (
          match detect_unknown_keeper_toml_keys doc with
          | [] -> None
          | unknown_keys ->
              Some
                {
                  keeper_name = keeper_name_of_toml_path path;
                  path;
                  unknown_keys = normalize_unknown_keeper_toml_keys unknown_keys;
                }))

let keeper_toml_config_error_of_path path =
  let error =
    match Safe_ops.read_file_safe path with
    | Error e -> Some (Printf.sprintf "cannot read %s: %s" path e)
    | Ok content -> (
        match Keeper_toml_loader.parse_toml content with
        | Error e -> Some (Printf.sprintf "%s: %s" path e)
        | Ok doc -> (
            match profile_defaults_of_toml doc with
            | Error e -> Some (Printf.sprintf "%s: %s" path e)
            | Ok _ -> (
                match Keeper_toml_loader.toml_string_opt doc "keeper.name" with
                | Some name when name <> "" && not (validate_name name) ->
                    Some (Printf.sprintf "%s: invalid keeper name '%s'" path name)
                | _ -> None)))
  in
  match error with
  | None -> None
  | Some error ->
      Some
        {
          keeper_name = keeper_name_of_toml_path path;
          path;
          error;
          reason = classify_toml_failure_reason error;
        }

let keeper_toml_config_errors_in_dir dir =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.filter_map (fun f ->
         keeper_toml_config_error_of_path (Filename.concat dir f))

let keeper_toml_unknown_keys_in_dir dir =
  if not (Fs_compat.file_exists dir && Sys.is_directory dir) then []
  else
    dir
    |> Sys.readdir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.sort String.compare
    |> List.filter_map (fun f ->
         keeper_toml_unknown_keys_of_path (Filename.concat dir f))

let keeper_toml_config_errors () =
  keeper_toml_config_errors_in_dir (Config_dir_resolver.keepers_dir ())

let keeper_toml_unknown_keys () =
  keeper_toml_unknown_keys_in_dir (Config_dir_resolver.keepers_dir ())

let keeper_toml_config_errors_json () =
  `List (List.map keeper_toml_config_error_to_json (keeper_toml_config_errors ()))

let keeper_toml_config_error_for_name name =
  match keeper_toml_path_opt name with
  | None -> None
  | Some path -> keeper_toml_config_error_of_path path

(* Profile defaults cache — strict results are cached by source file
   fingerprint, not by keeper name alone. TOML/persona edits happen outside the
   process, so both Ok and Error entries must invalidate when their dependency
   mtimes/sizes change. *)
type profile_defaults_cache_key = string * string

type profile_defaults_cache_entry =
  { primary_toml_path : string option
  ; dependency_paths : string list
  ; dependency_fingerprint : string
  ; result : (keeper_profile_defaults, string) result
  }

let profile_defaults_cache : (profile_defaults_cache_key, profile_defaults_cache_entry) Hashtbl.t =
  Hashtbl.create 32
let profile_defaults_mu = Stdlib.Mutex.create ()

let profile_cache_scope () =
  try
    let resolution = Config_dir_resolver.resolve () in
    String.concat "|"
      [ resolution.config_root.path; resolution.personas.path ]
  with
  | exn ->
    (* resolver failure fallback uses env only as a cache-key salt;
       profile parsing remains explicit and the cache miss path revalidates
       file fingerprints before returning a cached result. NDT-OK *)
    String.concat "|"
      [
        Option.value ~default:"" (Sys.getenv_opt "MASC_CONFIG_DIR");
        (* NDT-OK: same cache-key salt fallback as MASC_CONFIG_DIR above. *)
        Option.value ~default:"" (Sys.getenv_opt "MASC_PERSONAS_DIR");
        Printexc.to_string exn;
      ]

let profile_defaults_cache_key name = (profile_cache_scope (), name)

let same_string_opt a b =
  match a, b with
  | None, None -> true
  | Some a, Some b -> String.equal a b
  | _ -> false

let file_fingerprint path =
  match Fs_compat.file_mtime path, Fs_compat.file_size path with
  | Some mtime, Some size -> Printf.sprintf "%s:%.6f:%d" path mtime size
  | Some mtime, None -> Printf.sprintf "%s:%.6f:?" path mtime
  | None, Some size -> Printf.sprintf "%s:missing:%d" path size
  | None, None -> path ^ ":missing"

let dependency_fingerprint paths =
  paths |> List.map file_fingerprint |> String.concat "|"

let persona_profile_candidate_paths name =
  let dirs =
    try Config_dir_resolver.personas_dirs () with
    | Sys_error _ -> []
    | exn ->
      Prometheus.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:[ "site", Keeper_profile_load_failure_site.(to_label Personas_dirs_resolve) ]
        ();
      Log.Keeper.warn
        "profile cache personas_dirs unexpected: %s"
        (Printexc.to_string exn);
      []
  in
  dirs
  |> List.map (fun root ->
       Filename.concat (Filename.concat root name) "profile.json")

let profile_dependency_paths ~name ~primary_toml_path
    (result : (keeper_profile_defaults, string) result) =
  let paths =
    match primary_toml_path, result with
    | Some toml_path, Ok defaults ->
      let persona_paths =
        match defaults.persona_name with
        | Some persona_name when String.trim persona_name <> "" ->
          persona_profile_candidate_paths persona_name
        | _ -> []
      in
      toml_path :: persona_paths
    | Some toml_path, Error _ -> [ toml_path ]
    | None, _ -> persona_profile_candidate_paths name
  in
  dedupe_keep_order paths

let load_keeper_profile_defaults_result name :
    (keeper_profile_defaults, string) result =
  let primary_toml_path = keeper_toml_path_opt name in
  let key = profile_defaults_cache_key name in
  let cached =
    Stdlib.Mutex.lock profile_defaults_mu;
    let value = Hashtbl.find_opt profile_defaults_cache key in
    Stdlib.Mutex.unlock profile_defaults_mu;
    value
  in
  match cached with
  | Some entry
    when same_string_opt entry.primary_toml_path primary_toml_path
         && String.equal entry.dependency_fingerprint
              (dependency_fingerprint entry.dependency_paths) ->
    entry.result
  | _ ->
    let result = load_keeper_profile_defaults_result_uncached name in
    let dependency_paths =
      profile_dependency_paths ~name ~primary_toml_path result
    in
    let entry =
      { primary_toml_path
      ; dependency_paths
      ; dependency_fingerprint = dependency_fingerprint dependency_paths
      ; result
      }
    in
    Stdlib.Mutex.lock profile_defaults_mu;
    Hashtbl.replace profile_defaults_cache key entry;
    Stdlib.Mutex.unlock profile_defaults_mu;
    result

let invalidate_keeper_profile_defaults_cache name =
  let key = profile_defaults_cache_key name in
  Stdlib.Mutex.lock profile_defaults_mu;
  Hashtbl.remove profile_defaults_cache key;
  Stdlib.Mutex.unlock profile_defaults_mu

let load_keeper_profile_defaults name : keeper_profile_defaults =
  match load_keeper_profile_defaults_result name with
  | Ok defaults -> defaults
  | Error e ->
    (match keeper_toml_path_opt name with
     | Some _ ->
       Log.Keeper.warn "toml config for %s failed (%s), falling back to persona" name e;
       Prometheus.inc_counter Keeper_metrics.(to_string TomlInvalid)
         ~labels:[ ("keeper", name); ("reason", classify_toml_failure_reason e) ]
         ()
     | None -> ());
    load_keeper_profile_defaults_from_persona name

(** Clamp a profile-provided max-turns override to [1, 100] — the same range
    enforced by [Keeper_runtime_resolved.reactive_max_turns_per_call].
    Values outside the range are rejected so a typo in TOML cannot silently
    bypass the budget envelope. *)
let clamp_max_turns_override : int option -> int option = function
  | Some n
    when n >= Keeper_runtime_resolved.max_turns_per_call_min
      && n <= Keeper_runtime_resolved.max_turns_per_call_max ->
    Some n
  | _ -> None

let effective_max_turns_per_call (profile : keeper_profile_defaults) : int =
  match clamp_max_turns_override profile.max_turns_per_call with
  | Some n -> n
  | None -> Keeper_runtime_resolved.reactive_max_turns_per_call ()

let effective_max_turns_per_call_scheduled_autonomous
    (profile : keeper_profile_defaults) : int =
  let global_cap = Keeper_runtime_resolved.reactive_max_turns_per_call () in
  match clamp_max_turns_override profile.max_turns_per_call_scheduled_autonomous with
  | Some n -> min n global_cap
  | None ->
    Keeper_runtime_resolved.autonomous_max_turns_per_call ()

type keeper_default_source_snapshot = {
  source_kind : string option;
  defaults : keeper_profile_defaults;
}

let keeper_default_source_snapshot name : keeper_default_source_snapshot =
  match keeper_toml_path_opt name with
  | Some toml_path -> (
      match load_keeper_toml toml_path with
      | Ok (_name, defaults) ->
          { source_kind = Some "toml"; defaults }
      | Error e ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string ProfileLoadFailures)
            ~labels:[("site", Keeper_profile_load_failure_site.(to_label Toml_fallback))]
            ();
          Log.Keeper.warn
            "toml config for %s failed (%s), falling back to persona"
            name e;
          let defaults = load_keeper_profile_defaults_from_persona name in
          let source_kind =
            if Option.is_some defaults.manifest_path then Some "persona" else None
          in
          { source_kind; defaults })
  | None ->
      let defaults = load_keeper_profile_defaults_from_persona name in
      let source_kind =
        if Option.is_some defaults.manifest_path then Some "persona" else None
      in
      { source_kind; defaults }

let persona_description_max_chars =
  Keeper_types_profile_persona.persona_description_max_chars
;;

let load_persona_extended = Keeper_types_profile_persona.load_persona_extended
let load_persona_summary = Keeper_types_profile_persona.load_persona_summary

let load_persona_summary_from_path =
  Keeper_types_profile_persona.load_persona_summary_from_path
;;

let list_persona_summaries = Keeper_types_profile_persona.list_persona_summaries

let keeper_dir (config : Workspace.config) =
  let d = Workspace.keepers_runtime_dir config in
  ensure_dir d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Workspace.config) =
  let d = Filename.concat (Workspace.masc_root_dir config) "traces" in
  ensure_dir d
