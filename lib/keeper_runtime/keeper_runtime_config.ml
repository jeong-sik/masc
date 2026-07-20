(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].  See [.mli] for design. *)

(* TOML key → env var name. Startup-scoped runtime knobs map here so
   that TOML is the SSOT and env vars become CI/test overrides.
   Keys owned by another runtime.toml parser are ignored by this layer.
   Removed Keeper runtime keys are rejected explicitly below. *)
let key_path_to_env =
  [
    (* [bootstrap] *)
    [ "bootstrap"; "enabled" ], "MASC_KEEPER_BOOTSTRAP_ENABLED";
    [ "bootstrap"; "stale_turn_sec" ], "MASC_KEEPER_BOOTSTRAP_STALE_TURN_SEC";
    [ "bootstrap"; "max_scan" ], "MASC_KEEPER_BOOTSTRAP_MAX_SCAN";
    (* [autonomous] *)
    (* RFC-0297 P0-1: global lifecycle kill-switches. Without these mappings
       the [reactive]/[proactive]/[autonomous] enabled keys were silently
       dropped (see load_and_apply — only known key_to_env keys are visited). *)
    [ "autonomous"; "enabled" ], "MASC_KEEPER_AUTONOMOUS_ENABLED";
    (* [reactive] *)
    [ "reactive"; "enabled" ], "MASC_KEEPER_REACTIVE_ENABLED";
    (* [heartbeat] *)
    [ "heartbeat"; "interval_sec" ], "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC";
    [ "heartbeat"; "snapshot_sec" ], "MASC_KEEPER_SNAPSHOT_SEC";
    [ "heartbeat"; "work_as_heartbeat" ], "MASC_KEEPER_WORK_AS_HEARTBEAT";
    [ "heartbeat"; "sleep_chunk_sec" ], "MASC_KEEPER_SLEEP_CHUNK_SEC";
    [ "heartbeat"; "board_wakeup_max" ], "MASC_KEEPER_BOARD_WAKEUP_MAX";
    (* [health] *)
    [ "health"; "durable_queue_stale_sec" ], "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC";
    (* [wire_capture] *)
    [ "wire_capture"; "enabled" ], "MASC_KEEPER_WIRE_CAPTURE";
    (* [proactive] *)
    [ "proactive"; "enabled" ], "MASC_KEEPER_PROACTIVE_ENABLED";
    (* [turn] *)
    [ "turn"; "stream_idle_timeout_sec" ], "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC";
    [ "turn"; "cli_subprocess_idle_sec" ], "MASC_KEEPER_CLI_SUBPROCESS_IDLE_SEC";
    [ "turn"; "temperature" ], "MASC_KEEPER_UNIFIED_TEMP";
    [ "turn"; "enable_thinking" ], "MASC_KEEPER_ENABLE_THINKING";
    (* [supervisor] *)
    [ "supervisor"; "sweep_sec" ], "MASC_KEEPER_SUPERVISOR_SWEEP_SEC";
    (* [lifecycle] *)
    [ "lifecycle"; "dead_ttl_sec" ], "MASC_KEEPER_DEAD_TTL_SEC";
    (* [metrics] *)
    [ "metrics"; "max_bytes" ], "MASC_KEEPER_METRICS_MAX_BYTES";
    [ "metrics"; "max_rotated" ], "MASC_KEEPER_METRICS_MAX_ROTATED";
    (* [memory] *)
    [ "memory"; "max_notes" ], "MASC_KEEPER_MEMORY_MAX_NOTES";
    [ "memory"; "compact_trigger_bytes" ], "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES";
    [ "memory"; "max_length" ], "MASC_KEEPER_MEMORY_MAX_LENGTH";
    [ "memory"; "placeholders" ], "MASC_KEEPER_MEMORY_PLACEHOLDERS";
    [ "memory"; "consensus_pattern" ], "MASC_KEEPER_MEMORY_CONSENSUS_PATTERN";
    [ "memory"; "llm_summary" ], "MASC_KEEPER_MEMORY_LLM_SUMMARY";
    (* [web_search] *)
    [ "web_search"; "searxng_url" ], "MASC_SEARXNG_URL";
    [ "web_search"; "provider" ], "MASC_WEB_SEARCH_PROVIDER";
    [ "web_search"; "provider_order" ], "MASC_WEB_SEARCH_PROVIDER_ORDER";
    [ "web_search"; "fallbacks" ], "MASC_WEB_SEARCH_FALLBACKS";
    [ "web_search"; "timeout_sec" ], "MASC_WEB_SEARCH_TIMEOUT_SEC";
    [ "web_search"; "cache_ttl_sec" ], "MASC_WEB_SEARCH_CACHE_TTL_SEC";
    (* [debug] *)
    [ "debug"; "enabled" ], "MASC_KEEPER_DEBUG";
  ]

