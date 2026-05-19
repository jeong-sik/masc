(** Unknown keeper TOML key detection and once-per-path warning state. *)

module Oas_env = Keeper_types_profile_oas_env

let oas_env_key_prefix = Oas_env.oas_env_key_prefix

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then false
      else (
        Hashtbl.add seen item ();
        true))
    items

(** Fields actually read by [profile_defaults_of_toml] from the [[keeper]]
    TOML table.  Keep this in sync with the record construction above — the
    compile-time assertion below will fail if the two lists diverge. *)
let parsed_field_key_names =
  [ "name"
  ; "persona_name"
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "room_signal_prompt_enabled"
  ; "shards"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "github_identity"
  ; "git_identity_mode"
  ; "tool_access.kind"
  ; "tool_access.preset"
  ; "tool_access.also_allow"
  ; "tool_access.tools"
  ; "tool_denylist"
  ; "active_goal_ids"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout"
  ; "always_approve"
  ; "max_turns_per_call"
  ; "max_turns_per_call_scheduled_autonomous"
  ; "social_model"
  ; "cascade_name"
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
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "autoboot_enabled"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "room_signal_prompt_enabled"
  ; "shards"
  ; "allowed_paths"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "github_identity"
  ; "git_identity_mode"
  ; "tool_access.kind"
  ; "tool_access.preset"
  ; "tool_access.also_allow"
  ; "tool_access.tools"
  ; "tool_denylist"
  ; "active_goal_ids"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout"
  ; "always_approve"
  ; "max_turns_per_call"
  ; "max_turns_per_call_scheduled_autonomous"
  ; "social_model"
  ; "cascade_name"
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

let warn_unknown_keeper_toml_keys ~path (doc : Keeper_toml_loader.toml_doc) =
  match detect_unknown_keeper_toml_keys doc with
  | [] -> ()
  | unknown ->
    let unknown = normalize_unknown_keeper_toml_keys unknown in
    if warn_unknown_keeper_toml_keys_once ~path unknown then begin
      Prometheus.inc_counter
        Prometheus.metric_config_unknown_keys_ignored
        ~labels:[("file_path", path)]
        ~delta:(float_of_int (List.length unknown))
        ();
      Log.Keeper.warn
        "keeper TOML %s has unknown keys: %s"
        path
        (String.concat ", " unknown)
    end
