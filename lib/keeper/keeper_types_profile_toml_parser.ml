include Keeper_config
include Keeper_types_profile_sandbox
include Keeper_types_profile_defaults
include Keeper_types_profile_toml_normalizers
include Keeper_types_profile_oas_env

let toml_value_kind = function
  | Keeper_toml_loader.Toml_string _ -> "string"
  | Keeper_toml_loader.Toml_int _ -> "integer"
  | Keeper_toml_loader.Toml_float _ -> "float"
  | Keeper_toml_loader.Toml_bool _ -> "boolean"
  | Keeper_toml_loader.Toml_string_array _ -> "string array"
  | Keeper_toml_loader.Toml_array _ -> "array"
  | Keeper_toml_loader.Toml_table _ -> "table"
  | Keeper_toml_loader.Toml_inline_table _ -> "inline table"
  | Keeper_toml_loader.Toml_table_array _ -> "table array"
  | Keeper_toml_loader.Toml_offset_datetime _ -> "offset datetime"
  | Keeper_toml_loader.Toml_local_datetime _ -> "local datetime"
  | Keeper_toml_loader.Toml_local_date _ -> "local date"
  | Keeper_toml_loader.Toml_local_time _ -> "local time"
;;

let validate_known_keeper_field_types doc =
  let string_fields =
    [ "name"; "persona_name"; "instructions"; "sandbox_profile"
    ; "sandbox_image"; "network_mode"; "multimodal_policy" ]
  in
  let bool_fields =
    [ "autoboot_enabled"; "proactive_enabled"; "telemetry_feedback_enabled"
    ; "always_allow" ]
  in
  let int_fields =
    [ "max_context_override"; "telemetry_feedback_window_hours" ]
  in
  let string_array_fields =
    [ "mention_targets"; "allowed_paths"; "active_goal_ids" ]
  in
  let expected key =
    let bare_key = String.sub key 7 (String.length key - 7) in
    if List.mem bare_key string_fields
    then Some ("string", function Keeper_toml_loader.Toml_string _ -> true | _ -> false)
    else if List.mem bare_key bool_fields
    then Some ("boolean", function Keeper_toml_loader.Toml_bool _ -> true | _ -> false)
    else if List.mem bare_key int_fields
    then Some ("integer", function Keeper_toml_loader.Toml_int _ -> true | _ -> false)
    else if List.mem bare_key string_array_fields
    then
      Some
        ( "string array"
        , function Keeper_toml_loader.Toml_string_array _ -> true | _ -> false )
    else None
  in
  doc
  |> List.find_map (fun (key, value) ->
       if String.starts_with key ~prefix:"keeper."
          && not (String.starts_with key ~prefix:oas_env_key_prefix)
       then
         match expected key with
         | Some (expected_kind, accepts) when not (accepts value) ->
           Some
             (Printf.sprintf
                "%s must be a TOML %s, got %s"
                key
                expected_kind
                (toml_value_kind value))
         | Some _ | None -> None
       else if String.starts_with key ~prefix:oas_env_key_prefix
               && Option.is_none (string_of_toml_value_for_env value)
       then
         Some
           (Printf.sprintf
              "%s must be a scalar TOML value, got %s"
              key
              (toml_value_kind value))
       else None)
  |> function None -> Ok () | Some error -> Error error
;;