let removed_key_paths =
  [ [ "bootstrap"; "autoboot_max" ]
  ; [ "autonomous"; "fairness_cooldown_sec" ]
  ; [ "heartbeat"; "max_silence_sec" ]
  ; [ "turn"; "capacity_limit" ]
  ; [ "turn"; "batch_limit" ]
  ; [ "turn"; "max_output_tokens" ]
  ]

let top_level_table = function
  | table :: _ when table <> "" -> table
  | _ -> invalid_arg "Keeper_runtime_config: empty TOML key path"

let key_to_env =
  List.map
    (fun (path, env_name) -> String.concat "." path, env_name)
    key_path_to_env

let owned_table_names =
  (List.map (fun (path, _) -> top_level_table path) key_path_to_env
   @ List.map top_level_table removed_key_paths)
  |> List.sort_uniq String.compare

let removed_key_names = List.map (String.concat ".") removed_key_paths
let live_key_names = List.map fst key_to_env

let flat_key_path key = String.split_on_char '.' key

let validate_owned_keys (doc : Keeper_toml_loader.toml_doc) =
  let unknown =
    doc
    |> List.filter_map (fun (key, _) ->
      match flat_key_path key with
      | table :: _
        when List.mem table owned_table_names
             && not (List.mem key live_key_names)
             && not (List.mem key removed_key_names) ->
        Some key
      | _ -> None)
  in
  match unknown with
  | [] -> Ok ()
  | keys ->
    Error
      (Printf.sprintf
         "unknown Keeper runtime TOML keys: %s"
         (String.concat ", " keys))

let validate_removed_keys (doc : Keeper_toml_loader.toml_doc) =
  let present = List.filter (fun key -> List.mem_assoc key doc) removed_key_names in
  match present with
  | [] -> Ok ()
  | keys ->
    Error
      (Printf.sprintf
         "removed Keeper runtime TOML keys: %s"
         (String.concat ", " keys))

let validate_document doc =
  match validate_removed_keys doc with
  | Error _ as error -> error
  | Ok () -> validate_owned_keys doc

let env_is_set env_lookup env_name =
  Option.is_some (env_lookup env_name)

let resolved_config_root ~base_path =
  let inputs = Config_dir_resolver.inputs_from_env () in
  let resolution =
    Config_dir_resolver.resolve_with
      { inputs with env_base_path = Some base_path }
  in
  resolution.Config_dir_resolver.config_root.path

let toml_path ~base_path =
  Filename.concat
    (resolved_config_root ~base_path)
    Config_dir_resolver.runtime_toml_filename

let read_file path =
  (* Eio-native read (Fs_compat.load_file) so the keeper-runtime TOML
     read does not block the whole domain on each refresh. *)
  try Ok (Fs_compat.load_file path)
  with Sys_error msg -> Error msg

(** Format a TOML scalar back to a string suitable for the boot override store.
    Booleans → "true"/"false"; floats keep their TOML representation;
    strings pass through as-is. String arrays are not supported — they
    have no env var equivalent in the keeper config. *)
let value_to_string ~key = function
  | Keeper_toml_loader.Toml_string s -> Ok s
  | Keeper_toml_loader.Toml_int i -> Ok (string_of_int i)
  | Keeper_toml_loader.Toml_float f ->
    (* Match TOML representation (no trailing zeros). *)
    Ok (Printf.sprintf "%g" f)
  | Keeper_toml_loader.Toml_bool b -> Ok (if b then "true" else "false")
  | Keeper_toml_loader.Toml_string_array _ ->
    Error (Printf.sprintf "%s: string arrays are not supported" key)

