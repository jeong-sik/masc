(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].  See [.mli] for design. *)

(* Generated projection of the typed setting authority. A TOML setting cannot
   reach the boot-overlay path unless the registry also declares its type,
   range, default, restart boundary, and concrete runtime consumer. *)
let key_to_env = Keeper_runtime_setting_registry.active_toml_mappings

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
let value_to_string = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f ->
    (* Match TOML representation (no trailing zeros). *)
    Some (Printf.sprintf "%g" f)
  | Keeper_toml_loader.Toml_bool b -> Some (if b then "true" else "false")
  | ( Keeper_toml_loader.Toml_string_array _
    | Keeper_toml_loader.Toml_array _
    | Keeper_toml_loader.Toml_table _
    | Keeper_toml_loader.Toml_inline_table _
    | Keeper_toml_loader.Toml_table_array _
    | Keeper_toml_loader.Toml_offset_datetime _
    | Keeper_toml_loader.Toml_local_datetime _
    | Keeper_toml_loader.Toml_local_date _
    | Keeper_toml_loader.Toml_local_time _ ) ->
    None

(** Resolve a single TOML key to its boot-override value. Returns
    [Some (env_name, value)] when the key is present in the doc and the
    corresponding env var is unset (so the TOML value would apply).
    Returns [None] when the env var is already set (caller override wins)
    or the key is absent / unsupported.

    This is the single precedence rule shared by the pure preview
    ([resolve_overrides]) and the effectful apply path ([apply_one]):
    env var > TOML > hardcoded default. *)
let resolve_one
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) (toml_key, env_name) =
  if env_is_set env_lookup env_name then
    (* Caller env override — leave alone. *)
    None
  else
    match List.assoc_opt toml_key doc with
    | None -> None
    | Some v -> Option.map (fun s -> (env_name, s)) (value_to_string v)

(** Apply one TOML key to the corresponding env var, unless the env var
    is already set (caller override wins). Returns [true] iff a boot
    override was actually recorded.

    [~env_lookup] and [~env_set] are injectable for testing: production
    uses [Env_config_core.raw_value_opt] / [Config_boot_overrides.set];
    tests supply a fake env to avoid global process env dependence. *)
let apply_one
    ?(env_lookup = Env_config_core.raw_value_opt)
    ?(env_set = Config_boot_overrides.set)
    (doc : Keeper_toml_loader.toml_doc) pair =
  match resolve_one ~env_lookup doc pair with
  | None -> false
  | Some (env_name, s) ->
    env_set env_name s;
    true

(** Pure version of the load+apply pipeline. Parses TOML and returns
    the number of overrides that would be applied, plus a list of
    (env_name, value) pairs. Exposed for testing without env side effects. *)
let resolve_overrides
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  let applied = List.filter_map (resolve_one ~env_lookup doc) key_to_env in
  (List.length applied, applied)

