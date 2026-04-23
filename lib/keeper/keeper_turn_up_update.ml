(** Keeper_turn_up_update -- update an existing keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok (Some old) branch).
    Handles merging of new arguments with existing keeper meta,
    policy validation, and keepalive restart. *)

open Keeper_types
open Keeper_keepalive
open Keeper_turn_up_args

let update_keeper (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result =
  match p.tool_access_opt, old.tool_access, p.tool_preset_opt, p.tool_also_allow_opt with
  | None, Custom _, None, Some _ ->
      (false, "tool_also_allow requires a preset-based keeper policy; set tool_preset first")
  | _ ->
  let goal_provided = Option.is_some p.goal_opt in
  let goal =
    match p.goal_opt with
    | Some g -> normalize_goal_horizon_text g
    | None ->
        if String.trim old.goal <> "" then old.goal
        else p.profile_defaults.goal |> Option.value ~default:""
  in
  let short_goal_default = if goal_provided then goal else old.short_goal in
  let mid_goal_default = if goal_provided then goal else old.mid_goal in
  let long_goal_default = if goal_provided then goal else old.long_goal in
  let short_goal =
    Option.value ~default:short_goal_default p.short_goal_opt
    |> normalize_goal_horizon_text
  in
  let mid_goal =
    Option.value ~default:mid_goal_default p.mid_goal_opt
    |> normalize_goal_horizon_text
  in
  let long_goal =
    Option.value ~default:long_goal_default p.long_goal_opt
    |> normalize_goal_horizon_text
  in
  let policy_voice_enabled =
    first_some
      p.policy_voice_enabled_opt
      (first_some (Some old.policy_voice_enabled) p.profile_defaults.policy_voice_enabled)
    |> Option.value ~default:false
  in
  let allowed_paths =
    Option.value ~default:old.allowed_paths p.allowed_paths_opt
  in
  let sandbox_profile =
    Option.value ~default:old.sandbox_profile p.sandbox_profile_opt
  in
  let network_mode =
    match p.network_mode_opt with
    | Some mode -> mode
    | None ->
        if Option.is_some p.sandbox_profile_opt
           && sandbox_profile <> old.sandbox_profile
        then
          (* Recompute the profile default on sandbox posture changes so
             legacy egress does not silently carry into hardened mode. *)
          default_network_mode_for_profile sandbox_profile
        else
          old.network_mode
  in
  let shared_memory_scope =
    Option.value ~default:old.shared_memory_scope p.shared_memory_scope_opt
  in
  let autoboot_enabled =
    Option.value ~default:old.autoboot_enabled p.autoboot_enabled_opt
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_in:p.mention_targets_in
      ~fallback_targets:
        (if old.mention_targets <> [] then old.mention_targets
         else p.profile_defaults.mention_targets)
      ~name:p.name
  in
  let room_signal_prompt_enabled =
    match keeper_room_signal_prompt_enabled_override () with
    | Some value -> value
    | None ->
        Option.value
          ~default:default_room_signal_prompt_enabled
          p.profile_defaults.room_signal_prompt_enabled
  in
  let (compaction_profile, compaction_ratio_gate, compaction_message_gate, compaction_token_gate) =
    resolve_compaction_policy
      ~profile_opt:p.compaction_profile_opt
      ~ratio_opt:p.compaction_ratio_gate_opt
      ~message_opt:p.compaction_message_gate_opt
      ~token_opt:p.compaction_token_gate_opt
      ~fallback_profile:old.compaction.profile
      ~fallback_ratio:old.compaction.ratio_gate
      ~fallback_message:old.compaction.message_gate
      ~fallback_token:old.compaction.token_gate
  in
  let tool_access =
    match p.tool_access_opt with
    | Some access -> access
    | None ->
        match old.tool_access with
        | Preset current ->
            let preset = Option.value ~default:current.preset p.tool_preset_opt in
            let also_allow =
              resolve_tool_name_list
                ~preferred:p.tool_also_allow_opt
                ~fallback:(Some current.also_allow)
            in
            Preset { preset; also_allow }
        | Custom names -> (
            match p.tool_preset_opt with
            | Some preset ->
                let also_allow =
                  resolve_tool_name_list
                    ~preferred:p.tool_also_allow_opt
                    ~fallback:p.profile_defaults.tool_also_allow
                in
                Preset { preset; also_allow }
            | None -> Custom names)
  in
  let tool_denylist =
    let profile_or_old =
      match p.profile_defaults.tool_denylist with
      | Some _ as toml -> toml
      | None ->
        if old.tool_denylist <> [] then Some old.tool_denylist
        else None
    in
    resolve_tool_name_list
      ~preferred:p.tool_denylist_opt
      ~fallback:profile_or_old
  in
  let updated = { old with
    goal;
    short_goal;
    mid_goal;
    long_goal;
    cascade_name =
      (* TOML cascade_name takes precedence over runtime JSON when present.
         Without this, changing cascade_name in keepers/*.toml has no effect
         until the runtime JSON is deleted.  See #6747.

         Store the raw string as declared in TOML / state JSON.  Downstream
         consumers ([Cascade_runtime], [Keeper_status_bridge],
         [Admission_queue], ...) already canonicalize at point-of-use, so
         preserving the raw value here lets the dashboard surface config
         drift (keeper TOML referencing an unknown cascade name) via the
         [canonical] column of [Dashboard_cascade.keeper_profile_json]. *)
      (match p.profile_defaults.cascade_name with
       | Some name -> name
       | None ->
         if String.trim old.cascade_name <> "" then
           old.cascade_name
         else Keeper_config.default_cascade_name);
    will =
      Option.value
        ~default:
          (if String.trim old.will <> "" then old.will
           else Option.value ~default:default_keeper_will p.profile_defaults.will)
        p.will_opt;
    needs =
      Option.value
        ~default:
          (if String.trim old.needs <> "" then old.needs
           else Option.value ~default:default_keeper_needs p.profile_defaults.needs)
        p.needs_opt;
    desires =
      Option.value
        ~default:
          (if String.trim old.desires <> "" then old.desires
           else Option.value ~default:default_keeper_desires p.profile_defaults.desires)
        p.desires_opt;
    instructions =
      Option.value
        ~default:
          (if String.trim old.instructions <> "" then old.instructions
           else Option.value ~default:"" p.profile_defaults.instructions)
        p.instructions_opt;
    policy_voice_enabled;
    allowed_paths;
    execution_scope =
      Option.value ~default:old.execution_scope p.execution_scope_opt;
    sandbox_profile;
    network_mode;
    shared_memory_scope;
    tool_access;
    tool_denylist;
    autoboot_enabled;
    voice_enabled =
      Option.value ~default:old.voice_enabled p.voice_enabled_opt;
    voice_channel =
      (p.voice_channel_opt
      |> Option.map canonical_voice_channel
      |> Option.value ~default:old.voice_channel);
    voice_agent_id =
      Option.value ~default:old.voice_agent_id p.voice_agent_id_opt;
    mention_targets;
    room_signal_prompt_enabled;
    proactive = {
      enabled =
        (match p.proactive_enabled_opt with
         | Some v -> v
         | None ->
             (match p.profile_defaults.proactive_enabled with
              | Some v -> v
              | None -> old.proactive.enabled));
      idle_sec =
        (match p.proactive_idle_sec_opt with
         | Some v -> v
         | None ->
             (match p.profile_defaults.proactive_idle_sec with
              | Some v -> v
              | None -> old.proactive.idle_sec))
        |> normalize_proactive_idle_sec;
      cooldown_sec =
        (match p.proactive_cooldown_sec_opt with
         | Some v -> v
         | None ->
             (match p.profile_defaults.proactive_cooldown_sec with
              | Some v -> v
              | None -> old.proactive.cooldown_sec))
        |> normalize_proactive_cooldown_sec;
    };
    compaction = {
      profile = compaction_profile;
      ratio_gate = compaction_ratio_gate;
      message_gate = compaction_message_gate;
      token_gate = compaction_token_gate;
      cooldown_sec =
        Option.value
          ~default:old.compaction.cooldown_sec
          p.continuity_compaction_cooldown_sec_opt
        |> normalize_continuity_compaction_cooldown_sec;
      max_checkpoint_messages = old.compaction.max_checkpoint_messages;
    };
    auto_handoff = Option.value ~default:old.auto_handoff p.auto_handoff_opt;
    handoff_threshold = Option.value ~default:old.handoff_threshold p.handoff_threshold_opt;
    handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec p.handoff_cooldown_sec_opt;
    max_context_override = (match p.max_context_override_opt with Some _ as v -> v | None -> old.max_context_override);
    updated_at = now_iso ();
  } in
  match
    validate_sandbox_settings
      ~config:ctx.config
      ~keeper_name:p.name
      ~sandbox_profile
      ~network_mode
      ~allowed_paths
  with
  | Error err ->
      Log.Keeper.warn "update_keeper failed sandbox validation for %s: %s"
        p.name err;
      (false, err)
  | Ok () ->
      (match
         Keeper_sandbox_runtime.ensure_keeper_startup_preflight
           ~timeout_sec:15.0 ~sandbox_profile
       with
       | Error err ->
           Log.Keeper.warn "update_keeper failed sandbox preflight for %s: %s"
             p.name err;
           (false, err)
       | Ok () ->
      (match write_meta ctx.config updated with
       | Error e -> (false, e)
       | Ok () ->
         stop_keepalive ~base_path:ctx.config.base_path updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.to_string (meta_to_json updated))))
