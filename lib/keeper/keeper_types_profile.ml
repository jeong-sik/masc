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

let tool_result_ok ?(tool_name = "") body : tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time:(Time_compat.now ())
    ~data:(`String body)
    ()
;;

let tool_result_ok_data ?(tool_name = "") data : tool_result =
  Tool_result.make_ok
    ~tool_name
    ~start_time:(Time_compat.now ())
    ~data
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
    ~data:(`String body)
    body
;;

let tool_result_error_data
      ?(tool_name = "")
      ?(class_ = Tool_result.Runtime_failure)
      data
  : tool_result
  =
  Tool_result.make_err
    ~tool_name
    ~class_
    ~start_time:(Time_compat.now ())
    ~data
    (Yojson.Safe.to_string data)
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
    ]

let keeper_profile_defaults_materializable (defaults : keeper_profile_defaults) =
  let has_runtime_identity =
    Option.is_some defaults.persona_name
    || defaults.mention_targets <> []
  in
  match defaults.autoboot_enabled with
  | Some true -> true
  | Some false | None -> has_runtime_identity
;;

let keeper_toml_path_opt name =
  Config_dir_resolver.log_warnings ~context:"KeeperTypesProfile" ();
  Config_dir_resolver.keeper_toml_path_opt name

let keeper_toml_path_opt_for_base_path ~base_path name =
  Config_dir_resolver.keeper_toml_path_opt_for_base_path ~base_path name

let persona_load_error_to_profile_error
    ?keeper_path
    (error : Keeper_types_profile_persona_defaults.load_error) =
  let kind =
    match error.kind with
    | Keeper_types_profile_persona_defaults.Persona_read_error -> Read_error
    | Keeper_types_profile_persona_defaults.Persona_parse_error -> Parse_error
  in
  let keeper_path =
    match keeper_path with
    | Some keeper_path -> keeper_path
    | None -> error.path
  in
  { keeper_path
  ; failing_path = error.path
  ; kind
  ; detail = error.detail
  }

let load_keeper_profile_defaults_from_persona_dirs
    ?keeper_path
    ~persona_dirs
    name =
  Keeper_types_profile_persona_defaults.load_from_dirs ~persona_dirs ~name
  |> Result.map_error (persona_load_error_to_profile_error ?keeper_path)

let safe_persona_dirs ?base_path () =
  try
    match base_path with
    | Some base_path -> Config_dir_resolver.personas_dirs_for_base_path ~base_path
    | None -> Config_dir_resolver.personas_dirs ()
  with
  | Sys_error _ -> []
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:
          [ "site", Keeper_profile_load_failure_site.(to_label Personas_dirs_resolve) ]
        ();
      Log.Keeper.warn
        "profile defaults personas_dirs unexpected: %s"
        (Printexc.to_string exn);
      []

let resolved_persona_name ~keeper_name
    (defaults : keeper_profile_defaults) : string =
  match defaults.persona_name with
  | Some name when String.trim name <> "" -> name
  | _ -> keeper_name

let load_keeper_profile_defaults_result_uncached_with_paths
    ~keeper_toml_path_opt
    ~persona_dirs
    name :
    (keeper_profile_defaults, keeper_toml_load_error) result =
  (* Priority: TOML config/keepers/<name>.toml > persona profile.json.
     If TOML sets [persona_name], load that persona first and treat TOML as a
     thin overlay instead of duplicating the full keeper profile. *)
  let result =
    match keeper_toml_path_opt with
    | Some toml_path ->
      (match load_keeper_toml toml_path with
       | Ok (_name, defaults) -> (
           match defaults.persona_name with
           | Some persona_name ->
               (match
                  load_keeper_profile_defaults_from_persona_dirs
                    ~keeper_path:toml_path
                    ~persona_dirs
                    persona_name
                with
                | Error _ as error -> error
                | Ok persona_defaults ->
                  Ok
                    (merge_keeper_profile_defaults ~agent_name:name
                       ~base:persona_defaults ~overlay:defaults))
           | None -> Ok defaults)
       | Error e -> Error e)
    | None ->
      load_keeper_profile_defaults_from_persona_dirs ~persona_dirs name
  in
  result

