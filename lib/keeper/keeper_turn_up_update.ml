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
  let policy_mode =
    first_some
      p.policy_mode_opt
      (first_some
         (if String.trim old.policy_mode <> "" then Some old.policy_mode else None)
         p.profile_defaults.policy_mode)
    |> Option.value ~default:"heuristic"
    |> canonical_policy_mode
  in
  let policy_action_budget =
    first_some
      p.policy_action_budget_opt
      (first_some
         (if String.trim old.policy_action_budget <> "" then Some old.policy_action_budget else None)
         p.profile_defaults.policy_action_budget)
    |> Option.value ~default:"conversation"
    |> canonical_policy_action_budget
  in
  let policy_reward_model_path =
    first_some
      p.policy_reward_model_path_opt
      (first_some
         (if String.trim old.policy_reward_model_path <> "" then Some old.policy_reward_model_path else None)
         p.profile_defaults.policy_reward_model_path)
    |> Option.value ~default:""
    |> resolve_reward_model_path ~base_path:ctx.config.base_path
  in
  let policy_voice_enabled =
    first_some
      p.policy_voice_enabled_opt
      (first_some (Some old.policy_voice_enabled) p.profile_defaults.policy_voice_enabled)
    |> Option.value ~default:false
  in
  let policy_shell_mode =
    first_some
      p.policy_shell_mode_opt
      (first_some (Some old.policy_shell_mode) p.profile_defaults.policy_shell_mode)
    |> Option.value ~default:"disabled"
    |> canonical_policy_shell_mode
  in
  let initiative_enabled =
    first_some
      p.initiative_enabled_opt
      (first_some (Some old.initiative_enabled) p.profile_defaults.initiative_enabled)
    |> Option.value ~default:false
  in
  let initiative_scope =
    first_some
      p.initiative_scope_opt
      (first_some (Some old.initiative_scope) p.profile_defaults.initiative_scope)
    |> Option.value ~default:"board_only"
    |> canonical_initiative_scope
  in
  let initiative_idle_sec =
    first_some
      p.initiative_idle_sec_opt
      (first_some (Some old.initiative_idle_sec) p.profile_defaults.initiative_idle_sec)
    |> Option.value ~default:3600
    |> normalize_initiative_idle_sec
  in
  let initiative_cooldown_sec =
    first_some
      p.initiative_cooldown_sec_opt
      (first_some (Some old.initiative_cooldown_sec) p.profile_defaults.initiative_cooldown_sec)
    |> Option.value ~default:3600
    |> normalize_initiative_cooldown_sec
  in
  let initiative_context_mode =
    first_some
      p.initiative_context_mode_opt
      (first_some (Some old.initiative_context_mode) p.profile_defaults.initiative_context_mode)
    |> Option.value ~default:"board_snapshot"
    |> canonical_initiative_context_mode
  in
  let initiative_post_ttl_hours =
    first_some
      p.initiative_post_ttl_hours_opt
      (first_some (Some old.initiative_post_ttl_hours) p.profile_defaults.initiative_post_ttl_hours)
    |> Option.value ~default:24
    |> normalize_initiative_post_ttl_hours
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
    |> Option.value ~default:"legacy"
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
      ~fallback_profile:old.compaction_profile
      ~fallback_ratio:old.compaction_ratio_gate
      ~fallback_message:old.compaction_message_gate
      ~fallback_token:old.compaction_token_gate
  in
  match validate_policy ~policy_mode ~policy_action_budget
          ~policy_voice_enabled ~policy_shell_mode ~initiative_enabled with
  | Some err -> (false, err)
  | None ->
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
    policy_action_budget;
    policy_reward_model_path;
    policy_voice_enabled;
    policy_shell_mode;
    initiative_enabled;
    initiative_scope;
    initiative_idle_sec;
    initiative_cooldown_sec;
    initiative_context_mode;
    initiative_post_ttl_hours;
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
    verify = Option.value ~default:old.verify p.verify_opt;
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
    proactive_enabled =
      Option.value
        ~default:
          (Option.value
             ~default:
               (if
                  trigger_mode
                  |> Keeper_contract.trigger_mode_of_string
                  |> Keeper_contract.trigger_mode_is_explicit_only
                then false
                else old.proactive_enabled)
             p.profile_defaults.proactive_enabled)
        p.proactive_enabled_opt;
    proactive_idle_sec =
      Option.value ~default:old.proactive_idle_sec p.proactive_idle_sec_opt
      |> normalize_proactive_idle_sec;
    proactive_cooldown_sec =
      Option.value ~default:old.proactive_cooldown_sec p.proactive_cooldown_sec_opt
      |> normalize_proactive_cooldown_sec;
    drift_enabled = Option.value ~default:old.drift_enabled p.drift_enabled_opt;
    drift_min_turn_gap =
      Option.value ~default:old.drift_min_turn_gap p.drift_min_turn_gap_opt
      |> normalize_drift_min_turn_gap;
    compaction_profile;
    compaction_ratio_gate;
    compaction_message_gate;
    compaction_token_gate;
    continuity_compaction_cooldown_sec =
      Option.value
        ~default:old.continuity_compaction_cooldown_sec
        p.continuity_compaction_cooldown_sec_opt
      |> normalize_continuity_compaction_cooldown_sec;
    auto_handoff = Option.value ~default:old.auto_handoff p.auto_handoff_opt;
    handoff_threshold = Option.value ~default:old.handoff_threshold p.handoff_threshold_opt;
    handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec p.handoff_cooldown_sec_opt;
    context_budget = Option.value ~default:old.context_budget p.context_budget_opt;
    auto_team_session_enabled =
      Option.value
        ~default:old.auto_team_session_enabled
        p.auto_team_session_enabled_opt;
    updated_at = now_iso ();
  } in
  (match write_meta ctx.config updated with
   | Error e -> (false, e)
   | Ok () ->
     stop_keepalive updated.name;
     start_keepalive ctx updated;
     (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))
