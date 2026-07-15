include Keeper_config
include Keeper_types_profile_sandbox
include Keeper_types_profile_defaults
include Keeper_types_profile_toml_normalizers
include Keeper_types_profile_oas_env

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
    let present key =
      match str key with
      | None -> false
      | Some raw -> String.trim raw <> ""
    in
    match present "model", present "runtime_id" with
    | true, _ | _, true ->
      Error
        "keeper.model / keeper.runtime_id are removed. Assign the keeper's \
         runtime in runtime.toml [[runtime.assignments]] (keyed by keeper name)."
    | false, false -> Ok ()
  in
  let legacy_goal_result =
    if has "goal" || has "active_goal_ids" then
      Error "keeper.goal and keeper.active_goal_ids are removed"
    else Ok ()
  in
  let result =
    Result.bind
      (Result.bind result (fun () -> runtime_assignment_result))
      (fun () -> legacy_goal_result)
  in
  Result.map
    (fun () ->
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
        telemetry_feedback_enabled = bool_ "telemetry_feedback_enabled";
        telemetry_feedback_window_hours = int_ "telemetry_feedback_window_hours";
        always_allow = bool_ "always_allow";
        oas_env;
        unknown_toml_keys = [];
      })
    result

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
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "always_allow"
  ]

(** Canonical TOML key names used by [detect_unknown_keeper_toml_keys].
    Keys outside this set under [[keeper]] (or any other table) are silently
    ignored by the loader, which historically let dead config accumulate
    (e.g. legacy [legacy_scope], [scope_kind]).  [warn_unknown_keeper_toml_keys]
    uses this list to surface drift on boot, symmetric with
    [warn_unknown_keeper_meta_keys] on the JSON side.

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
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "always_allow"
  ]

let loader_level_keeper_toml_key_names = [ "base" ]

let () =
  assert (
    List.sort String.compare canonical_keeper_toml_key_names
    = List.sort String.compare parsed_field_key_names)

(** Pure detector: returns TOML keys that [profile_defaults_of_toml] does not
    consume.  Exposed separately from the logging wrapper so tests can
    assert on the key list without mocking the Log subsystem. *)
let detect_unknown_keeper_toml_keys (doc : Keeper_toml_loader.toml_doc) =
  let known =
    (canonical_keeper_toml_key_names @ loader_level_keeper_toml_key_names)
    |> List.map (fun k -> "keeper." ^ k)
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
    ~agent_name
    ~(base : keeper_profile_defaults)
    ~(overlay : keeper_profile_defaults) : keeper_profile_defaults =
  ignore agent_name;
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
