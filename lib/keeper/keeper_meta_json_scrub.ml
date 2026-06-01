(** Keeper meta JSON removed-field guards.

    Kept below the codec/parser facade so persisted runtime JSON can be
    rejected before strict [keeper_meta] decoding. *)


(* Config fields owned by TOML only. Never written to JSON and rejected from
   persisted runtime JSON.

   Defined here (not in keeper_meta_json.ml) to avoid a cycle:
   keeper_meta_json.ml includes this module, so referencing a value
   defined in keeper_meta_json.ml from here would create
   Keeper_meta_json -> Keeper_meta_json_scrub -> Keeper_meta_json. *)
let config_field_names =
  [ "goal"; "short_goal"; "mid_goal"; "long_goal"
  ; "social_model"; "runtime_id"
  ; "will"; "needs"; "desires"; "instructions"
  ; "sandbox_profile"; "sandbox_image"; "network_mode"; "allowed_paths"
  ; "tool_denylist"
  ; "mention_targets"
  ; "proactive_enabled"; "proactive_idle_sec"; "proactive_cooldown_sec"
  ; "compaction_profile"; "compaction_ratio_gate"
  ; "compaction_message_gate"; "compaction_token_gate"
  ; "continuity_compaction_cooldown_sec"
  ; "max_checkpoint_messages"; "keep_recent_tool_results"
  ; "tool_heavy_msg_threshold"; "tool_heavy_ratio_floor"
  ; "auto_handoff"; "handoff_threshold"; "handoff_cooldown_sec"
  ; "per_provider_timeout_s"; "always_approve"
  ; "autoboot_enabled"; "max_context_override"
  ; "telemetry_feedback_enabled"; "telemetry_feedback_window_hours"
  ]

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = Keeper_config_text.present_json_keys Keeper_config_text.removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error (Printf.sprintf "removed keeper meta fields: %s" (String.concat ", " fields))
;;

let rejected_keeper_meta_tool_policy_key_names =
  [ "tool_preset"; "tool_preset_source"; "tool_also_allow"; "tool_custom_allowlist"; "tool_allowlist" ]
;;

let retired_keeper_meta_key_names =
  let retired_discovery_key suffix = "work_" ^ "discovery" ^ suffix in
  [
    "repo_cli_identity";
    "last_" ^ retired_discovery_key "_ts";
    retired_discovery_key "_count";
    retired_discovery_key "_enabled";
    retired_discovery_key "_sources";
    retired_discovery_key "_interval_sec";
    retired_discovery_key "_guidance";
  ]
;;

let strict_rejected_keeper_meta_key_names =
  [ "allowed_providers"; "last_blocker_class" ]
  @ rejected_keeper_meta_tool_policy_key_names
  @ retired_keeper_meta_key_names
;;

let reject_strict_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = Keeper_config_text.present_json_keys strict_rejected_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "removed keeper meta fields are no longer supported: %s"
         (String.concat ", " fields))
;;

let reject_config_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = Keeper_config_text.present_json_keys config_field_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "config-only keeper meta fields are no longer supported in runtime JSON: %s"
         (String.concat ", " fields))
;;