let profile_defaults_of_toml (doc : Keeper_toml_loader.toml_doc)
    : (keeper_profile_defaults, string) result =
  let k key = "keeper." ^ key in
  let str key = Keeper_toml_loader.toml_string_opt doc (k key) in
  let bool_ key = Keeper_toml_loader.toml_bool_opt doc (k key) in
  let int_ key = Keeper_toml_loader.toml_int_opt doc (k key) in
  let strs key = Keeper_toml_loader.toml_string_list doc (k key) in
  let has key = List.mem_assoc (k key) doc in
  let oas_env = extract_oas_env_from_doc doc in
  let removed_present =
    removed_keeper_input_key_names
    |> List.map k
    |> List.filter (fun key -> List.mem_assoc key doc)
  in
  let result =
    if has "goal" then
      Error
        "keeper.goal is removed. Link Goal entities through active_goal_ids; \
         keeper instructions remain under keeper.instructions."
    else
      match removed_present with
      | [] -> Ok ()
      | fields ->
          Error
            (Printf.sprintf
               "removed keeper TOML keys: %s"
               (String.concat ", " fields))
  in
  let result =
    Result.bind result (fun () ->
        validate_known_keeper_field_types doc)
  in
  let result =
    Result.bind result (fun () ->
        match str "persona_name" with
        | Some raw when not (validate_name raw) ->
            Error (Printf.sprintf "invalid persona_name '%s'" raw)
        | _ -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "sandbox_profile" with
        | Some raw -> (
            match sandbox_profile_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid sandbox_profile '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_sandbox_profile_strings)))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "network_mode" with
        | Some raw -> (
            match network_mode_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid network_mode '%s' (allowed: none, inherit)"
                     raw))
        | None -> Ok ())
  in
  let result =
    Result.bind result (fun () ->
        match str "multimodal_policy" with
        | Some raw -> (
            (* RFC vision-delegation §2.4. Fail loud on an unrecognised value
               rather than silently defaulting (no silent failure). *)
            match multimodal_policy_of_string raw with
            | Some _ -> Ok ()
            | None ->
                Error
                  (Printf.sprintf
                     "invalid multimodal_policy '%s' (allowed: %s)"
                     raw
                     (String.concat ", " valid_multimodal_policy_strings)))
        | None -> Ok ())
  in
  (* persona⊥{model,runtime}: keeper TOML no longer carries a runtime/model
     selection.  keeper→runtime assignment is the sole responsibility of
     runtime.toml [[runtime.assignments]] (keyed by keeper name), resolved via
     {!Runtime.runtime_id_for_keeper}.  Both the legacy [keeper.model] and the
     (now removed) [keeper.runtime_id] keys are rejected at load — fail loud
     rather than silently discard, pointing the operator at the new SSOT.
     BREAKING: a keeper TOML still carrying [runtime_id] fails to load; migrate
     its value to runtime.toml [[runtime.assignments]]. *)
  let runtime_assignment_result =
    let present key = has key in
    match present "model", present "runtime_id" with
    | true, _ | _, true ->
      Error
        "keeper.model / keeper.runtime_id are removed. Assign the keeper's \
         runtime in runtime.toml [[runtime.assignments]] (keyed by keeper name)."
    | false, false -> Ok ()
  in
  let result = Result.bind result (fun () -> runtime_assignment_result) in
  let max_context_override_result =
    match int_ "max_context_override" with
    | None -> Ok None
    | Some value ->
      Keeper_config.validate_max_context_override_value value
      |> Result.map Option.some
  in
  Result.bind result (fun () ->
    Result.map
      (fun max_context_override ->
      {
        id = None;
        manifest_path = None;
        persona_name = str "persona_name";
        instructions = str "instructions";
        autoboot_enabled = bool_ "autoboot_enabled";
        mention_targets = strs "mention_targets";
        proactive_enabled = bool_ "proactive_enabled";
        allowed_paths =
          if has "allowed_paths" then Some (strs "allowed_paths")
          else None;
        sandbox_profile =
          Option.bind (str "sandbox_profile") sandbox_profile_of_string;
        sandbox_image = str "sandbox_image";
        network_mode =
          Option.bind (str "network_mode") network_mode_of_string;
        multimodal_policy =
          Option.bind (str "multimodal_policy") multimodal_policy_of_string;
        active_goal_ids =
          if has "active_goal_ids" then
            Some (normalize_name_list (strs "active_goal_ids"))
          else None;
        max_context_override;
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        always_allow = bool_ "always_allow";
        oas_env;
        unknown_toml_keys = [];
      })
      max_context_override_result)

(** Fields actually read by [profile_defaults_of_toml] from the [[keeper]]
    TOML table.  Keep this in sync with the record construction above — the
    compile-time assertion below will fail if the two lists diverge. *)
let parsed_field_key_names =
  [ "name"
  ; "persona_name"
  ; "instructions"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "multimodal_policy"
  ; "active_goal_ids"
  ; "max_context_override"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "always_allow"
  ]

(** Canonical TOML key names used by [detect_unknown_keeper_toml_keys].
    Keys outside this set under [[keeper]] (or any other table) are silently
    ignored by the loader, which historically let dead config accumulate
    (e.g. legacy [legacy_scope], [scope_kind]).  [warn_unknown_keeper_toml_keys]
    uses this list to surface drift on boot. The JSON side no longer has a
    symmetric warning: [Keeper_meta_json.meta_of_json] decodes only the exact
    current shape, so an unknown persisted key is a decode error there rather
    than a warning.

    Must be kept in sync with [parsed_field_key_names] — the assertion below
    catches drift at compile time. *)
let canonical_keeper_toml_key_names =
  [ "name"
  ; "persona_name"
  ; "instructions"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "multimodal_policy"
  ; "active_goal_ids"
  ; "max_context_override"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "always_allow"
  ]

let () =
  assert (
    List.sort String.compare canonical_keeper_toml_key_names
    = List.sort String.compare parsed_field_key_names)

(** Pure detector: returns TOML keys that [profile_defaults_of_toml] does not
    consume.  Exposed separately from the logging wrapper so tests can
    assert on the key list without mocking the Log subsystem. *)
