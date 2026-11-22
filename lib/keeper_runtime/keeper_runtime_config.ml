(** Keeper_runtime_config — load startup runtime env seeding from
    [<resolved config root>/runtime.toml].  See [.mli] for design. *)

(* Generated projection of the typed setting authority. A TOML setting cannot
   reach the boot-overlay path unless the registry also declares its type,
   range, default, restart boundary, and concrete runtime consumer. *)
let key_to_env = Keeper_runtime_setting_registry.toml_env_mappings

let env_is_set env_lookup env_name =
  Option.is_some (env_lookup env_name)

(* A variable of the same name in the process environment is not a caller
   override for a row whose TOML key is its only input. *)
let env_preempts env_lookup env_name =
  (not (List.mem env_name Keeper_runtime_setting_registry.file_owned_env_names))
  && env_is_set env_lookup env_name

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

(** Decode a TOML scalar directly into a typed boot value without round-tripping
    through fake environment strings. *)
let typed_value_of_toml ~(kind : Keeper_runtime_setting_registry.value_kind) = function
  | Keeper_toml_loader.Toml_bool b ->
    (match kind with
     | Keeper_runtime_setting_registry.Boolean -> Some (Config_boot_overrides.Bool b)
     | Integer | Float | String -> None)
  | Keeper_toml_loader.Toml_int i ->
    (match kind with
     | Keeper_runtime_setting_registry.Integer -> Some (Config_boot_overrides.Int i)
     | Keeper_runtime_setting_registry.Float -> Some (Config_boot_overrides.Float (float_of_int i))
     | Boolean | String -> None)
  | Keeper_toml_loader.Toml_float f ->
    (match kind with
     | Keeper_runtime_setting_registry.Float -> Some (Config_boot_overrides.Float f)
     | Boolean | Integer | String -> None)
  | Keeper_toml_loader.Toml_string s ->
    (match kind with
     | Keeper_runtime_setting_registry.String -> Some (Config_boot_overrides.String s)
     | Boolean | Integer | Float -> None)
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

let decode_int_opt doc key =
  match List.assoc_opt key doc with
  | Some v ->
    (match typed_value_of_toml ~kind:Keeper_runtime_setting_registry.Integer v with
     | Some (Config_boot_overrides.Int i) -> Some i
     | Some (Bool _ | Float _ | String _) | None -> None)
  | None -> None

let decode_float_opt doc key =
  match List.assoc_opt key doc with
  | Some v ->
    (match typed_value_of_toml ~kind:Keeper_runtime_setting_registry.Float v with
     | Some (Config_boot_overrides.Float f) -> Some f
     | Some (Bool _ | Int _ | String _) | None -> None)
  | None -> None

let decode_bool_opt doc key =
  match List.assoc_opt key doc with
  | Some v ->
    (match typed_value_of_toml ~kind:Keeper_runtime_setting_registry.Boolean v with
     | Some (Config_boot_overrides.Bool b) -> Some b
     | Some (Int _ | Float _ | String _) | None -> None)
  | None -> None

let decode_string_opt doc key =
  match List.assoc_opt key doc with
  | Some v ->
    (match typed_value_of_toml ~kind:Keeper_runtime_setting_registry.String v with
     | Some (Config_boot_overrides.String s) -> Some s
     | Some (Bool _ | Int _ | Float _) | None -> None)
  | None -> None

let decode_typed_namespaces (doc : Keeper_toml_loader.toml_doc)
  : Config_boot_overrides.typed_namespaces
  =
  { Config_boot_overrides.memory =
      { category_cap = decode_int_opt doc "memory.category_cap"
      ; facts_per_category_cap = decode_int_opt doc "memory.facts_per_category_cap"
      ; recall_enabled = decode_bool_opt doc "memory.recall_enabled"
      ; librarian_enabled = decode_bool_opt doc "memory.librarian_enabled"
      ; facts_max_bytes = decode_int_opt doc "memory.facts_max_bytes"
      ; pending_max_bytes = decode_int_opt doc "memory.pending_max_bytes"
      }
  ; wiki_contents = { enabled = decode_bool_opt doc "wiki_contents.enabled" }
  ; maintenance = { jsonl_retention_days = decode_int_opt doc "maintenance.jsonl_retention_days" }
  ; transport =
      { h2_max_concurrent_streams = decode_int_opt doc "transport.h2_max_concurrent_streams"
      ; h2_max_pending_response_bytes = decode_int_opt doc "transport.h2_max_pending_response_bytes"
      ; h2_initial_window_size = decode_int_opt doc "transport.h2_initial_window_size"
      ; https_port = decode_int_opt doc "transport.https_port"
      ; tls_cert_file = decode_string_opt doc "transport.tls_cert_file"
      ; tls_key_file = decode_string_opt doc "transport.tls_key_file"
      ; grpc_enabled = decode_bool_opt doc "transport.grpc_enabled"
      ; ws_enabled = decode_bool_opt doc "transport.ws_enabled"
      ; serving_domain_enabled = decode_bool_opt doc "transport.serving_domain_enabled"
      ; startup_watchdog_sec = decode_float_opt doc "transport.startup_watchdog_sec"
      }
  }