(* Shadow registry: stores every TOML value keyed by env name, even when
   the env var is already set.  This lets operator surfaces compare the
   effective env override against the operator's TOML intent (issue #17192). *)
let toml_shadow : (string, string) Hashtbl.t = Hashtbl.create 16

let toml_value_opt env_name = Hashtbl.find_opt toml_shadow env_name

let current_schema_version = 1
let schema_version_key = "keeper_settings.schema_version"

type validation_severity =
  | Error
  | Warning

type validation_issue_kind =
  | Invalid_schema_version
  | Unknown_key
  | Retired_key
  | Type_mismatch
  | Out_of_range

type validation_issue =
  { key : string
  ; kind : validation_issue_kind
  ; severity : validation_severity
  ; detail : string
  }

type validation_report =
  { schema_version : int
  ; forward_schema : bool
  ; issues : validation_issue list
  }

let last_applied_at = Atomic.make None
let last_applied_at_unix () = Atomic.get last_applied_at

let validation_issue ~key ~kind ~severity detail =
  { key; kind; severity; detail }
;;

let validation_report_is_valid report =
  not (List.exists (fun issue -> issue.severity = Error) report.issues)
;;

let first_segment key =
  match String.index_opt key '.' with
  | Some index -> String.sub key 0 index
  | None -> key
;;

let owned_namespaces =
  let add_unique value values =
    if List.exists (String.equal value) values then values else value :: values
  in
  List.fold_left
    (fun namespaces row ->
       match Keeper_runtime_setting_registry.toml_key_opt row with
       | Some key -> add_unique (first_segment key) namespaces
       | None -> namespaces)
    [ "keeper_settings" ]
    Keeper_runtime_setting_registry.all
;;

let is_direct_namespace_child key =
  match String.split_on_char '.' key with
  | [ namespace; _ ] -> List.exists (String.equal namespace) owned_namespaces
  | _ -> false
;;

let is_owned_key key =
  String.equal key schema_version_key
  || Option.is_some (Keeper_runtime_setting_registry.find_by_toml_key key)
  || is_direct_namespace_child key
;;

let numeric_value = function
  | Keeper_toml_loader.Toml_int value -> Some (float_of_int value)
  | Keeper_toml_loader.Toml_float value -> Some value
  | ( Keeper_toml_loader.Toml_string _
    | Keeper_toml_loader.Toml_bool _
    | Keeper_toml_loader.Toml_string_array _
    | Keeper_toml_loader.Toml_array _
    | Keeper_toml_loader.Toml_table _
    | Keeper_toml_loader.Toml_inline_table _
    | Keeper_toml_loader.Toml_table_array _
    | Keeper_toml_loader.Toml_offset_datetime _
    | Keeper_toml_loader.Toml_local_datetime _
    | Keeper_toml_loader.Toml_local_date _
    | Keeper_toml_loader.Toml_local_time _ ) ->
    None
;;

let type_matches kind value =
  match kind, value with
  | Keeper_runtime_setting_registry.Boolean, Keeper_toml_loader.Toml_bool _ -> true
  | Keeper_runtime_setting_registry.Integer, Keeper_toml_loader.Toml_int _ -> true
  | ( Keeper_runtime_setting_registry.Float
    , (Keeper_toml_loader.Toml_int _ | Keeper_toml_loader.Toml_float _) ) ->
    true
  | Keeper_runtime_setting_registry.String, Keeper_toml_loader.Toml_string _ -> true
  | ( ( Keeper_runtime_setting_registry.Boolean
      | Keeper_runtime_setting_registry.Integer
      | Keeper_runtime_setting_registry.Float
      | Keeper_runtime_setting_registry.String )
    , ( Keeper_toml_loader.Toml_string _
      | Keeper_toml_loader.Toml_int _
      | Keeper_toml_loader.Toml_float _
      | Keeper_toml_loader.Toml_bool _
      | Keeper_toml_loader.Toml_string_array _
      | Keeper_toml_loader.Toml_array _
      | Keeper_toml_loader.Toml_table _
      | Keeper_toml_loader.Toml_inline_table _
      | Keeper_toml_loader.Toml_table_array _
      | Keeper_toml_loader.Toml_offset_datetime _
      | Keeper_toml_loader.Toml_local_datetime _
      | Keeper_toml_loader.Toml_local_date _
      | Keeper_toml_loader.Toml_local_time _ ) ) ->
    false
;;

let range_matches range value =
  match range with
  | Keeper_runtime_setting_registry.Unbounded -> true
  | Keeper_runtime_setting_registry.Integer_range { min_inclusive; max_inclusive } ->
    (match value with
     | Keeper_toml_loader.Toml_int value ->
       Option.fold ~none:true ~some:(fun minimum -> value >= minimum) min_inclusive
       && Option.fold ~none:true ~some:(fun maximum -> value <= maximum) max_inclusive
     | ( Keeper_toml_loader.Toml_string _
       | Keeper_toml_loader.Toml_float _
       | Keeper_toml_loader.Toml_bool _
       | Keeper_toml_loader.Toml_string_array _
       | Keeper_toml_loader.Toml_array _
       | Keeper_toml_loader.Toml_table _
       | Keeper_toml_loader.Toml_inline_table _
       | Keeper_toml_loader.Toml_table_array _
       | Keeper_toml_loader.Toml_offset_datetime _
       | Keeper_toml_loader.Toml_local_datetime _
       | Keeper_toml_loader.Toml_local_date _
       | Keeper_toml_loader.Toml_local_time _ ) ->
       false)
  | Keeper_runtime_setting_registry.Float_range
      { min_inclusive; min_exclusive; max_inclusive } ->
    (match numeric_value value with
     | Some value ->
       Float.is_finite value
       && Option.fold ~none:true ~some:(fun minimum -> value >= minimum) min_inclusive
       && Option.fold ~none:true ~some:(fun minimum -> value > minimum) min_exclusive
       && Option.fold ~none:true ~some:(fun maximum -> value <= maximum) max_inclusive
     | None -> false)
;;

let validate_setting_value key row value =
  if not (type_matches row.Keeper_runtime_setting_registry.value_kind value)
  then
    Some
      (validation_issue
         ~key
         ~kind:Type_mismatch
         ~severity:Error
         (match row.value_kind with
          | Keeper_runtime_setting_registry.Float -> "expected a numeric TOML value"
          | kind ->
            Printf.sprintf
              "expected a %s TOML value"
              (Keeper_runtime_setting_registry.value_kind_label kind)))
  else if range_matches row.value_range value
  then None
  else
    Some
      (validation_issue
         ~key
         ~kind:Out_of_range
         ~severity:Error
         (match row.value_range with
          | Keeper_runtime_setting_registry.Float_range
              { min_inclusive = None
              ; min_exclusive = Some minimum
              ; max_inclusive = None
              }
            when Float.equal minimum 0.0 ->
            "expected a finite, positive number of seconds"
          | range ->
            Printf.sprintf
              "value is outside the declared range %s"
              (Keeper_runtime_setting_registry.value_range_label range)))
;;

let schema_version_of_doc doc =
  match List.assoc_opt schema_version_key doc with
  | None -> current_schema_version, []
  | Some (Keeper_toml_loader.Toml_int version) when version > 0 -> version, []
  | Some _ ->
    ( current_schema_version
    , [ validation_issue
          ~key:schema_version_key
          ~kind:Invalid_schema_version
          ~severity:Error
          "schema_version must be a positive integer"
      ] )
;;

let validate_doc doc =
  let schema_version, schema_issues = schema_version_of_doc doc in
  let forward_schema = schema_version > current_schema_version in
  let issues =
    List.fold_left
      (fun issues (key, value) ->
         if String.equal key schema_version_key || not (is_owned_key key)
         then issues
         else
           match Keeper_runtime_setting_registry.find_by_toml_key key with
           | Some
               ({ lifecycle = Keeper_runtime_setting_registry.Active; _ } as row) ->
             (match validate_setting_value key row value with
              | Some issue -> issue :: issues
              | None -> issues)
           | Some
               { lifecycle = Keeper_runtime_setting_registry.Retired { reason; replacement }
               ; _
               } ->
             let replacement =
               match replacement with
               | Some value -> Printf.sprintf "; use %s" value
               | None -> ""
             in
             validation_issue
               ~key
               ~kind:Retired_key
               ~severity:Error
               (reason ^ replacement)
             :: issues
           | None ->
             validation_issue
               ~key
               ~kind:Unknown_key
               ~severity:(if forward_schema then Warning else Error)
               (if forward_schema
                then
                  Printf.sprintf
                    "unknown to Keeper settings schema v%d; preserved as a future-version warning"
                    current_schema_version
                else "unknown Keeper runtime setting")
             :: issues)
      schema_issues
      doc
  in
  { schema_version; forward_schema; issues = List.rev issues }
;;

let validate_source_text source_text =
  match Keeper_toml_loader.parse_toml source_text with
  | Result.Error message -> Result.Error message
  | Ok doc -> Ok (validate_doc doc)
;;

let validation_severity_label = function
  | Error -> "error"
  | Warning -> "warning"
;;

let validation_issue_kind_label = function
  | Invalid_schema_version -> "invalid_schema_version"
  | Unknown_key -> "unknown_key"
  | Retired_key -> "retired_key"
  | Type_mismatch -> "type_mismatch"
  | Out_of_range -> "out_of_range"
;;

let validation_report_to_yojson report =
  `Assoc
    [ "valid", `Bool (validation_report_is_valid report)
    ; "schema_version", `Int report.schema_version
    ; "current_schema_version", `Int current_schema_version
    ; "forward_schema", `Bool report.forward_schema
    ; ( "issues"
      , `List
          (List.map
             (fun issue ->
                `Assoc
                  [ "key", `String issue.key
                  ; "kind", `String (validation_issue_kind_label issue.kind)
                  ; "severity", `String (validation_severity_label issue.severity)
                  ; "detail", `String issue.detail
                  ])
             report.issues) )
    ]
;;

let setting_schema_to_yojson = Keeper_runtime_setting_registry.schema_to_yojson

let configured_value doc (row : Keeper_runtime_setting_registry.setting) =
  match Keeper_runtime_setting_registry.toml_key_opt row with
  | Some key -> Option.bind (List.assoc_opt key doc) value_to_string
  | None -> None
;;

let effective_source env_name =
  match Config_boot_overrides.source env_name with
  | "boot_override" -> "toml"
  | "env" -> "env"
  | "default" -> "default"
  | _ -> "unknown"
;;

let application_status doc (row : Keeper_runtime_setting_registry.setting) =
  match configured_value doc row, effective_source row.env_name with
  | Some _, "env" -> "preempted_by_env"
  | Some configured, "toml" ->
    (match toml_value_opt row.env_name with
     | Some applied when String.equal applied configured -> "applied"
     | Some _ | None -> "pending_restart")
  | Some _, ("default" | "unknown") ->
    if Keeper_runtime_setting_registry.requires_restart row
    then "pending_restart"
    else "pending_effect_boundary"
  | None, "toml" ->
    (* The boot snapshot still serves the removed TOML value until restart.
       Absence in the edited document is therefore a pending removal, not
       "not configured". *)
    "pending_restart"
  | None, _ ->
    (match row.exposure with
     | Keeper_runtime_setting_registry.Env_only -> "environment_only"
     | Keeper_runtime_setting_registry.Toml_and_env _ -> "not_configured")
  | Some _, _ -> "pending_restart"
;;

let display_bool value = if value then "true" else "false"
let display_int = string_of_int
let display_float value = Printf.sprintf "%g" value
let display_string_option = function
  | Some value -> value
  | None -> "(none)"
;;
let display_float_option = Option.fold ~none:"(none)" ~some:display_float

let bounded_int_from_env ~default ~min_value ~max_value env_name =
  Env_config_core.get_int ~default env_name |> max min_value |> min max_value
;;

let bounded_float_from_env ~default ~min_value ~max_value env_name =
  Env_config_core.get_float ~default env_name
  |> Float.max min_value
  |> Float.min max_value
;;

(** Read the same typed value exposed to the runtime consumer. This projection
    deliberately does not echo [raw_value_opt]: malformed or clamped process
    input must never be presented to operators as an effective value. *)
let effective_setting_value (row : Keeper_runtime_setting_registry.setting) =
  try
    Result.Ok
      (match row.env_name with
       | "MASC_KEEPER_BOOTSTRAP_ENABLED" ->
         display_bool Env_config_keeper.KeeperBootstrap.enabled
       | "MASC_KEEPER_BOOTSTRAP_LAZY_STARTUP_POLL_INTERVAL_SEC" ->
         display_float
           Env_config_keeper.KeeperBootstrap.lazy_startup_poll_interval_sec
       | "MASC_KEEPER_BOOTSTRAP_LISTENER_RETRY_INTERVAL_SEC" ->
         display_float
           Env_config_keeper.KeeperBootstrap.keeper_listener_retry_interval_sec
       | "MASC_KEEPER_BOOTSTRAP_POST_STARTUP_SETTLE_SEC" ->
         display_float Env_config_keeper.KeeperBootstrap.post_startup_settle_sec
       | "MASC_KEEPER_REACTIVE_ENABLED"
       | "MASC_KEEPER_PROACTIVE_ENABLED"
       | "MASC_KEEPER_AUTONOMOUS_ENABLED" ->
         display_bool (Feature_flag_registry.get_bool row.env_name)
       | "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" ->
         display_int Env_config_keeper.KeeperKeepalive.interval_sec
       | "MASC_KEEPER_SNAPSHOT_SEC" ->
         display_int Env_config_keeper.KeeperRuntime.snapshot_sec
       | "MASC_KEEPER_WORK_AS_HEARTBEAT" ->
         display_bool Env_config_keeper.WorkAsHeartbeat.enabled
       | "MASC_KEEPER_SLEEP_CHUNK_SEC" ->
         display_float Env_config_keeper.KeeperKeepalive.sleep_chunk_sec
       | "MASC_KEEPER_DURABLE_QUEUE_STALE_SEC" ->
         display_float (Env_config_keeper.KeeperHealth.durable_queue_stale_sec ())
       | "MASC_KEEPER_WIRE_CAPTURE" ->
         display_bool (Env_config_keeper.KeeperWireCapture.enabled ())
       | "MASC_KEEPER_WIRE_CAPTURE_RETENTION_DAYS" ->
         display_int (Env_config_keeper.KeeperWireCapture.retention_days ())
       | "MASC_KEEPER_WIRE_CAPTURE_MAX_BYTES" ->
         display_int (Env_config_keeper.KeeperWireCapture.max_bytes ())
       | "MASC_KEEPER_DEBUG" ->
         display_bool Env_config_keeper.KeeperRuntime.debug
       | "MASC_KEEPER_BATCH_LIMIT" ->
         display_int
           (bounded_int_from_env
              ~default:200
              ~min_value:10
              ~max_value:2000
              row.env_name)
       | "MASC_KEEPER_UNIFIED_TEMP" ->
         display_float
           (bounded_float_from_env
              ~default:0.4
              ~min_value:0.0
              ~max_value:2.0
              row.env_name)
       | "MASC_KEEPER_ENABLE_THINKING" ->
         display_bool (Env_config_core.get_bool ~default:false row.env_name)
       | "MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC" ->
         (match Env_config_keeper.KeeperKeepalive.stream_idle_timeout_sec () with
          | Some value -> display_float value
          | None ->
            display_float
              Env_config_keeper.KeeperKeepalive.stream_idle_failsafe_floor_sec)
       | "MASC_KEEPER_FIRST_EVENT_TIMEOUT_SEC" ->
         (match Env_config_keeper.KeeperKeepalive.first_event_timeout_sec () with
          | Some value -> display_float value
          | None ->
            display_float
              Env_config_keeper.KeeperKeepalive.first_event_failsafe_floor_sec)
       | "MASC_KEEPER_PROVIDER_CALL_DEADLINE_SEC" ->
         display_float_option
           Env_config_keeper.KeeperKeepalive.provider_call_deadline_sec_override
       | "MASC_KEEPER_BODY_TIMEOUT_SEC" ->
         display_float_option Env_config_keeper.KeeperKeepalive.body_timeout_sec_override
       | "MASC_KEEPER_CRASH_PERSIST_DRAIN_INTERVAL_SEC" ->
         display_float Env_config_keeper.KeeperPollIntervals.crash_persistence_drain_sec
       | "MASC_KEEPER_STAGE_TIMING_RING_SIZE" ->
         display_int Env_config_keeper.KeeperProactive.stage_timing_ring_size
       | "MASC_KEEPER_SUPERVISOR_SWEEP_SEC" ->
         display_float Env_config_keeper.KeeperSupervisor.sweep_interval_sec
       | "MASC_KEEPER_METRICS_MAX_BYTES" ->
         display_int Env_config_keeper.KeeperMetrics.max_file_bytes
       | "MASC_KEEPER_METRICS_MAX_ROTATED" ->
         display_int Env_config_keeper.KeeperMetrics.max_rotated_files
       | "MASC_KEEPER_MEMORY_OS_LIBRARIAN_CADENCE_TURNS" ->
         display_int (Env_config_keeper.KeeperMemoryOs.librarian_cadence_turns ())
       | "MASC_KEEPER_MEMORY_OS_LIBRARIAN_MAX_MESSAGES" ->
         display_int (Env_config_keeper.KeeperMemoryOs.librarian_max_messages ())
       | "MASC_KEEPER_MEMORY_OS_RECALL_FACTS_MAX_BYTES" ->
         display_int (Env_config_keeper.KeeperMemoryOs.recall_facts_max_bytes ())
       | "MASC_KEEPER_MEMORY_OS_RECALL" ->
         display_bool (Env_config_keeper.KeeperMemoryOs.recall_enabled ())
       | "MASC_KEEPER_MEMORY_OS_LIBRARIAN" ->
         (match Env_config_keeper.KeeperMemoryOs.librarian_config_state () with
          | Env_config_keeper.KeeperMemoryOs.Enabled -> "true"
          | Env_config_keeper.KeeperMemoryOs.Disabled -> "false"
          | Env_config_keeper.KeeperMemoryOs.Invalid ->
            raise
              (Env_config_core.Config_error
                 "MASC_KEEPER_MEMORY_OS_LIBRARIAN is malformed"))
       | "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" ->
         display_int (Env_config_keeper.KeeperVision.max_image_bytes ())
       | "MASC_KEEPER_VISION_MAX_OUTPUT_TOKENS" ->
         display_int (Env_config_keeper.KeeperVision.max_output_tokens ())
       | "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_BASE_SEC" ->
         display_float (Env_config_keeper.KeeperVision.candidate_backoff_base_sec ())
       | "MASC_KEEPER_VISION_CANDIDATE_BACKOFF_MAX_SEC" ->
         display_float (Env_config_keeper.KeeperVision.candidate_backoff_max_sec ())
       | "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" ->
         display_int (Env_config_keeper.KeeperGeneratedMedia.max_bytes ())
       | "MASC_KEEPER_GENERATED_MEDIA_DIR_MAX_BYTES" ->
         display_int (Env_config_keeper.KeeperGeneratedMedia.dir_max_bytes ())
       | "MASC_KEEPER_GENERATED_MEDIA_RETENTION_SEC" ->
         display_float (Env_config_keeper.KeeperGeneratedMedia.retention_seconds ())
       | "MASC_KEEPER_GRPC_RECONNECT_BACKOFF_SEC" ->
         display_float Env_config_keeper.KeeperGrpc.reconnect_backoff_sec
       | "MASC_KEEPER_AUTONOMOUS_WAKE_PROMPT" ->
         (* Reports the same string the prompt builder uses, so the settings
            panel and the turn agree. *)
         Env_config_keeper.KeeperAutonomous.wake_prompt ()
       | "MASC_SEARXNG_URL" ->
         let url =
           match Env_config_core.raw_value_opt row.env_name with
           | None -> Masc_network_defaults.searxng_default_url
           | Some raw ->
             let normalized =
               raw |> String.trim |> Env_config_core.strip_trailing_slashes
             in
             if String.equal normalized ""
             then Masc_network_defaults.searxng_default_url
             else normalized
         in
         (match Uri.scheme (Uri.of_string url) |> Option.map String.lowercase_ascii with
          | Some ("http" | "https") -> url
          | Some _ | None ->
            raise
              (Env_config_core.Config_error
                 (Printf.sprintf
                    "MASC_SEARXNG_URL must use http or https scheme (got: %s)"
                    url)))
       | "MASC_WEB_SEARCH_PROVIDER" ->
         display_string_option (Env_config_runtime.Tools.web_search_provider_opt ())
       | "MASC_WEB_SEARCH_PROVIDER_ORDER" ->
         display_string_option
           (Env_config_runtime.Tools.web_search_provider_order_opt ())
       | "MASC_WEB_SEARCH_FALLBACKS" ->
         display_string_option (Env_config_runtime.Tools.web_search_fallbacks_opt ())
       | "MASC_WEB_SEARCH_TIMEOUT_SEC" ->
         display_int (Env_config_runtime.Tools.web_search_timeout_sec ())
       | "MASC_WEB_SEARCH_CACHE_TTL_SEC" ->
         display_float (Env_config_runtime.Tools.web_search_cache_ttl_sec ())
       | unsupported ->
         raise
           (Env_config_core.Config_error
              ("no typed effective-value projector for " ^ unsupported)))
  with
  | Env_config_core.Config_error message -> Result.Error message
;;

let settings_projection_to_yojson doc =
  let applied_at = last_applied_at_unix () in
  let applied_at_json status =
    match status, applied_at with
    | "applied", Some value -> `Float value
    | _, _ -> `Null
  in
  let project (row : Keeper_runtime_setting_registry.setting) =
    let configured_value = configured_value doc row in
    let source = effective_source row.env_name in
    let effective_value = effective_setting_value row in
    let application_status = application_status doc row in
    `Assoc
      [ ( "key"
        , match Keeper_runtime_setting_registry.toml_key_opt row with
          | Some value -> `String value
          | None -> `Null )
      ; "env", `String row.env_name
      ; ( "configured_value"
        , match configured_value with
          | Some value -> `String value
          | None -> `Null )
      ; "source", `String source
      ; ( "effective_value"
        , match effective_value with
          | Ok value -> `String value
          | Result.Error _ -> `Null )
      ; ( "effective_error"
        , match effective_value with
          | Ok _ -> `Null
          | Result.Error message -> `String message )
      ; "applied_at", applied_at_json application_status
      ; "reload_class", `String (Keeper_runtime_setting_registry.reload_class_label row.reload_class)
      ; "requires_restart", `Bool (Keeper_runtime_setting_registry.requires_restart row)
      ; "application_status", `String application_status
      ; "consumers", `List (List.map (fun value -> `String value) row.consumers)
      ]
  in
  `List (List.map project Keeper_runtime_setting_registry.active)
;;

let overlay_application_to_yojson doc =
  let configured =
    Keeper_runtime_setting_registry.active_toml
    |> List.filter (fun row -> Option.is_some (configured_value doc row))
  in
  let application_rows =
    Keeper_runtime_setting_registry.active_toml
    |> List.filter (fun row ->
      Option.is_some (configured_value doc row)
      || String.equal (effective_source row.env_name) "toml")
  in
  let classified =
    List.map
      (fun row ->
         let key =
           match Keeper_runtime_setting_registry.toml_key_opt row with
           | Some key -> key
           | None ->
             invalid_arg
               (Printf.sprintf
                  "active_toml row %s has no TOML key"
                  row.env_name)
         in
         key, application_status doc row)
      application_rows
  in
  let keys_with_status expected =
    classified
    |> List.filter_map (fun (key, status) ->
      if String.equal status expected then Some (`String key) else None)
  in
  let pending_keys =
    classified
    |> List.filter_map (fun (key, status) ->
      if String.equal status "pending_restart"
         || String.equal status "pending_effect_boundary"
      then Some (`String key)
      else None)
  in
  let status =
    if classified = []
    then "not_configured"
    else if pending_keys <> []
    then "pending_restart"
    else if List.for_all (fun (_, value) -> String.equal value "applied") classified
    then "applied"
    else if List.for_all (fun (_, value) -> String.equal value "preempted_by_env") classified
    then "preempted_by_env"
    else "mixed"
  in
  `Assoc
    [ "status", `String status
    ; "configured_count", `Int (List.length configured)
    ; "requires_restart", `Bool (pending_keys <> [])
    ; "pending_keys", `List pending_keys
    ; "applied_keys", `List (keys_with_status "applied")
    ; "preempted_keys", `List (keys_with_status "preempted_by_env")
    ; ( "applied_at"
      , match status, last_applied_at_unix () with
        | "applied", Some value -> `Float value
        | _, _ -> `Null )
    ]
;;

(* Bootstrap labels its failure counter from this. It used to recover the label
   by re-reading the rendered message for a "read " or "parse " prefix, which
   left the validate failure — and any future one — incrementing nothing, while
   the counter's help text advertised those two as the whole domain. *)
type load_failure_kind =
  | Read
  | Parse
  | Validate

let load_failure_kind_label = function
  | Read -> "read_error"
  | Parse -> "parse_error"
  | Validate -> "validate_error"
;;

let all_load_failure_kinds = [ Read; Parse; Validate ]

let load_failure_kind_labels = List.map load_failure_kind_label all_load_failure_kinds

type load_failure =
  { kind : load_failure_kind
  ; message : string
  }

let load_failure_to_string { kind; message } =
  let verb =
    match kind with
    | Read -> "read"
    | Parse -> "parse"
    | Validate -> "validate"
  in
  Printf.sprintf "%s %s" verb message
;;

let load_and_apply ~base_path =
  let path = toml_path ~base_path in
  if not (Sys.file_exists path) then
    Ok 0
  else
    match read_file path with
    | Result.Error msg ->
      Result.Error { kind = Read; message = Printf.sprintf "%s: %s" path msg }
    | Ok content ->
      match Keeper_toml_loader.parse_toml content with
      | Result.Error msg ->
        Result.Error { kind = Parse; message = Printf.sprintf "%s: %s" path msg }
      | Ok doc ->
        let report = validate_doc doc in
        (match List.find_opt (fun issue -> issue.severity = Error) report.issues with
         | Some issue ->
           Result.Error
             { kind = Validate
             ; message = Printf.sprintf "%s: %s: %s" path issue.key issue.detail
             }
         | None ->
           Hashtbl.clear toml_shadow;
           let count =
             List.fold_left
               (fun acc (toml_key, env_name) ->
                  (* Populate shadow registry for every known key that has a
                     TOML value, regardless of whether env preempts it. *)
                  (match List.assoc_opt toml_key doc with
                   | None -> ()
                   | Some v ->
                     match value_to_string v with
                     | None -> ()
                     | Some s -> Hashtbl.replace toml_shadow env_name s);
                  if apply_one doc (toml_key, env_name) then acc + 1 else acc)
               0
               key_to_env
           in
           Atomic.set last_applied_at (Some (Time_compat.now ()));
           Ok count)