let detect_unknown_keeper_toml_keys (doc : Keeper_toml_loader.toml_doc) =
  let known =
    canonical_keeper_toml_key_names |> List.map (fun k -> "keeper." ^ k)
  in
  let oas_env_prefix = oas_env_key_prefix in
  let oas_env_prefix_len = String.length oas_env_prefix in
  let starts_with_oas_env k =
    String.length k > oas_env_prefix_len
    && String.starts_with k ~prefix:oas_env_prefix
  in
  doc
  |> List.map fst
  |> List.filter (fun key ->
       not (List.mem key known) && not (starts_with_oas_env key))
  |> dedupe_keep_order

let unknown_keeper_toml_warning_key_limit = 256
let unknown_keeper_toml_warning_keys : string list Atomic.t = Atomic.make []

let current_unknown_keeper_toml_warning_keys () =
  Atomic.get unknown_keeper_toml_warning_keys

let rec take_warning_keys n keys =
  match n, keys with
  | n, _ when n <= 0 -> []
  | _, [] -> []
  | n, key :: rest -> key :: take_warning_keys (n - 1) rest

let normalize_unknown_keeper_toml_keys unknown =
  List.sort_uniq String.compare unknown
;;

let warn_unknown_keeper_toml_keys_once ~path unknown =
  let normalized_unknown = normalize_unknown_keeper_toml_keys unknown in
  let warning_key =
    path ^ "\x1f" ^ String.concat "," normalized_unknown
  in
  let rec loop () =
    let seen = Atomic.get unknown_keeper_toml_warning_keys in
    if List.mem warning_key seen then
      false
    else
      let next =
        take_warning_keys unknown_keeper_toml_warning_key_limit (warning_key :: seen)
      in
      if Atomic.compare_and_set unknown_keeper_toml_warning_keys seen next then
        true
      else
        loop ()
  in
  loop ()

let warn_unknown_keeper_toml_key_names ~path unknown =
  match normalize_unknown_keeper_toml_keys unknown with
  | [] -> ()
  | unknown ->
    if warn_unknown_keeper_toml_keys_once ~path unknown then begin
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_config_unknown_keys_ignored
        ~labels:[("file_path", path)]
        ~delta:(float_of_int (List.length unknown))
        ();
      Log.Keeper.warn
        "keeper TOML %s has unknown keys: %s"
        path
        (String.concat ", " unknown)
    end

let warn_unknown_keeper_toml_keys ~path (doc : Keeper_toml_loader.toml_doc) =
  warn_unknown_keeper_toml_key_names
    ~path
    (detect_unknown_keeper_toml_keys doc)

let merge_string_list ~base overlay =
  match overlay with [] -> base | xs -> xs

let merge_keeper_profile_defaults
    ~(base : keeper_profile_defaults)
    ~(overlay : keeper_profile_defaults) : keeper_profile_defaults =
  let prefer overlay_value base_value =
    match overlay_value with Some _ -> overlay_value | None -> base_value
  in
  {
    id = prefer overlay.id base.id;
    manifest_path = prefer overlay.manifest_path base.manifest_path;
    persona_name = prefer overlay.persona_name base.persona_name;
    instructions = prefer overlay.instructions base.instructions;
    autoboot_enabled = prefer overlay.autoboot_enabled base.autoboot_enabled;
    mention_targets =
      merge_string_list ~base:base.mention_targets overlay.mention_targets;
    proactive_enabled = prefer overlay.proactive_enabled base.proactive_enabled;
    allowed_paths = prefer overlay.allowed_paths base.allowed_paths;
    sandbox_profile = prefer overlay.sandbox_profile base.sandbox_profile;
    sandbox_image = prefer overlay.sandbox_image base.sandbox_image;
    network_mode = prefer overlay.network_mode base.network_mode;
    multimodal_policy = prefer overlay.multimodal_policy base.multimodal_policy;
    active_goal_ids = prefer overlay.active_goal_ids base.active_goal_ids;
    max_context_override =
      prefer overlay.max_context_override base.max_context_override;
    telemetry_feedback_enabled =
      prefer overlay.telemetry_feedback_enabled base.telemetry_feedback_enabled;
    telemetry_feedback_window_hours =
      prefer overlay.telemetry_feedback_window_hours
        base.telemetry_feedback_window_hours;
    always_allow = prefer overlay.always_allow base.always_allow;
    oas_env =
      (let overlay_keys = List.map fst overlay.oas_env in
       let surviving_base =
         List.filter (fun (k, _) -> not (List.mem k overlay_keys)) base.oas_env
       in
       surviving_base @ overlay.oas_env);
    unknown_toml_keys =
      merge_string_list ~base:base.unknown_toml_keys overlay.unknown_toml_keys;
  }