(** Format a TOML scalar for operator display projections. *)
let value_to_string = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f -> Some (Keeper_runtime_setting_registry.display_file_float f)
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

(** Resolve a single TOML setting directly into its typed boot value. Returns
    [Some (env_name, typed_value)] when the key is present in the doc and the
    corresponding env var does not preempt it. *)
let resolve_typed_row
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc)
    (row : Keeper_runtime_setting_registry.setting) =
  match Keeper_runtime_setting_registry.toml_key_opt row with
  | None -> None
  | Some toml_key ->
    if env_preempts env_lookup row.env_name then
      None
    else
      match List.assoc_opt toml_key doc with
      | None -> None
      | Some v ->
        Option.map
          (fun tv -> row.env_name, tv)
          (typed_value_of_toml ~kind:row.value_kind v)

(** Pure projection for display/testing: returns (count, (env_name, display_str) list). *)
let resolve_overrides
    ?(env_lookup = Env_config_core.raw_value_opt)
    (doc : Keeper_toml_loader.toml_doc) =
  let applied =
    List.filter_map
      (fun row ->
         Option.map
           (fun (env_name, tv) -> env_name, Config_boot_overrides.typed_value_to_string tv)
           (resolve_typed_row ~env_lookup doc row))
      Keeper_runtime_setting_registry.toml_settings
  in
  (List.length applied, applied)

(* Store the parsed boot document independently of any env override. Compare
   numeric settings by value, not by the spelling chosen for display. *)
let toml_shadow : (string, Keeper_toml_loader.toml_value) Hashtbl.t = Hashtbl.create 16

let current_schema_version = 1
let schema_version_key = "keeper_settings.schema_version"

type validation_severity =
  | Error
  | Warning

type validation_issue_kind =
  | Invalid_schema_version
  | Unknown_key
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

(* What the row's own check says of the text the boot load would store for
   [value]. A value with no such text has already failed the type check. *)
let meaning_refusal (row : Keeper_runtime_setting_registry.setting) value =
  match row.value_meaning, value_to_string value with
  | None, (Some _ | None) | Some _, None -> None
  | Some check, Some text ->
    (match check text with
     | Ok () -> None
     | Result.Error detail -> Some detail)
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
          | (Keeper_runtime_setting_registry.Boolean | Keeper_runtime_setting_registry.Integer | Keeper_runtime_setting_registry.String) as kind -> Printf.sprintf
              "expected a %s TOML value"
              (Keeper_runtime_setting_registry.value_kind_label kind)))
  else if range_matches row.value_range value
  then
    Option.map
      (validation_issue ~key ~kind:Out_of_range ~severity:Error)
      (meaning_refusal row value)
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
          | ( Keeper_runtime_setting_registry.Unbounded
            | Keeper_runtime_setting_registry.Integer_range _
            | Keeper_runtime_setting_registry.Float_range _ ) as range ->
            Printf.sprintf
              "value is outside the declared range %s"
              (Keeper_runtime_setting_registry.value_range_label range)))
;;

let schema_version_of_doc doc =
  match List.assoc_opt schema_version_key doc with
  | None -> current_schema_version, []
  | Some (Keeper_toml_loader.Toml_int version) when version > 0 -> version, []
  | Some
      ( Keeper_toml_loader.Toml_string _
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
      | Keeper_toml_loader.Toml_local_time _ ) ->
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
           | Some row ->
             (match validate_setting_value key row value with
              | Some issue -> issue :: issues
              | None -> issues)
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

let configured_toml_value doc (row : Keeper_runtime_setting_registry.setting) =
  match Keeper_runtime_setting_registry.toml_key_opt row with
  | Some key -> List.assoc_opt key doc
  | None -> None
;;

let configured_value doc row =
  Option.bind (configured_toml_value doc row) value_to_string
;;

let same_setting_value (row : Keeper_runtime_setting_registry.setting) applied configured =
  match row.value_kind with
  | Keeper_runtime_setting_registry.Float ->
    (match numeric_value applied, numeric_value configured with
     | Some left, Some right -> Float.equal left right
     | Some _, None | None, Some _ | None, None -> false)
  | Keeper_runtime_setting_registry.Boolean
  | Keeper_runtime_setting_registry.Integer
  | Keeper_runtime_setting_registry.String ->
    Option.equal String.equal (value_to_string applied) (value_to_string configured)
;;