let load_keeper_profile_defaults_result_uncached name :
    (keeper_profile_defaults, keeper_toml_load_error) result =
  load_keeper_profile_defaults_result_uncached_with_paths
    ~keeper_toml_path_opt:(keeper_toml_path_opt name)
    ~persona_dirs:(safe_persona_dirs ())
    name

let load_keeper_profile_defaults_result_for_base_path ~base_path name :
    (keeper_profile_defaults, keeper_toml_load_error) result =
  load_keeper_profile_defaults_result_uncached_with_paths
    ~keeper_toml_path_opt:(keeper_toml_path_opt_for_base_path ~base_path name)
    ~persona_dirs:(safe_persona_dirs ~base_path ())
    name

type keeper_toml_config_error = {
  keeper_name : string;
  keeper_path : string;
  failing_path : string;
  kind : keeper_toml_error_kind;
  detail : string;
}

type keeper_config_probe_error_kind =
  | Directory_resolution_error
  | Not_a_directory
  | Directory_read_error

type keeper_config_probe_error =
  { directory_path : string option
  ; kind : keeper_config_probe_error_kind
  ; detail : string
  }

type keeper_toml_unknown_keys = {
  keeper_name : string;
  path : string;
  unknown_keys : string list;
}

let keeper_toml_config_error_to_json
    ({ keeper_name; keeper_path; failing_path; kind; detail } :
      keeper_toml_config_error)
    : Yojson.Safe.t =
  `Assoc
    [
      ("keeper", `String keeper_name);
      ("keeper_path", `String keeper_path);
      ("failing_path", `String failing_path);
      ("kind", `String (keeper_toml_error_kind_to_string kind));
      ("detail", `String detail);
      ("terminal_reason", `String "config_invalid");
      ("severity", `String "error");
      ("blocking", `Bool true);
      ("operator_action_required", `Bool true);
      ("next_action", `String "fix_keeper_toml_config");
    ]

let keeper_config_probe_error_kind_to_string = function
  | Directory_resolution_error -> "directory_resolution_error"
  | Not_a_directory -> "not_a_directory"
  | Directory_read_error -> "directory_read_error"

let keeper_config_probe_error_to_json
    ({ directory_path; kind; detail } : keeper_config_probe_error)
    : Yojson.Safe.t =
  `Assoc
    [ ("directory_path", Json_util.string_opt_to_json directory_path)
    ; ("kind", `String (keeper_config_probe_error_kind_to_string kind))
    ; ("detail", `String detail)
    ; ("blocking", `Bool true)
    ; ("operator_action_required", `Bool true)
    ; ("next_action", `String "repair_keeper_config_directory")
    ]

let keeper_toml_config_error_of_load_error
    ~keeper_name
    (error : keeper_toml_load_error) =
  { keeper_name
  ; keeper_path = error.keeper_path
  ; failing_path = error.failing_path
  ; kind = error.kind
  ; detail = error.detail
  }

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
  match inspect_keeper_toml path with
  | Ok _ -> None
  | Error error ->
    Some
      (keeper_toml_config_error_of_load_error
         ~keeper_name:(keeper_name_of_toml_path path)
         error)

let keeper_toml_config_errors_in_dir_result dir =
  try
    if not (Fs_compat.file_exists dir)
    then Ok []
    else if not (Sys.is_directory dir)
    then
      Error
        { directory_path = Some dir
        ; kind = Not_a_directory
        ; detail = "keeper config path exists but is not a directory"
        }
    else
      match Safe_ops.list_dir_safe dir with
      | Error detail ->
        Error { directory_path = Some dir; kind = Directory_read_error; detail }
      | Ok files ->
        Ok
          (files
           |> List.filter (fun f -> Filename.check_suffix f ".toml")
           |> List.sort String.compare
           |> List.filter_map (fun f ->
                keeper_toml_config_error_of_path (Filename.concat dir f)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      { directory_path = Some dir
      ; kind = Directory_read_error
      ; detail = Printexc.to_string exn
      }

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

let keeper_toml_config_errors_result () =
  try keeper_toml_config_errors_in_dir_result (Config_dir_resolver.keepers_dir ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      { directory_path = None
      ; kind = Directory_resolution_error
      ; detail = Printexc.to_string exn
      }

let keeper_toml_unknown_keys () =
  keeper_toml_unknown_keys_in_dir (Config_dir_resolver.keepers_dir ())

(* Profile defaults cache — strict results are cached by source file
   fingerprint, not by keeper name alone. TOML/persona edits happen outside the
   process, so both Ok and Error entries must invalidate when their dependency
   mtimes/sizes change. *)
type profile_defaults_cache_key = string * string

type profile_defaults_cache_entry =
  { primary_toml_path : string option
  ; dependency_paths : string list
  ; dependency_fingerprint : string
  ; result : (keeper_profile_defaults, keeper_toml_load_error) result
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
      Otel_metric_store.inc_counter
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
    (result : (keeper_profile_defaults, keeper_toml_load_error) result) =
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
    | Some _, Error error -> keeper_toml_load_error_paths error
    | None, _ -> persona_profile_candidate_paths name
  in
  dedupe_keep_order paths

let load_keeper_profile_defaults_result name :
    (keeper_profile_defaults, keeper_toml_load_error) result =
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

let keeper_profile_defaults_materializable_for_name ?base_path name =
  try
    let defaults_result =
      match base_path with
      | Some base_path ->
        load_keeper_profile_defaults_result_for_base_path ~base_path name
      | None -> load_keeper_profile_defaults_result name
    in
    (match defaults_result with
     | Ok defaults -> keeper_profile_defaults_materializable defaults
     | Error error ->
       Log.Keeper.warn
         "profile materializable check for %s blocked by invalid config: %s"
         name
         (keeper_toml_load_error_to_string error);
       false)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string ProfileLoadFailures)
        ~labels:
          [
            ( "site",
              Keeper_profile_load_failure_site.(to_label Materializable_check) );
          ]
        ();
      let base_path_detail =
        match base_path with
        | Some base_path -> Printf.sprintf " base_path=%s" base_path
        | None -> ""
      in
      Log.Keeper.warn
        "profile materializable check for %s failed%s: %s"
        name
        base_path_detail
        (Printexc.to_string exn);
      false

type keeper_default_source_snapshot = {
  source_kind : string option;
  defaults : keeper_profile_defaults;
  config_error : keeper_toml_load_error option;
}

let keeper_default_source_snapshot ~base_path name : keeper_default_source_snapshot =
  match keeper_toml_path_opt_for_base_path ~base_path name with
  | Some toml_path -> (
      match load_keeper_toml toml_path with
      | Ok (_name, defaults) ->
          { source_kind = Some "toml"; defaults; config_error = None }
      | Error e ->
          Log.Keeper.warn
            "toml config for %s failed (%s); no declarative defaults projected"
            name
            (keeper_toml_load_error_to_string e);
          { source_kind = None
          ; defaults = empty_keeper_profile_defaults
          ; config_error = Some e
          })
  | None ->
      (match
         load_keeper_profile_defaults_from_persona_dirs
           ~persona_dirs:(safe_persona_dirs ~base_path ())
           name
       with
       | Error config_error ->
         { source_kind = None
         ; defaults = empty_keeper_profile_defaults
         ; config_error = Some config_error
         }
       | Ok defaults ->
         let source_kind =
           if Option.is_some defaults.manifest_path then Some "persona" else None
         in
         { source_kind; defaults; config_error = None })

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
