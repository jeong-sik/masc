(** Keeper_types — shared keeper contract, registry/store helpers,
    path resolution, and model-selection utilities. *)

(* Utility functions, canonical helpers, profile defaults, and dir helpers
   extracted to Keeper_types_profile *)
include Keeper_types_profile

(* Policy/runtime/meta contract and pure helpers extracted from the
   store/JSON facade. Keeper_types includes this module for API
   compatibility. *)
include Keeper_meta_contract

let runtime_meta_write_sync_hook : (Coord.config -> keeper_meta -> unit) ref =
  ref (fun _ _ -> ())
;;

let register_runtime_meta_write_sync f = runtime_meta_write_sync_hook := f

let reject_legacy_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    keeper_legacy_model_arg_names
    |> List.filter (fun key ->
      match Yojson.Safe.Util.member key args with
      | `Null -> false
      | _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper model args removed for %s: %s. Keepers now use cascade_name and \
          last_model_used only."
         tool_name
         (String.concat ", " fields))
;;

let drop_assoc_keys (keys : string list) (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
  | _ -> json
;;

let reject_removed_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys removed_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error (Printf.sprintf "removed keeper meta fields: %s" (String.concat ", " fields))
;;

let legacy_keeper_meta_tool_policy_key_names =
  [ "tool_preset"; "tool_also_allow"; "tool_custom_allowlist"; "tool_allowlist" ]
;;

let legacy_keeper_meta_key_names =
  "allowed_providers" :: legacy_keeper_meta_tool_policy_key_names
;;

let reject_legacy_keeper_meta_fields (json : Yojson.Safe.t) =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper meta fields require scrub via read_meta_file_path: %s"
         (String.concat ", " fields))
;;

let legacy_tool_access_kind_needs_scrub (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Assoc _ as access_json ->
    (match
       Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
     with
     | Some "restricted" | Some "unrestricted" -> true
     | _ -> false)
  | _ -> false
;;

let scrub_legacy_tool_policy_meta_json (json : Yojson.Safe.t) : Yojson.Safe.t * string list =
  let present = present_json_keys legacy_keeper_meta_key_names json in
  let missing_tool_access = not (json_member_present "tool_access" json) in
  let legacy_tool_access_kind = legacy_tool_access_kind_needs_scrub json in
  let needs_tool_access_rewrite =
    present <> [] || missing_tool_access || legacy_tool_access_kind
  in
  if not needs_tool_access_rewrite
  then json, []
  else
    match legacy_tool_access_of_meta_json json with
    | Error _ ->
      let dropped =
        present |> List.filter (fun key -> String.equal key "allowed_providers")
      in
      if dropped = []
      then json, []
      else
        (drop_assoc_keys dropped json, dropped)
    | Ok tool_access ->
      let rewrite_reasons =
        (if missing_tool_access then [ "tool_access(defaulted)" ] else [])
        @ (if legacy_tool_access_kind then [ "tool_access(legacy-kind)" ] else [])
        @ present
      in
      let base = drop_assoc_keys legacy_keeper_meta_key_names json in
      let scrubbed =
        match base with
        | `Assoc fields ->
          `Assoc
            (("tool_access", tool_access_to_json tool_access)
             :: List.remove_assoc "tool_access" fields)
        | _ -> base
      in
      scrubbed, rewrite_reasons
;;

let scrub_persisted_keeper_meta_json ~path (json : Yojson.Safe.t) : Yojson.Safe.t * bool =
  let json, legacy_tool_policy_rewrites = scrub_legacy_tool_policy_meta_json json in
  match json with
  | `Assoc fields ->
    let removed_present =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key removed_keeper_meta_key_names then Some key else None)
    in
    if removed_present = [] && legacy_tool_policy_rewrites = []
    then json, false
    else (
      let migrate_legacy_disabled_keepalive =
        (match List.assoc_opt "presence_keepalive" fields with
         | Some (`Bool false) -> true
         | _ -> false)
        && not (List.mem_assoc "paused" fields)
      in
      let scrubbed =
        let base = drop_assoc_keys removed_keeper_meta_key_names json in
        match base with
        | `Assoc base_fields when migrate_legacy_disabled_keepalive ->
          `Assoc (("paused", `Bool true) :: List.remove_assoc "paused" base_fields)
        | _ -> base
      in
      let content = Yojson.Safe.pretty_to_string scrubbed in
      (try
         Fs_compat.save_file path content;
         Log.Keeper.info
           "scrubbed legacy keeper meta fields for %s: %s%s"
           path
           (String.concat ", " (legacy_tool_policy_rewrites @ removed_present))
           (if migrate_legacy_disabled_keepalive
            then " (migrated presence_keepalive=false to paused=true)"
            else "")
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn
           "failed to scrub removed keeper meta fields for %s: %s"
           path
           (Printexc.to_string exn));
      scrubbed, true)
  | _ -> json, false