(* A [Toml_only] row ignores the process environment, so the layer in effect is
   the file's value or the default whatever the shell exported. *)
let effective_source (row : Keeper_runtime_setting_registry.setting) =
  if Keeper_runtime_setting_registry.reads_process_env row
  then Config_boot_overrides.source row.env_name
  else (
    match Config_boot_overrides.get_opt row.env_name with
    | Some _ -> Config_boot_overrides.Boot_override
    | None -> Config_boot_overrides.Default)
;;

(* The panel's label for the layer in effect; a boot override is the
   runtime file's value, so it reads "toml". *)
let effective_source_label = function
  | Config_boot_overrides.Boot_override -> "toml"
  | Config_boot_overrides.Env -> "env"
  | Config_boot_overrides.Default -> "default"
;;

let application_status doc (row : Keeper_runtime_setting_registry.setting) =
  match configured_value doc row, effective_source row with
  | Some _, Config_boot_overrides.Env -> "preempted_by_env"
  | Some _, Config_boot_overrides.Boot_override ->
    (match Hashtbl.find_opt toml_shadow row.env_name, configured_toml_value doc row with
     | Some applied, Some configured when same_setting_value row applied configured -> "applied"
     | Some _, Some _ | Some _, None | None, Some _ | None, None -> "pending_restart")
  | Some _, Config_boot_overrides.Default ->
    if Keeper_runtime_setting_registry.requires_restart row
    then "pending_restart"
    else "pending_effect_boundary"
  | None, Config_boot_overrides.Boot_override ->
    (* The boot snapshot still serves the removed TOML value until restart.
       Absence in the edited document is therefore a pending removal, not
       "not configured". *)
    "pending_restart"
  | None, (Config_boot_overrides.Env | Config_boot_overrides.Default) ->
    (match row.exposure with
     | Keeper_runtime_setting_registry.Env_only -> "environment_only"
     | Keeper_runtime_setting_registry.Toml_and_env _
     | Keeper_runtime_setting_registry.Toml_only _ -> "not_configured")
;;

(** The value the row's runtime consumer reads, from the accessor the
    registry row carries. Never an echo of [raw_value_opt]: malformed or
    clamped process input must not be presented to operators as an effective
    value. *)
let effective_setting_value (row : Keeper_runtime_setting_registry.setting) =
  try Result.Ok (Keeper_runtime_setting_registry.effective_value row) with
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
    let source = effective_source_label (effective_source row) in
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
  `List (List.map project Keeper_runtime_setting_registry.all)
;;

let overlay_application_to_yojson doc =
  let configured =
    Keeper_runtime_setting_registry.toml_settings
    |> List.filter (fun row -> Option.is_some (configured_value doc row))
  in
  let application_rows =
    Keeper_runtime_setting_registry.toml_settings
    |> List.filter (fun row ->
      Option.is_some (configured_value doc row)
      || effective_source row = Config_boot_overrides.Boot_override)
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
                  "toml_settings row %s has no TOML key"
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

(* The first registry reader that rejects what the process environment and the
   defaults hold, with its message. The file's own values are not this check's
   to judge: [validate_doc] refuses them before any is stored. *)
let first_rejecting_reader () =
  List.find_map
    (fun (row : Keeper_runtime_setting_registry.setting) ->
       match Keeper_runtime_setting_registry.effective_value row with
       | (_ : string) -> None
       | exception Env_config_core.Config_error message -> Some message)
    Keeper_runtime_setting_registry.toml_settings

(* One load at a time stores the file's values and records them in the shadow
   registry, so two loads cannot leave the store holding one file's values and
   the shadow registry the other's. *)
let apply_sequence_mutex = Eio.Mutex.create ()

let load_and_apply_document ~base_path =
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
           Eio_guard.with_mutex apply_sequence_mutex (fun () ->
             let typed_pairs =
               List.filter_map
                 (resolve_typed_row doc)
                 Keeper_runtime_setting_registry.toml_settings
             in
             Config_boot_overrides.set_typed_batch typed_pairs;
             Config_boot_overrides.set_typed_namespaces (decode_typed_namespaces doc);
             let count = List.length typed_pairs in
             Hashtbl.clear toml_shadow;
             List.iter
               (fun (toml_key, env_name) ->
                  (* Populate shadow registry for every known key that has a
                     TOML value, regardless of whether env preempts it. *)
                  match List.assoc_opt toml_key doc with
                  | None -> ()
                  | Some v ->
                    (match value_to_string v with
                     | None -> ()
                     | Some _ -> Hashtbl.replace toml_shadow env_name v))
               key_to_env;
             Atomic.set last_applied_at (Some (Time_compat.now ()));
             Ok count))

let load_and_apply ~base_path : (int, load_failure) result =
  (* First, so the validation below and every later read of these names leave
     the process environment out. *)
  Config_boot_overrides.declare_file_owned
    Keeper_runtime_setting_registry.file_owned_env_names;
  (* Before the file adds anything: the process environment and the defaults. A
     malformed variable is reported as one, not blamed on the file. *)
  let validation =
    match first_rejecting_reader () with
    | Some message -> Result.Error { kind = Validate; message }
    | None -> Ok ()
  in
  let result =
    match validation with
    | Result.Error error -> Result.Error error
    | Ok () -> load_and_apply_document ~base_path
  in
  (* A file that did not load fed nothing, so these names are not the file's
     alone: a process that goes on after the failure reads them as it did
     before. *)
  (match result with
   | Result.Error _ -> Config_boot_overrides.declare_file_owned []
   | Ok _ -> ());
  result
