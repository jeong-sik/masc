(** Keeper_turn_up_update -- update an existing keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok (Some old) branch).
    Handles merging of new arguments with existing keeper meta,
    policy validation, and keepalive restart. *)

open Keeper_types
open Keeper_keepalive
open Keeper_turn_up_args

let update_keeper (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result =
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
  let models =
    if p.models_in <> [] then p.models_in
    else if old.models <> [] then old.models
    else if p.profile_defaults.models <> [] then p.profile_defaults.models
    else p.profile_defaults.allowed_models
  in
  let allowed_models =
    resolve_allowed_models
      ~explicit_allowed_models:p.allowed_models_in
      ~seed_allowed_models:
        (if old.allowed_models <> [] then old.allowed_models
         else p.profile_defaults.allowed_models)
      ~models
  in
  let active_model =
    p.active_model_opt
    |> first_some
         (if String.trim old.active_model <> "" then Some old.active_model else None)
    |> first_some p.profile_defaults.active_model
    |> Option.value
         ~default:
           (match models with
            | model :: _ -> model
            | [] -> "")
  in
  (* Mode categorization removed: always use fixed values. *)
  let policy_mode = "unified" in
  let policy_voice_enabled =
    first_some
      p.policy_voice_enabled_opt
      (first_some (Some old.policy_voice_enabled) p.profile_defaults.policy_voice_enabled)
    |> Option.value ~default:false
  in
  let policy_shell_mode = "coding" in
  let allowed_paths =
    Option.value ~default:old.allowed_paths p.allowed_paths_opt
  in
  let room_scope =
    p.room_scope_opt
    |> first_some
         (if String.trim old.room_scope <> "" then Some old.room_scope else None)
    |> first_some p.profile_defaults.room_scope
    |> Option.value ~default:"current"
    |> canonical_room_scope
  in
  let scope_kind =
    p.scope_kind_opt
    |> first_some
         (if String.trim old.scope_kind <> "" then Some old.scope_kind else None)
    |> first_some p.profile_defaults.scope_kind
    |> Option.value ~default:(if room_scope = "all" then "global" else "local")
    |> canonical_scope_kind
  in
  let trigger_mode =
    p.trigger_mode_opt
    |> first_some
         (if String.trim old.trigger_mode <> "" then Some old.trigger_mode else None)
    |> first_some p.profile_defaults.trigger_mode
    |> Option.value ~default:"explicit_only"
    |> canonical_trigger_mode
  in
  let mention_targets =
    resolve_mention_targets
      ~mention_targets_in:p.mention_targets_in
      ~fallback_targets:
        (if old.mention_targets <> [] then old.mention_targets
         else p.profile_defaults.mention_targets)
      ~name:p.name
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
  let updated = { old with
    goal;
    short_goal;
    mid_goal;
    long_goal;
    soul_profile =
      Option.value
        ~default:
          (if String.trim old.soul_profile <> "" then old.soul_profile
           else Option.value ~default:default_soul_profile p.profile_defaults.soul_profile)
        p.soul_profile_opt;
    cascade_name =
      (if String.trim old.cascade_name <> "" then old.cascade_name
       else "keeper_unified");
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
    models;
    allowed_models;
    active_model;
    policy_mode;
    policy_voice_enabled;
    policy_shell_mode;
    allowed_paths;
    scope_kind;
    room_scope;
    trigger_mode;
    voice_enabled =
      Option.value ~default:old.voice_enabled p.voice_enabled_opt;
    voice_channel =
      (p.voice_channel_opt
      |> Option.map canonical_voice_channel
      |> Option.value ~default:old.voice_channel);
    voice_agent_id =
      Option.value ~default:old.voice_agent_id p.voice_agent_id_opt;
    mention_targets;
    persona_profile_path =
      if String.trim old.persona_profile_path <> "" then old.persona_profile_path
      else Option.value ~default:"" p.profile_defaults.manifest_path;
    presence_keepalive =
      Option.value
        ~default:
          (Option.value ~default:old.presence_keepalive p.profile_defaults.presence_keepalive)
        p.presence_keepalive_opt;
    presence_keepalive_sec =
      Option.value
        ~default:
          (Option.value
             ~default:old.presence_keepalive_sec
             p.profile_defaults.presence_keepalive_sec)
        p.presence_keepalive_sec_opt;
    proactive = { old.proactive with
      enabled =
        Option.value
          ~default:old.proactive.enabled
          p.proactive_enabled_opt;
      idle_sec =
        Option.value ~default:old.proactive.idle_sec p.proactive_idle_sec_opt
        |> normalize_proactive_idle_sec;
      cooldown_sec =
        Option.value ~default:old.proactive.cooldown_sec p.proactive_cooldown_sec_opt
        |> normalize_proactive_cooldown_sec;
    };
    compaction = { old.compaction with
      profile = compaction_profile;
      ratio_gate = compaction_ratio_gate;
      message_gate = compaction_message_gate;
      token_gate = compaction_token_gate;
      cooldown_sec =
        Option.value
          ~default:old.compaction.cooldown_sec
          p.continuity_compaction_cooldown_sec_opt
        |> normalize_continuity_compaction_cooldown_sec;
    };
    auto_handoff = Option.value ~default:old.auto_handoff p.auto_handoff_opt;
    handoff_threshold = Option.value ~default:old.handoff_threshold p.handoff_threshold_opt;
    handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec p.handoff_cooldown_sec_opt;
    updated_at = now_iso ();
  } in
  (match write_meta ctx.config updated with
   | Error e -> (false, e)
   | Ok () ->
     stop_keepalive updated.name;
     start_keepalive ctx updated;
     (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))
