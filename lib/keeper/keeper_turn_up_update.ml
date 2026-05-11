(** Keeper_turn_up_update -- update an existing keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok (Some old) branch).
    Handles merging of new arguments with existing keeper meta,
    policy validation, and keepalive restart. *)

open Keeper_types
open Keeper_keepalive
open Keeper_turn_up_args

let resolve_active_goal_ids config p old_ids =
  let active_goal_ids =
    match p.active_goal_ids_opt with
    | Some ids -> ids
    | None ->
        Option.value ~default:old_ids p.profile_defaults.active_goal_ids
  in
  match p.active_goal_ids_opt with
  | None -> Ok active_goal_ids
  | Some _ ->
      let missing =
        List.filter
          (fun goal_id -> Option.is_none (Goal_store.get_goal config ~goal_id))
          active_goal_ids
      in
      if missing = [] then Ok active_goal_ids
      else
        Error
          (Printf.sprintf "unknown active_goal_ids: %s"
             (String.concat ", " missing))

let blocker_requires_continue_gate (old : keeper_meta) =
  match old.runtime.last_blocker with
  | Some info -> blocker_class_continue_gate info.klass
  | None -> false

let paused_state_requires_approval (old : keeper_meta) =
  Keeper_approval_queue.has_pending_for_keeper ~keeper_name:old.name
  || blocker_requires_continue_gate old

let update_keeper (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result =
  match p.tool_access_opt, old.tool_access, p.tool_preset_opt, p.tool_also_allow_opt with
  | None, Custom _, None, Some _ ->
      (false, "tool_also_allow requires a preset-based keeper policy; set tool_preset first")
  | _ ->
  match resolve_active_goal_ids ctx.config p old.active_goal_ids with
  | Error msg -> (false, msg)
  | Ok active_goal_ids ->
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
  let room_signal_prompt_enabled =
    match keeper_room_signal_prompt_enabled_override () with
    | Some value -> value
    | None ->
        Option.value
          ~default:
            (tool_access_default_room_signal_prompt_enabled
               ~default:default_room_signal_prompt_enabled
               tool_access)
          p.profile_defaults.room_signal_prompt_enabled
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
  let new_will =
    Option.value
      ~default:
        (if String.trim old.will <> "" then old.will
         else Option.value ~default:(Env_config_core.keeper_will ()) p.profile_defaults.will)
      p.will_opt
  in
  let new_needs =
    Option.value
      ~default:
        (if String.trim old.needs <> "" then old.needs
         else Option.value ~default:(Env_config_core.keeper_needs ()) p.profile_defaults.needs)
      p.needs_opt
  in
  let new_desires =
    Option.value
      ~default:
        (if String.trim old.desires <> "" then old.desires
         else Option.value ~default:(Env_config_core.keeper_desires ()) p.profile_defaults.desires)
      p.desires_opt
  in
  (* Layer 1 boundary check: warn (not truncate) when an update brings a
     persona field above the prompt-render cap.  Skip when the value
     equals [old.*] — a silent read-back must not spam logs.  Disk
     preserves the raw value; only prompt rendering applies the cap. *)
  let warn_personality_cap field old_value new_value =
    if not (String.equal old_value new_value) then
      let len = String.length new_value in
      if len > Keeper_config.prompt_render_max_bytes then
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_turn_up_update_failures
          ~labels:[("keeper", old.name); ("site", "prompt_cap")]
          ();
        Log.Keeper.warn
          "update_keeper personality.%s for %s exceeds prompt cap \
           (%d bytes > %d). Stored as-is; truncated only at prompt rendering."
          field old.name len Keeper_config.prompt_render_max_bytes
  in
  warn_personality_cap "will" old.will new_will;
  warn_personality_cap "needs" old.needs new_needs;
  warn_personality_cap "desires" old.desires new_desires;
  let resume_paused_keeper =
    old.paused && not (paused_state_requires_approval old)
  in
  if resume_paused_keeper then (
    let blocker_class, blocker_detail =
      match old.runtime.last_blocker with
      | Some info -> blocker_class_to_string info.klass, info.detail
      | None -> "none", ""
    in
    let auto_resume_after_sec =
      old.auto_resume_after_sec
      |> Option.map (Printf.sprintf "%.0f")
      |> Option.value ~default:"none"
    in
    Log.Keeper.warn
      "update_keeper resumed paused keeper %s; clearing \
       auto_resume_after_sec=%s last_blocker.klass=%s last_blocker.detail=%S"
      old.name auto_resume_after_sec blocker_class blocker_detail);
  if old.paused && not resume_paused_keeper then
    Log.Keeper.warn
      "update_keeper kept %s paused because an approval/reconcile gate is pending"
      old.name;
  let updated = { old with
    goal;
    short_goal;
    mid_goal;
    long_goal;
    cascade_ref =
      (* RFC-0041 (post-step-4): cascade_ref is the SSOT.
         TOML cascade_name takes precedence over runtime when present;
         otherwise preserve the existing keeper's cascade_ref so the
         dashboard surfaces drift (keeper TOML referencing an unknown
         cascade name) via the [canonical] column of
         [Dashboard_cascade.keeper_profile_json].  See #6747. *)
      (let group =
         match p.profile_defaults.cascade_name with
         | Some name -> name
         | None ->
           let prev = cascade_name_of_meta old in
           if String.trim prev <> "" then prev
           else (Keeper_config.default_cascade_name ())
       in
       Some Cascade_ref.{ group; item = None });
    will = new_will;
    needs = new_needs;
    desires = new_desires;
    instructions =
      Option.value
        ~default:
          (if String.trim old.instructions <> "" then old.instructions
           else Option.value ~default:"" p.profile_defaults.instructions)
        p.instructions_opt;
    policy_voice_enabled;
    allowed_paths;
    sandbox_profile;
    network_mode;
    tool_access;
    tool_denylist;
    tool_preset_source = p.profile_defaults.tool_preset_source;
    autoboot_enabled;
    active_goal_ids;
    paused = if resume_paused_keeper then false else old.paused;
    auto_resume_after_sec =
      if resume_paused_keeper then None else old.auto_resume_after_sec;
    runtime =
      (if resume_paused_keeper then
         {
           old.runtime with
           last_blocker = None;
         }
       else old.runtime);
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
      ~github_identity:p.profile_defaults.github_identity
      ~sandbox_profile
      ~network_mode
      ~allowed_paths
  with
  | Error err ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_turn_up_update_failures
        ~labels:[("keeper", p.name); ("site", "sandbox_validation")]
        ();
      Log.Keeper.warn "update_keeper failed sandbox validation for %s: %s"
        p.name err;
      (false, err)
  | Ok () ->
      (match
         Keeper_sandbox_runtime.ensure_keeper_startup_preflight
           ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Turn_up ()) ~sandbox_profile
       with
       | Error err ->
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_turn_up_update_failures
             ~labels:[("keeper", p.name); ("site", "sandbox_preflight")]
             ();
           Log.Keeper.warn "update_keeper failed sandbox preflight for %s: %s"
             p.name err;
           (false, err)
       | Ok () ->
      (match write_meta ctx.config updated with
       | Error e ->
           Prometheus.inc_counter
             Keeper_metrics.metric_keeper_write_meta_failures
             ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
             ();
           (false, e)
       | Ok () ->
         stop_keepalive ~base_path:ctx.config.base_path updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.to_string (meta_to_json updated))))