;;

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  let rt = m.runtime in
  `Assoc
    [ "name", `String m.name
    ; "agent_name", `String m.agent_name
    ; "trace_id", `String (Keeper_id.Trace_id.to_string rt.trace_id)
    ; "trace_history", `List (List.map (fun s -> `String s) rt.trace_history)
    ; "goal", `String m.goal
    ; "short_goal", `String m.short_goal
    ; "mid_goal", `String m.mid_goal
    ; "long_goal", `String m.long_goal
    
    ; "social_model", `String m.social_model
    ; "cascade_name", `String m.cascade_name
    (* "models" intentionally omitted from serialization.  The field
       is in removed_keeper_meta_key_names (via removed_keeper_input_key_names)
       and scrub_persisted_keeper_meta_json strips it on every load.
       Re-emitting it here creates a scrub → write → re-scrub loop that
       fires ~20 INFO log lines per keeper per session.  Models are
       resolved at runtime from cascade config, not from persisted meta. *)
    ; "will", `String m.will
    ; "needs", `String m.needs
    ; "desires", `String m.desires
    ; "instructions", `String m.instructions
    ; "policy_voice_enabled", `Bool m.policy_voice_enabled
    ; "sandbox_profile", `String (sandbox_profile_to_string m.sandbox_profile)
    ; "network_mode", `String (network_mode_to_string m.network_mode)
    ; "shared_memory_scope", `String (shared_memory_scope_to_string m.shared_memory_scope)
    ; "allowed_paths", `List (List.map (fun s -> `String s) m.allowed_paths)
    ; "tool_access", tool_access_to_json m.tool_access
    ; "tool_preset_source", Json_util.string_opt_to_json m.tool_preset_source
    ; "tool_denylist", `List (List.map (fun s -> `String s) m.tool_denylist)
    ; "mention_targets", `List (List.map (fun s -> `String s) m.mention_targets)
    ; "room_signal_prompt_enabled", `Bool m.room_signal_prompt_enabled
    ; "joined_room_ids", `List (List.map (fun s -> `String s) m.joined_room_ids)
    ; "last_seen_seq_by_room", room_seq_map_to_json m.last_seen_seq_by_room
    ; "generation", `Int rt.generation
    ; "proactive_enabled", `Bool m.proactive.enabled
    ; "proactive_idle_sec", `Int m.proactive.idle_sec
    ; "proactive_cooldown_sec", `Int m.proactive.cooldown_sec
    ; "compaction_profile", `String m.compaction.profile
    ; "compaction_ratio_gate", `Float m.compaction.ratio_gate
    ; "compaction_message_gate", `Int m.compaction.message_gate
    ; "compaction_token_gate", `Int m.compaction.token_gate
    ; "continuity_compaction_cooldown_sec", `Int m.compaction.cooldown_sec
    ; "max_checkpoint_messages", `Int m.compaction.max_checkpoint_messages
    ; "auto_handoff", `Bool m.auto_handoff
    ; "handoff_threshold", `Float m.handoff_threshold
    ; "handoff_cooldown_sec", `Int m.handoff_cooldown_sec
    ; "voice_enabled", `Bool m.voice_enabled
    ; "voice_channel", `String m.voice_channel
    ; "voice_agent_id", `String m.voice_agent_id
    ; "last_handoff_ts", `Float rt.last_handoff_ts
    ; "created_at", `String m.created_at
    ; "updated_at", `String m.updated_at
    ; "total_turns", `Int rt.usage.total_turns
    ; "total_input_tokens", `Int rt.usage.total_input_tokens
    ; "total_output_tokens", `Int rt.usage.total_output_tokens
    ; "total_tokens", `Int rt.usage.total_tokens
    ; "total_cost_usd", `Float rt.usage.total_cost_usd
    ; "last_turn_ts", `Float rt.usage.last_turn_ts
    ; "last_model_used", `String rt.usage.last_model_used
    ; "last_input_tokens", `Int rt.usage.last_input_tokens
    ; "last_output_tokens", `Int rt.usage.last_output_tokens
    ; "last_total_tokens", `Int rt.usage.last_total_tokens
    ; "last_latency_ms", `Int rt.usage.last_latency_ms
    ; "compaction_count", `Int rt.compaction_rt.count
    ; "last_compaction_ts", `Float rt.compaction_rt.last_ts
    ; "last_compaction_before_tokens", `Int rt.compaction_rt.last_before_tokens
    ; "last_compaction_after_tokens", `Int rt.compaction_rt.last_after_tokens
    ; "proactive_count_total", `Int rt.proactive_rt.count_total
    ; "last_proactive_ts", `Float rt.proactive_rt.last_ts
    ; "proactive_visible_count_total", `Int rt.proactive_rt.visible_count_total
    ; "last_visible_proactive_ts", `Float rt.proactive_rt.last_visible_ts
    ; ( "last_proactive_outcome"
      , `String (proactive_cycle_outcome_to_string rt.proactive_rt.last_outcome) )
    ; "last_proactive_reason", `String rt.proactive_rt.last_reason
    ; "last_proactive_preview", `String rt.proactive_rt.last_preview
    ; "last_work_discovery_ts", `Float rt.proactive_rt.last_work_discovery_ts
    ; "work_discovery_count", `Int rt.proactive_rt.work_discovery_count
    ; "consecutive_noop_count", `Int rt.proactive_rt.consecutive_noop_count
    ; "last_compaction_check_ts", `Float rt.compaction_rt.last_check_ts
    ; "last_compaction_decision", `String rt.compaction_rt.last_decision
    ; "last_continuity_update_ts", `Float rt.last_continuity_update_ts
    ; "continuity_summary", `String m.continuity_summary
    ; "active_goal_ids", `List (List.map (fun s -> `String s) m.active_goal_ids)
    ; "last_autonomous_action_at", `String rt.last_autonomous_action_at
    ; "autonomous_action_count", `Int rt.autonomous_action_count
    ; "autonomous_turn_count", `Int rt.autonomous_turn_count
    ; "autonomous_text_turn_count", `Int rt.autonomous_text_turn_count
    ; "autonomous_tool_turn_count", `Int rt.autonomous_tool_turn_count
    ; "board_reactive_turn_count", `Int rt.board_reactive_turn_count
    ; "mention_reactive_turn_count", `Int rt.mention_reactive_turn_count
    ; "noop_turn_count", `Int rt.noop_turn_count
    ; "consecutive_noop_count", `Int rt.consecutive_noop_count
    ; "last_speech_act", `String rt.last_speech_act
    ; "last_social_transition_reason", `String rt.last_social_transition_reason
    ; "last_active_desire", `String rt.last_active_desire
    ; "last_current_intention", `String rt.last_current_intention
    ; "last_blocker", `String rt.last_blocker
    ; "last_blocker_class", (match rt.last_blocker_class with
        | Some bc -> `String (blocker_class_to_string bc)
        | None -> `Null)
    ; "last_need", `String rt.last_need
    ; "paused", `Bool m.paused
    ; "autoboot_enabled", `Bool m.autoboot_enabled
    ; "current_task_id", Json_util.string_opt_to_json (Option.map Keeper_id.Task_id.to_string m.current_task_id)
    ; "max_context_override", Json_util.int_opt_to_json m.max_context_override
    ; "work_discovery_enabled", Json_util.bool_opt_to_json m.work_discovery_enabled
    ; "work_discovery_sources"
      , (match m.work_discovery_sources with
         | Some xs -> `List (List.map (fun s -> `String s) xs)
         | None -> `Null)
    ; "work_discovery_interval_sec", Json_util.int_opt_to_json m.work_discovery_interval_sec
    ; "work_discovery_guidance", Json_util.string_opt_to_json m.work_discovery_guidance
    ; "telemetry_feedback_enabled", Json_util.bool_opt_to_json m.telemetry_feedback_enabled
    ; "telemetry_feedback_window_hours", Json_util.int_opt_to_json m.telemetry_feedback_window_hours
    ; "per_provider_timeout_s", Json_util.float_opt_to_json m.per_provider_timeout_s
    ; "always_approve", Json_util.bool_opt_to_json m.always_approve
    ; "keeper_id", (match m.keeper_id with
      | Some uid -> Keeper_id.uid_to_yojson uid
      | None -> `Null)
    ; "oas_env", `Assoc (List.map (fun (k, v) -> (k, `String v)) m.oas_env)
    ; "meta_version", `Int m.meta_version
    ]
;;

type parsed_keeper_identity =
  { pk_name : string
  ; pk_agent_name : string
  ; pk_trace_id : Keeper_id.Trace_id.t
  ; pk_trace_history : string list
  ; pk_goal : string
  ; pk_short_goal : string
  ; pk_mid_goal : string
  ; pk_long_goal : string
  
  ; pk_social_model : string
  ; pk_cascade_name : string
  ; pk_models : string list
  ; pk_will : string
  ; pk_needs : string
  ; pk_desires : string
  ; pk_instructions : string
  }

type parsed_keeper_policy =
  { pp_policy_voice_enabled : bool
  ; pp_sandbox_profile : sandbox_profile
  ; pp_network_mode : network_mode
  ; pp_shared_memory_scope : shared_memory_scope
  ; pp_allowed_paths : string list
  ; pp_tool_access : tool_access
  ; pp_tool_denylist : string list
  ; pp_mention_targets : string list
  ; pp_room_signal_prompt_enabled : bool
  ; pp_joined_room_ids : string list
  ; pp_last_seen_seq_by_room : (string * int) list
  ; pp_proactive : proactive_policy
  ; pp_compaction : compaction_policy
  ; pp_auto_handoff : bool
  ; pp_handoff_threshold : float
  ; pp_handoff_cooldown_sec : int
  ; pp_voice_enabled : bool
  ; pp_voice_channel : string
  ; pp_voice_agent_id : string
  ; pp_per_provider_timeout_s : float option
  ; pp_always_approve : bool option
  }

type parsed_keeper_state =
  { ps_created_at_raw : string
  ; ps_updated_at_raw : string
  ; ps_continuity_summary : string
  ; ps_active_goal_ids : string list
  ; ps_paused : bool
  ; ps_autoboot_enabled : bool
  ; ps_current_task_id : Keeper_id.Task_id.t option
  ; ps_max_context_override : int option
  ; ps_runtime : agent_runtime_state
  }

let parse_keeper_identity (json : Yojson.Safe.t)
    : (parsed_keeper_identity, string) result =
  let ident = Keeper_identity.parse_json_identity json in
  let pk_name = ident.keeper_name in
  let pk_agent_name = ident.agent_name in
  let pk_trace_id_raw = Option.value ~default:"" ident.trace_id in
  match
    if String.trim pk_trace_id_raw = "" then
      Error "missing trace_id in persisted keeper identity"
    else
      match Keeper_id.Trace_id.of_string pk_trace_id_raw with
      | Ok x -> Ok x
      | Error err ->
        Error
          ("invalid trace_id in persisted keeper identity: " ^ err)
  with
  | Error e -> Error ("keeper meta parse error: " ^ e)
  | Ok pk_trace_id ->
  let pk_trace_history =
    Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
  in
  let pk_goal =
    Safe_ops.json_string ~default:"" "goal" json |> normalize_goal_horizon_text
  in
  let pk_short_goal, pk_mid_goal, pk_long_goal =
    resolve_goal_horizons
      ~goal:pk_goal
      ~short_goal_opt:
        (normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" json))
      ~mid_goal_opt:
        (normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" json))
      ~long_goal_opt:
        (normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" json))
  in
  let pk_social_model =
    Safe_ops.json_string ~default:(Env_config_core.keeper_social_model ()) "social_model" json
  in
  let pk_will =
    Safe_ops.json_string ~default:(Env_config_core.keeper_will ()) "will" json
    |> normalize_self_model_text
  in
  let pk_needs =
    Safe_ops.json_string ~default:(Env_config_core.keeper_needs ()) "needs" json
    |> normalize_self_model_text
  in
  let pk_desires =
    Safe_ops.json_string ~default:(Env_config_core.keeper_desires ()) "desires" json
    |> normalize_self_model_text
  in
  let pk_instructions = Safe_ops.json_string ~default:"" "instructions" json in
  let pk_cascade_name =
    (* Preserve the raw cascade_name as persisted in runtime JSON so the
       dashboard can distinguish "declared in TOML" from "canonicalized
       fallback".  Downstream code canonicalizes at point-of-use. *)
    Safe_ops.json_string ~default:Keeper_config.default_cascade_name "cascade_name" json
  in
  let pk_models =
    match json |> Yojson.Safe.Util.member "models" with
    | `List items ->
      List.filter_map
        (function `String s -> Some (String.trim s) | _ -> None)
        items
    | _ -> []
  in
  Ok { pk_name
  ; pk_agent_name
  ; pk_trace_id
  ; pk_trace_history
  ; pk_goal
  ; pk_short_goal
  ; pk_mid_goal
  ; pk_long_goal
  ; pk_social_model
  ; pk_cascade_name
  ; pk_models
  ; pk_will
  ; pk_needs
  ; pk_desires
  ; pk_instructions
  }
;;

let parse_keeper_policy (json : Yojson.Safe.t) ~(keeper_name : string)
  : (parsed_keeper_policy, string) result
  =
  let voice_enabled_default = default_voice_enabled_for keeper_name in
  match tool_access_of_meta_json json with
  | Error msg -> Error ("meta parse error: " ^ msg)
  | Ok pp_tool_access ->
    let pp_policy_voice_enabled =
      Safe_ops.json_bool ~default:voice_enabled_default "policy_voice_enabled" json
    in
    let pp_sandbox_profile =
      let raw =
        Safe_ops.json_string
          ~default:(sandbox_profile_to_string default_sandbox_profile)
          "sandbox_profile" json
      in
      Option.value ~default:default_sandbox_profile
        (sandbox_profile_of_string raw)
    in
    let pp_network_mode =
      let fallback = default_network_mode_for_profile pp_sandbox_profile in
      let raw =
        Safe_ops.json_string
          ~default:(network_mode_to_string fallback)
          "network_mode" json
      in
      Option.value ~default:fallback (network_mode_of_string raw)
    in
    let pp_shared_memory_scope =
      let raw =
        Safe_ops.json_string
          ~default:(shared_memory_scope_to_string default_shared_memory_scope)
          "shared_memory_scope" json
      in
      Option.value ~default:default_shared_memory_scope
        (shared_memory_scope_of_string raw)
    in
    let pp_allowed_paths = Safe_ops.json_string_list "allowed_paths" json in
    let pp_tool_denylist = Safe_ops.json_string_list "tool_denylist" json in
    let pp_mention_targets =
      Safe_ops.json_string_list "mention_targets" json |> dedupe_keep_order
    in
    let pp_room_signal_prompt_enabled =
      Safe_ops.json_bool
        ~default:default_room_signal_prompt_enabled
        "room_signal_prompt_enabled"
        json
    in
    let pp_joined_room_ids =
      Safe_ops.json_string_list "joined_room_ids" json
      |> List.filter validate_name
      |> dedupe_keep_order
    in
    let pp_last_seen_seq_by_room =
      Yojson.Safe.Util.member "last_seen_seq_by_room" json |> room_seq_map_of_json
    in
    let proactive_enabled =
      Safe_ops.json_bool ~default:default_proactive_enabled "proactive_enabled" json
    in
    let proactive_idle_sec =
      Safe_ops.json_int ~default:default_proactive_idle_sec "proactive_idle_sec" json
      |> normalize_proactive_idle_sec
    in
    let proactive_cooldown_sec =
      Safe_ops.json_int
        ~default:default_proactive_cooldown_sec
        "proactive_cooldown_sec"
        json
      |> normalize_proactive_cooldown_sec
    in
    let env_ratio_gate, env_message_gate, env_token_gate =
      keeper_compaction_policy_from_env ()
    in
    let compaction_profile =
      Safe_ops.json_string ~default:default_compaction_profile "compaction_profile" json
      |> canonical_compaction_profile
      |> Option.value ~default:default_compaction_profile
    in
    let compaction_ratio_gate =
      Safe_ops.json_float ~default:env_ratio_gate "compaction_ratio_gate" json
      |> normalize_compaction_ratio_gate
    in
    let compaction_message_gate =
      Safe_ops.json_int ~default:env_message_gate "compaction_message_gate" json
      |> normalize_compaction_message_gate
    in
    let compaction_token_gate =
      Safe_ops.json_int ~default:env_token_gate "compaction_token_gate" json
      |> normalize_compaction_token_gate
    in
    let continuity_compaction_cooldown_sec =
      Safe_ops.json_int
        ~default:(keeper_continuity_compaction_cooldown_sec ())
        "continuity_compaction_cooldown_sec"
        json
      |> normalize_continuity_compaction_cooldown_sec
    in
    let pp_auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
    let pp_handoff_threshold =
      Safe_ops.json_float ~default:0.85 "handoff_threshold" json
    in
    let pp_handoff_cooldown_sec =
      Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json
    in
    let pp_voice_enabled =
      Safe_ops.json_bool ~default:voice_enabled_default "voice_enabled" json
    in
    let pp_voice_channel =
      Safe_ops.json_string
        ~default:(default_voice_channel_for keeper_name)
        "voice_channel"
        json
      |> canonical_voice_channel
    in
    let pp_voice_agent_id =
      Safe_ops.json_string
        ~default:(default_voice_agent_id_for keeper_name)
        "voice_agent_id"
        json
    in
    let pp_per_provider_timeout_s =
      normalize_per_provider_timeout_json_field
        ~source:(Printf.sprintf "keeper meta %s" keeper_name)
        ~field:"per_provider_timeout_s"
        json
    in
    let pp_always_approve =
      Safe_ops.json_bool_opt "always_approve" json
    in
    Ok
      { pp_policy_voice_enabled
      ; pp_sandbox_profile
      ; pp_network_mode
      ; pp_shared_memory_scope
      ; pp_allowed_paths
      ; pp_tool_access
      ; pp_tool_denylist
      ; pp_mention_targets
      ; pp_room_signal_prompt_enabled
      ; pp_joined_room_ids
      ; pp_last_seen_seq_by_room
      ; pp_proactive =
          { enabled = proactive_enabled
          ; idle_sec = proactive_idle_sec
          ; cooldown_sec = proactive_cooldown_sec
          }
      ; pp_compaction =
          { profile = compaction_profile
          ; ratio_gate = compaction_ratio_gate
          ; message_gate = compaction_message_gate
          ; token_gate = compaction_token_gate
          ; cooldown_sec = continuity_compaction_cooldown_sec
          ; max_checkpoint_messages =
              Safe_ops.json_int ~default:120 "max_checkpoint_messages" json
          }
      ; pp_auto_handoff
      ; pp_handoff_threshold
      ; pp_handoff_cooldown_sec
      ; pp_voice_enabled
      ; pp_voice_channel
      ; pp_voice_agent_id
      ; pp_per_provider_timeout_s
      ; pp_always_approve
      }
;;

let parse_usage_metrics (json : Yojson.Safe.t) : usage_metrics =
  { total_turns = Safe_ops.json_int ~default:0 "total_turns" json
  ; total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json
  ; total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json
  ; total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json
  ; total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json
  ; last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json
  ; last_model_used = Safe_ops.json_string ~default:"" "last_model_used" json
  ; last_input_tokens = Safe_ops.json_int ~default:0 "last_input_tokens" json
  ; last_output_tokens = Safe_ops.json_int ~default:0 "last_output_tokens" json
  ; last_total_tokens = Safe_ops.json_int ~default:0 "last_total_tokens" json
  ; last_latency_ms = Safe_ops.json_int ~default:0 "last_latency_ms" json
  }
;;

let parse_compaction_runtime (json : Yojson.Safe.t) : compaction_runtime =
  { count = Safe_ops.json_int ~default:0 "compaction_count" json
  ; last_ts = Safe_ops.json_float ~default:0.0 "last_compaction_ts" json
  ; last_before_tokens = Safe_ops.json_int ~default:0 "last_compaction_before_tokens" json
  ; last_after_tokens = Safe_ops.json_int ~default:0 "last_compaction_after_tokens" json
  ; last_check_ts = Safe_ops.json_float ~default:0.0 "last_compaction_check_ts" json
  ; last_decision =
      Safe_ops.json_string ~default:"uninitialized" "last_compaction_decision" json
  }
;;

let parse_proactive_runtime (json : Yojson.Safe.t) : proactive_runtime =
  let count_total = Safe_ops.json_int ~default:0 "proactive_count_total" json in
  let last_ts = Safe_ops.json_float ~default:0.0 "last_proactive_ts" json in
  { count_total
  ; last_ts
  ; visible_count_total =
      Safe_ops.json_int
        ~default:0
        "proactive_visible_count_total"
        json
  ; last_visible_ts =
      Safe_ops.json_float
        ~default:0.0
        "last_visible_proactive_ts"
        json
  ; last_outcome =
      Safe_ops.json_string_opt "last_proactive_outcome" json
      |> Option.value ~default:"unknown"
      |> proactive_cycle_outcome_of_string
  ; last_reason = Safe_ops.json_string ~default:"" "last_proactive_reason" json
  ; last_preview = Safe_ops.json_string ~default:"" "last_proactive_preview" json
  ; last_work_discovery_ts =
      Safe_ops.json_float ~default:0.0 "last_work_discovery_ts" json
  ; work_discovery_count =
      Safe_ops.json_int ~default:0 "work_discovery_count" json
  ; consecutive_noop_count =
      Safe_ops.json_int ~default:0 "consecutive_noop_count" json
  }
;;

let parse_last_continuity_update_ts ~(continuity_summary : string) (json : Yojson.Safe.t) =
  let parsed_ts = Safe_ops.json_float ~default:0.0 "last_continuity_update_ts" json in
  if parsed_ts <= 0.0 && String.trim continuity_summary <> ""
  then Time_compat.now ()
  else parsed_ts
;;

let parse_keeper_state
      (json : Yojson.Safe.t)
      ~(trace_id : Keeper_id.Trace_id.t)
      ~(trace_history : string list)
  : parsed_keeper_state
  =
  let generation = Safe_ops.json_int ~default:0 "generation" json in
  let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
  let ps_created_at_raw = Safe_ops.json_string ~default:"" "created_at" json in
  let ps_updated_at_raw = Safe_ops.json_string ~default:"" "updated_at" json in
  let ps_continuity_summary =
    Safe_ops.json_string ~default:"" "continuity_summary" json
  in
  let last_continuity_update_ts =
    parse_last_continuity_update_ts ~continuity_summary:ps_continuity_summary json
  in
  let ps_active_goal_ids = Safe_ops.json_string_list "active_goal_ids" json in
  let last_autonomous_action_at =
    Safe_ops.json_string ~default:"" "last_autonomous_action_at" json
  in
  let autonomous_action_count =
    Safe_ops.json_int ~default:0 "autonomous_action_count" json
  in
  let autonomous_turn_count = Safe_ops.json_int ~default:0 "autonomous_turn_count" json in
  let autonomous_text_turn_count =
    Safe_ops.json_int ~default:0 "autonomous_text_turn_count" json
  in
  let autonomous_tool_turn_count =
    Safe_ops.json_int ~default:0 "autonomous_tool_turn_count" json
  in
  let board_reactive_turn_count =
    Safe_ops.json_int ~default:0 "board_reactive_turn_count" json
  in
  let mention_reactive_turn_count =
    Safe_ops.json_int ~default:0 "mention_reactive_turn_count" json
  in
  let noop_turn_count = Safe_ops.json_int ~default:0 "noop_turn_count" json in
  let consecutive_noop_count = Safe_ops.json_int ~default:0 "consecutive_noop_count" json in
  let last_speech_act = Safe_ops.json_string ~default:"" "last_speech_act" json in
  let last_social_transition_reason =
    Safe_ops.json_string ~default:"" "last_social_transition_reason" json
  in
  (* Gen12: cap narrative fields on load so pre-Gen8 checkpoints
     (written before the write-side cap) cannot bleed unbounded
     strings back into meta.runtime. Same budget as cap_social_state. *)
  let cap_loaded =
    Keeper_social_model_types.truncate_string
      ~max_chars:Keeper_social_model_types.default_option_field_max_chars
  in
  let last_active_desire =
    cap_loaded (Safe_ops.json_string ~default:"" "last_active_desire" json)
  in
  let last_current_intention =
    cap_loaded (Safe_ops.json_string ~default:"" "last_current_intention" json)
  in
  (* #9933: blocker may carry a structured [masc_oas_error] JSON
     payload. cap_loaded (narrative budget = 200 chars) would slice
     the JSON mid-key and lose diagnostic fields (budget_sec,
     keeper_turn_timeout_sec, estimated_input_tokens, source).
     cap_blocker preserves structured payloads up to
     masc_oas_error_max_chars and falls through to the narrative
     budget for plain text. Symmetric with the write side in
     Keeper_social_model_types.cap_social_state. *)
  let last_blocker =
    Keeper_social_model_types.cap_blocker
      (Safe_ops.json_string ~default:"" "last_blocker" json)
  in
  let last_blocker_class =
    match Safe_ops.json_string_opt "last_blocker_class" json with
    | Some raw -> blocker_class_of_serialized_string raw
    | None -> None
  in
  let last_need =
    cap_loaded (Safe_ops.json_string ~default:"" "last_need" json)
  in
  let ps_paused = Safe_ops.json_bool ~default:false "paused" json in
  let ps_autoboot_enabled =
    Safe_ops.json_bool ~default:true "autoboot_enabled" json
  in
  let ps_current_task_id = match Safe_ops.json_string_opt "current_task_id" json with None -> None | Some s -> (match Keeper_id.Task_id.of_string s with Ok tid -> Some tid | Error _ -> None) in
  let ps_max_context_override = Safe_ops.json_int_opt "max_context_override" json in
  { ps_created_at_raw
  ; ps_updated_at_raw
  ; ps_continuity_summary
  ; ps_active_goal_ids
  ; ps_paused
  ; ps_autoboot_enabled
  ; ps_current_task_id
  ; ps_max_context_override
  ; ps_runtime =
      { usage = parse_usage_metrics json
      ; compaction_rt = parse_compaction_runtime json
      ; proactive_rt = parse_proactive_runtime json
      ; generation
      ; trace_id
      ; trace_history
      ; last_handoff_ts
      ; last_continuity_update_ts
      ; last_autonomous_action_at
      ; autonomous_action_count
      ; autonomous_turn_count
      ; autonomous_text_turn_count
      ; autonomous_tool_turn_count
      ; board_reactive_turn_count
      ; mention_reactive_turn_count
      ; noop_turn_count
      ; consecutive_noop_count
      ; last_speech_act
      ; last_social_transition_reason
      ; last_active_desire
      ; last_current_intention
      ; last_blocker
      ; last_blocker_class
      ; last_need
      }
  }
;;

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    match reject_removed_keeper_meta_fields json with
    | Error e -> Error e
    | Ok () -> (
      match reject_legacy_keeper_meta_fields json with
      | Error e -> Error e
      | Ok () ->
      (match parse_keeper_identity json with
       | Error _ as e -> e
       | Ok identity ->
      match parse_keeper_policy json ~keeper_name:identity.pk_name with
       | Error _ as e -> e
       | Ok policy ->
         let state =
           parse_keeper_state
             json
             ~trace_id:identity.pk_trace_id
             ~trace_history:identity.pk_trace_history
         in
         if not (validate_name identity.pk_name)
         then Error "invalid keeper meta (bad name)"
         else if not (validate_name (Keeper_id.Trace_id.to_string identity.pk_trace_id))
         then Error "invalid keeper meta (bad trace_id)"
         else
           Ok
             { id = None
             ; name = identity.pk_name
             ; agent_name =
                 (if identity.pk_agent_name = ""
                  then keeper_agent_name identity.pk_name
                  else identity.pk_agent_name)
             ; goal = identity.pk_goal
             ; short_goal = identity.pk_short_goal
             ; mid_goal = identity.pk_mid_goal
             ; long_goal = identity.pk_long_goal
             ; social_model = identity.pk_social_model
             ; cascade_name = identity.pk_cascade_name
             ; models = identity.pk_models
             ; will = identity.pk_will
             ; needs = identity.pk_needs
             ; desires = identity.pk_desires
             ; instructions = identity.pk_instructions
             ; policy_voice_enabled = policy.pp_policy_voice_enabled
             ; sandbox_profile = policy.pp_sandbox_profile
             ; network_mode = policy.pp_network_mode
             ; shared_memory_scope = policy.pp_shared_memory_scope
             ; allowed_paths = policy.pp_allowed_paths
             ; tool_access = policy.pp_tool_access
             ; tool_preset_source = Safe_ops.json_string_opt "tool_preset_source" json
             ; tool_denylist = policy.pp_tool_denylist
             ; mention_targets = policy.pp_mention_targets
             ; room_signal_prompt_enabled = policy.pp_room_signal_prompt_enabled
             ; joined_room_ids = policy.pp_joined_room_ids
             ; last_seen_seq_by_room = policy.pp_last_seen_seq_by_room
             ; proactive = policy.pp_proactive
             ; compaction = policy.pp_compaction
             ; auto_handoff = policy.pp_auto_handoff
             ; handoff_threshold = policy.pp_handoff_threshold
             ; handoff_cooldown_sec = policy.pp_handoff_cooldown_sec
             ; voice_enabled = policy.pp_voice_enabled
             ; voice_channel = policy.pp_voice_channel
             ; voice_agent_id = policy.pp_voice_agent_id
             ; per_provider_timeout_s = policy.pp_per_provider_timeout_s
             ; always_approve = policy.pp_always_approve
             ; created_at =
                 (if state.ps_created_at_raw = ""
                  then now_iso ()
                  else state.ps_created_at_raw)
             ; updated_at =
                 (if state.ps_updated_at_raw = ""
                  then now_iso ()
                  else state.ps_updated_at_raw)
             ; continuity_summary = state.ps_continuity_summary
             ; active_goal_ids = state.ps_active_goal_ids
             ; paused = state.ps_paused
             ; autoboot_enabled = state.ps_autoboot_enabled
             ; current_task_id = state.ps_current_task_id
             ; max_context_override = state.ps_max_context_override
             ; work_discovery_enabled = Safe_ops.json_bool_opt "work_discovery_enabled" json
             ; work_discovery_sources =
                 (match json with
                  | `Assoc fields ->
                    (match List.assoc_opt "work_discovery_sources" fields with
                     | Some (`List items) ->
                       Some (List.filter_map (function
                         | `String s -> Some s | _ -> None) items)
                     | _ -> None)
                  | _ -> None)
             ; work_discovery_interval_sec = Safe_ops.json_int_opt "work_discovery_interval_sec" json
             ; work_discovery_guidance = Safe_ops.json_string_opt "work_discovery_guidance" json
             ; telemetry_feedback_enabled = Safe_ops.json_bool_opt "telemetry_feedback_enabled" json
             ; telemetry_feedback_window_hours = Safe_ops.json_int_opt "telemetry_feedback_window_hours" json
             ; runtime = state.ps_runtime
             ; oas_env =
                 (match Yojson.Safe.Util.member "oas_env" json with
                  | `Assoc fields ->
                    List.filter_map (function
                      | (k, `String v) -> Some (k, v)
                      | _ -> None) fields
                  | _ -> [])
             ; keeper_id =
                 (match Safe_ops.json_string_opt "keeper_id" json with
                  | Some s ->
                      (match Keeper_id.uid_of_yojson (`String s) with
                       | Ok uid -> Some uid
                       | Error _ -> None)
                  | None -> None)
             ; meta_version =
                 (match Safe_ops.json_int_opt "meta_version" json with
                  | Some v -> v
                  | None -> 0)
             })
      )
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))
;;

let fallback_canonical_keeper_meta_key_names =
  [ "name"
  ; "agent_name"
  ; "trace_id"
  ; "trace_history"
  ; "goal"
  ; "short_goal"
  ; "mid_goal"
  ; "long_goal"
  ; "social_model"
  ; "cascade_name"
  ; "models"
  ; "will"
  ; "needs"
  ; "desires"
  ; "instructions"
  ; "policy_voice_enabled"
  ; "allowed_paths"
  ; "tool_access"
  ; "tool_denylist"
  ; "mention_targets"
  ; "room_signal_prompt_enabled"
  ; "joined_room_ids"
  ; "last_seen_seq_by_room"
  ; "generation"
  ; "proactive_enabled"
  ; "proactive_idle_sec"
  ; "proactive_cooldown_sec"
  ; "compaction_profile"
  ; "compaction_ratio_gate"
  ; "compaction_message_gate"
  ; "compaction_token_gate"
  ; "continuity_compaction_cooldown_sec"
  ; "auto_handoff"
  ; "handoff_threshold"
  ; "handoff_cooldown_sec"
  ; "voice_enabled"
  ; "voice_channel"
  ; "voice_agent_id"
  ; "last_handoff_ts"
  ; "created_at"
  ; "updated_at"
  ; "total_turns"
  ; "total_input_tokens"
  ; "total_output_tokens"
  ; "total_tokens"
  ; "total_cost_usd"
  ; "last_turn_ts"
  ; "last_model_used"
  ; "last_input_tokens"
  ; "last_output_tokens"
  ; "last_total_tokens"
  ; "last_latency_ms"
  ; "compaction_count"
  ; "last_compaction_ts"
  ; "last_compaction_before_tokens"
  ; "last_compaction_after_tokens"
  ; "proactive_count_total"
  ; "last_proactive_ts"
  ; "proactive_visible_count_total"
  ; "last_visible_proactive_ts"
  ; "last_proactive_outcome"
  ; "last_proactive_reason"
  ; "last_proactive_preview"
  ; "last_work_discovery_ts"
  ; "work_discovery_count"
  ; "last_compaction_check_ts"
  ; "last_compaction_decision"
  ; "last_continuity_update_ts"
  ; "continuity_summary"
  ; "active_goal_ids"
  ; "last_autonomous_action_at"
  ; "autonomous_action_count"
  ; "autonomous_turn_count"
  ; "autonomous_text_turn_count"
  ; "autonomous_tool_turn_count"
  ; "board_reactive_turn_count"
  ; "mention_reactive_turn_count"
  ; "noop_turn_count"
  ; "consecutive_noop_count"
  ; "last_speech_act"
  ; "last_social_transition_reason"
  ; "last_active_desire"
  ; "last_current_intention"
  ; "last_blocker"
  ; "last_blocker_class"
  ; "last_need"
  ; "paused"
  ; "autoboot_enabled"
  ; "current_task_id"
  ; "max_context_override"
  ; "work_discovery_enabled"
  ; "work_discovery_sources"
  ; "work_discovery_interval_sec"
  ; "work_discovery_guidance"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ; "per_provider_timeout_s"
  ; "oas_env"
  ]
;;

let canonical_keeper_meta_key_names =
  let seed_json =
    `Assoc
      [ "name", `String "__keeper-meta-key-seed__"
      ; "agent_name", `String "__keeper-meta-key-seed__"
      ; "trace_id", `String "__keeper-meta-key-seed__"
      ]
  in
  match meta_of_json seed_json with
  | Ok meta ->
    (match meta_to_json meta with
     | `Assoc fields -> fields |> List.map fst |> dedupe_keep_order
     | _ -> fallback_canonical_keeper_meta_key_names)
  | Error msg ->
    Log.Keeper.warn
      "canonical_keeper_meta_key_names seed failed: %s; falling back to static keys"
      msg;
    fallback_canonical_keeper_meta_key_names
;;

let warn_unknown_keeper_meta_keys ~path (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let unknown =
      fields
      |> List.filter_map (fun (key, _) ->
        if List.mem key canonical_keeper_meta_key_names then None else Some key)
      |> dedupe_keep_order
    in
    if unknown <> []
    then
      Log.Keeper.warn
        "keeper meta %s has unknown keys: %s"
        path
        (String.concat ", " unknown)
  | _ -> ()
;;

let read_meta_file_path path : (keeper_meta option, string) result =
  if not (Fs_compat.file_exists path)
  then Ok None
  else (
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      let json, _scrubbed = scrub_persisted_keeper_meta_json ~path json in
      warn_unknown_keeper_meta_keys ~path json;
      (match meta_of_json json with
       | Ok meta -> Ok (Some meta)
       | Error e ->
         Log.Keeper.warn "keeper meta parse failed for %s: %s" path e;
         Error e))
;;

(** Sidecar stem suffixes (without the trailing .json).
    A file like [sangsu.dataset.json] has stem [sangsu.dataset]; stripping
    [.json] and checking [String.ends_with ~suffix] on this stem filters
    sidecars while allowing keeper names that contain dots (e.g.
    [dot.name.json]). When adding a new sidecar kind, add its dot-prefixed
    suffix here. *)
let keeper_sidecar_stem_suffixes =
  [ ".dataset" ]

let is_keeper_meta_file f =
  if not (Filename.check_suffix f ".json") then false
  else
    let stem = Filename.chop_suffix f ".json" in
    stem <> ""
    && not
         (List.exists
            (fun suf ->
              String.length stem > String.length suf
              && String.ends_with ~suffix:suf stem)
            keeper_sidecar_stem_suffixes)
let persisted_keeper_names config =
  let dir = keeper_dir config in
  match Safe_ops.list_dir_safe dir with
  | Error e ->
    Log.Keeper.warn "persisted_keeper_names: failed to list directory %s: %s" dir e;
    []
  | Ok files ->
    files
    |> List.filter is_keeper_meta_file
    |> List.map Filename.remove_extension
    |> List.filter validate_name
    |> List.sort String.compare
;;

let configured_keeper_names _config =
  Config_dir_resolver.log_warnings ~context:"KeeperTypes" ();
  Keeper_types_profile.discover_keepers_toml (Config_dir_resolver.keepers_dir ())
  |> List.map fst
  |> dedupe_keep_order
;;

let keeper_names config =
  (* Discovery uses persisted JSON (.masc/keepers/*.json) as primary source.
     JSON files are scoped to the server's base_path, so test isolation works.
     Overlay keepers (from .masc/config/keepers/*.toml) are materialized to
     JSON at boot by load_or_materialize_boot_meta, so they appear here too.
     Sidecar files (.dataset) are filtered by is_keeper_meta_file. *)
  persisted_keeper_names config
;;

let declarative_autoboot_enabled_by_default name =
  match (load_keeper_profile_defaults name).autoboot_enabled with
  | Some false -> false
  | Some true | None -> true
;;

let keepalive_keeper_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when not meta.paused && meta.autoboot_enabled ->
        Some meta.name
    | Ok (Some _) -> None  (* paused or autoboot disabled *)
    | Ok None ->
        if declarative_autoboot_enabled_by_default name then Some name else None
    | Error msg ->
        (* Issue #8377: was [_ -> None] which collapsed read/parse
           failures silently into "name disappeared". Discovery would
           treat a corrupt meta file as if the keeper was deleted,
           hiding the operational issue. Now logs and excludes — the
           degraded state is operator-visible. *)
        Log.Keeper.warn
          "keepalive_keeper_names: meta read failed for %s, dropping \
           from keepalive set: %s" name msg;
        None)
;;

(** Names of keepers that should be running across sessions.
    A keeper is "persistent" when its on-disk meta has autoboot enabled
    and is not currently paused — i.e. the operator expects the runtime
    to keep it alive after restart.

    Mirrors [keepalive_keeper_names] for readers that care about
    durability rather than the keepalive fiber. *)
let persistent_agent_names config =
  configured_keeper_names config
  |> List.filter_map (fun name ->
    match read_meta_file_path (keeper_meta_path config name) with
    | Ok (Some meta) when not meta.paused && meta.autoboot_enabled ->
        Some meta.name
    | Ok (Some _) -> None  (* paused or autoboot disabled *)
    | Ok None -> None      (* meta file absent -> not persistent *)
    | Error msg ->
        (* Issue #8377: same anti-pattern as keepalive_keeper_names —
           Error was silently collapsed into None. Operator can't
           distinguish "keeper intentionally not persistent" from
           "meta file is corrupt and we couldn't read it". *)
        Log.Keeper.warn
          "persistent_agent_names: meta read failed for %s, treating \
           as non-persistent: %s" name msg;
        None)

let keeper_name_from_agent_name = Keeper_identity.keeper_name_from_agent_name

let canonical_keeper_name_from_agent_name =
  Keeper_identity.canonical_keeper_name_from_agent_name

let canonical_keeper_name = Keeper_identity.canonical_keeper_name

let separator_alias_variants name =
  let map_sep ~from_ch ~to_ch value =
    String.map (fun c -> if c = from_ch then to_ch else c) value
  in
  Json_util.dedupe_keep_order
    [ name; map_sep ~from_ch:'_' ~to_ch:'-' name; map_sep ~from_ch:'-' ~to_ch:'_' name ]

let read_meta_resolved config name : ((string * keeper_meta) option, string) result =
  let requested_name = String.trim name in
  let read_candidate candidate =
    read_meta_file_path (keeper_meta_path config candidate)
    |> Result.map (Option.map (fun meta -> (candidate, meta)))
  in
  let rec read_first = function
    | [] -> Ok None
    | candidate :: rest -> (
        match read_candidate candidate with
        | Ok None -> read_first rest
        | Ok (Some _) as ok -> ok
        | Error _ as err -> err)
  in
  if requested_name = "" then
    Ok None
  else
    let alias_candidates =
      match keeper_name_from_agent_name requested_name with
      | Some alias_name when not (String.equal alias_name requested_name) ->
          separator_alias_variants alias_name
      | _ -> []
    in
    read_first (separator_alias_variants requested_name @ alias_candidates)
;;

let read_meta config name : (keeper_meta option, string) result =
  let requested_name = String.trim name in
  let path = keeper_meta_path config requested_name in
  if keeper_debug
  then
    Log.Keeper.debug
      "read_meta name=%s path=%s exists=%b"
      requested_name
      path
      (Fs_compat.file_exists path);
  match read_meta_resolved config requested_name with
  | Ok (Some (_resolved_name, meta)) -> Ok (Some meta)
  | Ok None -> Ok None
  | Error _ as err -> err
;;

(** Read keeper meta only if the file's mtime has changed since [last_mtime].
    Returns [Some (meta, new_mtime)] when the file changed, [None] when
    unchanged.  Avoids parsing JSON on every heartbeat cycle when no
    operator has modified the meta file. *)
let read_meta_if_changed config name ~(last_mtime : float)
  : (keeper_meta * float) option =
  let requested_name = String.trim name in
  let read_candidate candidate =
    let path = keeper_meta_path config candidate in
    if not (Fs_compat.file_exists path) then None
    else
      match Fs_compat.file_mtime path with
      | Some mtime when mtime > last_mtime ->
          (match read_meta_file_path path with
          | Ok (Some meta) -> Some (meta, mtime)
          | Ok None -> None  (* file existed at mtime check but absent on read *)
          | Error msg ->
              (* Issue #8377: was [_ -> None] which silently treated a
                 read/parse failure as "no change". Now logs so an
                 operator can correlate stale UI with bad meta JSON. *)
              Log.Keeper.warn
                "read_meta_if_changed: parse failed for %s (mtime=%.0f): %s"
                path mtime msg;
              None)
      | _ -> None
  in
  match read_candidate requested_name with
  | Some _ as changed -> changed
  | None -> (
      match keeper_name_from_agent_name requested_name with
      | Some alias_name when not (String.equal alias_name requested_name) ->
          read_candidate alias_name
      | _ -> None)
;;

(* Model selection, path utilities, and JSONL helpers
   extracted to Keeper_types_support *)
include Keeper_types_support

let current_utc_timestamp () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (t.tm_year + 1900)
    (t.tm_mon + 1)
    t.tm_mday
    t.tm_hour
    t.tm_min
    t.tm_sec
;;

let refresh_progress_updated_line config name =
  let progress_path = keeper_progress_path config name in
  try
    let content = Fs_compat.load_file progress_path in
    let now_str = current_utc_timestamp () in
    let updated =
      String.split_on_char '\n' content
      |> List.map (fun line ->
        if String.starts_with ~prefix:"Updated:" (String.trim line)
        then "Updated: " ^ now_str
        else line)
      |> String.concat "\n"
    in
    Fs_compat.save_file progress_path updated
  with
  | _ -> ()
;;

let persist_meta config path persisted =
  let json = meta_to_json persisted in
  match Keeper_fs.save_json_atomic path json with
  | Ok () ->
    !runtime_meta_write_sync_hook config persisted;
    refresh_progress_updated_line config persisted.name;
    Ok ()
  | Error msg ->
    Error (Printf.sprintf "failed to write meta %s: %s" path msg)
;;

let write_meta ?(force = false) config (m : keeper_meta) : (unit, string) result =
  (* Assign UUID on first write for legacy keepers lacking keeper_id. *)
  let m =
    match m.keeper_id with
    | Some _ -> m
    | None -> { m with keeper_id = Some (Keeper_id.Uid.generate ()) }
  in
  let path = keeper_meta_path config m.name in
  if force
  then
    let persisted = { m with meta_version = m.meta_version + 1 } in
    persist_meta config path persisted
  else (
    (* Version CAS: reject writes whose version doesn't match what's on disk. *)
    match read_meta_file_path path with
    | Ok (Some existing) ->
      if existing.meta_version <> m.meta_version
      then
        Error
          (Printf.sprintf
             "meta version conflict for %s: expected %d, disk has %d"
             m.name
             m.meta_version
             existing.meta_version)
      else
        let persisted = { m with meta_version = m.meta_version + 1 } in
        persist_meta config path persisted
    | Ok None ->
      (* No existing file — initial write. *)
      let persisted = { m with meta_version = 1 } in
      persist_meta config path persisted
    | Error msg ->
      Error (Printf.sprintf "failed to read existing meta for CAS %s: %s" path msg))
;;

let is_version_conflict_error msg =
  let re = Re.Pcre.re "meta version conflict" |> Re.compile in
  try ignore (Re.exec re msg); true with Not_found -> false

(* #9764/#9733/#9769: cycle-completion writes lose data when a heartbeat or
   supervisor fiber bumps meta_version between the cycle's read and its
   write. Bounded retry that re-reads the latest disk version, lifts the
   caller's payload onto it, and writes again.

   Trade-off: the caller's payload wins at the field level — concurrent
   updates from heartbeat (last_seen, cursor) are overwritten. This is
   acceptable for cycle completion because (a) heartbeat fields are
   ephemeral and resync on the next heartbeat tick, while (b) cycle
   payload (usage tokens, trace_history, generation) is non-recoverable.
   Heartbeat itself must NOT use this helper (it would cause the inverse
   problem). *)
let write_meta_with_retry
      ?(max_retries = 3)
      config
      (m : keeper_meta)
  : (unit, string) result
  =
  let path = keeper_meta_path config m.name in
  let rec attempt n m =
    match write_meta config m with
    | Ok () -> Ok ()
    | Error msg when n >= max_retries -> Error msg
    | Error msg when not (is_version_conflict_error msg) -> Error msg
    | Error _ ->
      (* Version conflict — read latest disk state, lift caller's payload
         onto its version, and try again. *)
      (match read_meta_file_path path with
       | Ok (Some latest) ->
         Log.Keeper.warn
           "write_meta CAS retry %d/%d for %s (caller had %d, disk %d)"
           (n + 1) max_retries m.name m.meta_version latest.meta_version;
         attempt (n + 1) { m with meta_version = latest.meta_version }
       | Ok None ->
         (* Disk file vanished between attempts; fall back to fresh write. *)
         attempt (n + 1) { m with meta_version = 0 }
       | Error read_msg ->
         Error
           (Printf.sprintf
              "write_meta retry: failed to re-read for CAS: %s" read_msg))
  in
  attempt 0 m
;;

(* #9769 root fix: like [write_meta_with_retry], but lets the caller
   declare field ownership via [merge]. The turn-failure/cycle path
   uses [Keeper_meta_merge.heartbeat_fields_from_disk] so its retry
   does not clobber heartbeat-owned fields ([joined_room_ids],
   [last_seen_seq_by_room]). *)
let write_meta_with_merge
      ?(max_retries = 3)
      ~(merge : latest:keeper_meta -> caller:keeper_meta -> keeper_meta)
      config
      (m : keeper_meta)
  : (unit, string) result
  =
  let path = keeper_meta_path config m.name in
  let rec attempt n (caller : keeper_meta) =
    match write_meta config caller with
    | Ok () -> Ok ()
    | Error msg when n >= max_retries -> Error msg
    | Error msg when not (is_version_conflict_error msg) -> Error msg
    | Error _ ->
      (match read_meta_file_path path with
       | Ok (Some latest) ->
         Log.Keeper.warn
           "write_meta CAS retry %d/%d for %s (caller had %d, disk %d; field-level merge)"
           (n + 1) max_retries caller.name caller.meta_version
           latest.meta_version;
         attempt (n + 1) (merge ~latest ~caller)
       | Ok None ->
         (* Disk file vanished between attempts; fall back to fresh write. *)
         attempt (n + 1) { caller with meta_version = 0 }
       | Error read_msg ->
         Error
           (Printf.sprintf
              "write_meta retry: failed to re-read for CAS: %s" read_msg))
  in
  attempt 0 m
;;

(** Fiber-level health for keeper supervisor monitoring.
    Defined here (not in Keeper_supervisor) to avoid circular
    dependencies between keeper_exec_status and the keeper supervisor. *)
type fiber_health =
  | Fiber_alive (** Fiber running, promise unresolved *)
  | Fiber_zombie (** Registry entry exists but fiber terminated *)
  | Fiber_dead (** Restart budget exhausted, manual recovery needed *)
  | Fiber_unknown (** Not in supervised registry *)

(** Keeper-level health state — derived from agent status, keepalive
    fiber, and supervisor monitoring. Serialized to string at JSON
    boundaries only. Defined here (not in Keeper_exec_status) so
    operator_control_snapshot can parse JSON into the same type. *)
type keeper_health =
  | KH_healthy  (** Keepalive alive, recent turns, no quiet_reason *)
  | KH_idle     (** Keepalive alive but no recent activity *)
  | KH_offline  (** Agent not present or status=offline/inactive *)
  | KH_stale    (** Last seen too long ago or zombie flag from agent *)
  | KH_degraded (** graphql_error or model_error quiet_reason *)
  | KH_zombie   (** Fiber terminated but registry entry exists *)
  | KH_dead     (** Restart budget exhausted *)

(** Keeper continuity state — derived from health + keepalive status. *)
type keeper_continuity =
  | Continuity_healthy    (** Runtime aligned with durable state *)
  | Continuity_recovering (** Reconciling back into live presence *)
  | Continuity_not_running (** Keepalive fiber not running *)

(** Per-tool usage entry for keeper tool tracking.
    Defined here so Keeper_registry can embed it without depending
    on Keeper_tools_oas (avoids module init order issues). *)
type tool_call_entry =
  { count : int
  ; successes : int
  ; failures : int
  ; last_used_at : float
  }

(* ================================================================ *)
(* Working Context Types (moved from Keeper_working_context)         *)
(* ================================================================ *)

type working_context =
  { checkpoint : Oas.Checkpoint.t
  ; max_tokens : int
  }

type checkpoint =
  { checkpoint_id : string
  ; timestamp : float
  ; generation : int
  ; message_count : int
  ; token_count : int
  ; serialized : string
  }

type session_context =
  { session_id : string
  ; session_dir : string
  ; mutable checkpoints : checkpoint list
  }