type resolved_value =
  { env_name : string
  ; value : string
  ; apply : bool
  }

(** Validate and resolve every Keeper-owned TOML value before any process-local
    state is mutated. [apply] records the precedence decision separately from
    the operator-authored value so the shadow view and the boot override view
    are projections of the same resolved document. *)
let resolve_values
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  match validate_document doc with
  | Error _ as error -> error
  | Ok () ->
    let rec collect resolved = function
      | [] -> Ok (List.rev resolved)
      | (toml_key, env_name) :: rest ->
        (match List.assoc_opt toml_key doc with
         | None -> collect resolved rest
         | Some raw_value ->
           (match value_to_string ~key:toml_key raw_value with
            | Error _ as error -> error
            | Ok value ->
              let apply = not (env_is_set env_lookup env_name) in
              collect ({ env_name; value; apply } :: resolved) rest))
    in
    collect [] key_to_env

(** Pure version of the load+apply pipeline. Parses TOML and returns
    the number of overrides that would be applied, plus a list of
    (env_name, value) pairs. Exposed for testing without env side effects. *)
let resolve_overrides
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  match resolve_values ~env_lookup doc with
  | Error _ as error -> error
  | Ok values ->
    let overrides =
      values
      |> List.filter_map (fun value ->
        if value.apply then Some (value.env_name, value.value) else None)
    in
    Ok (List.length overrides, overrides)

(* Shadow registry: stores every TOML value keyed by env name, even when
   the env var is already set.  This lets operator surfaces compare the
   effective env override against the operator's TOML intent (issue #17192). *)
let toml_shadow : (string, string) Hashtbl.t = Hashtbl.create 16

let toml_value_opt env_name = Hashtbl.find_opt toml_shadow env_name

let validate_stream_idle_timeout doc =
  let key = "turn.stream_idle_timeout_sec" in
  match List.assoc_opt key doc with
  | None -> Ok ()
  | Some (Keeper_toml_loader.Toml_int seconds) ->
    Env_config_keeper.KeeperKeepalive.parse_stream_idle_timeout_sec
      (string_of_int seconds)
    |> Result.map (fun (_ : float) -> ())
    |> Result.map_error (fun detail -> Printf.sprintf "%s: %s" key detail)
  | Some (Keeper_toml_loader.Toml_float seconds) ->
    Env_config_keeper.KeeperKeepalive.parse_stream_idle_timeout_sec
      (Printf.sprintf "%.17g" seconds)
    |> Result.map (fun (_ : float) -> ())
    |> Result.map_error (fun detail -> Printf.sprintf "%s: %s" key detail)
  | Some
      (Keeper_toml_loader.Toml_string _
      | Keeper_toml_loader.Toml_bool _
      | Keeper_toml_loader.Toml_string_array _) ->
    Error (Printf.sprintf "%s: expected a numeric TOML value" key)

let load_and_apply ~base_path =
  let path = toml_path ~base_path in
  if not (Sys.file_exists path) then
    Ok 0
  else
    match read_file path with
    | Error msg ->
      Error (Printf.sprintf "read %s: %s" path msg)
    | Ok content ->
      match Keeper_toml_loader.parse_toml content with
      | Error msg ->
        Error (Printf.sprintf "parse %s: %s" path msg)
      | Ok doc ->
        (match resolve_values doc with
         | Error msg -> Error (Printf.sprintf "validate %s: %s" path msg)
         | Ok values ->
           match validate_stream_idle_timeout doc with
           | Error msg -> Error (Printf.sprintf "validate %s: %s" path msg)
           | Ok () ->
             Hashtbl.reset toml_shadow;
             List.iter
               (fun value ->
                  Hashtbl.replace toml_shadow value.env_name value.value)
               values;
             let overrides = List.filter (fun value -> value.apply) values in
             List.iter
               (fun value -> Config_boot_overrides.set value.env_name value.value)
               overrides;
             Ok (List.length overrides))
