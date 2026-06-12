(** Keeper_turn_up_update -- update an existing keeper from parsed arguments.

    Extracted from keeper_turn_up.ml (Ok (Some old) branch).
    Handles merging of new arguments with existing keeper meta,
    policy validation, and keepalive restart. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
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

let update_keeper ?(force = false) ?(preserve_prompt_defaults = false)
    (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result
    =
  match resolve_active_goal_ids ctx.config p old.active_goal_ids with
  | Error msg -> tool_result_error msg
  | Ok active_goal_ids ->
  let goal_provided = Option.is_some p.goal_opt in
  let profile_default_text opt fallback =
    match opt with
    | Some value when String.trim value <> "" -> value
    | _ -> fallback
  in
  let goal =
    match p.goal_opt with
    | Some g -> normalize_goal_horizon_text g
    | None ->
        if preserve_prompt_defaults then old.goal
        else
          profile_default_text p.profile_defaults.goal
            (if String.trim old.goal <> "" then old.goal else "")
  in
  let short_goal_default = if goal_provided then goal else old.short_goal in
  let mid_goal_default = if goal_provided then goal else old.mid_goal in
  let long_goal_default = if goal_provided then goal else old.long_goal in
  let horizon_default profile_opt old_default =
    if goal_provided then old_default
    else if preserve_prompt_defaults then old_default
    else profile_default_text profile_opt old_default
  in
  let short_goal =
    Option.value
      ~default:(horizon_default p.profile_defaults.short_goal short_goal_default)
      p.short_goal_opt
    |> normalize_goal_horizon_text
  in
  let mid_goal =
    Option.value
      ~default:(horizon_default p.profile_defaults.mid_goal mid_goal_default)
      p.mid_goal_opt
    |> normalize_goal_horizon_text
  in
  let long_goal =
    Option.value
      ~default:(horizon_default p.profile_defaults.long_goal long_goal_default)
      p.long_goal_opt
    |> normalize_goal_horizon_text
  in
  let allowed_paths =
    Option.value ~default:old.allowed_paths p.allowed_paths_opt
  in
  match
    match p.sandbox_profile_opt with
    | None -> Ok old.sandbox_profile
    | Some raw ->
      match sandbox_profile_of_string raw with
      | Some sp -> Ok sp
      | None ->
        Error
          (Printf.sprintf "invalid sandbox_profile: %S (expected: local or docker)" raw)
  with
  | Error msg -> tool_result_error msg
  | Ok sandbox_profile ->
  match
    match p.network_mode_opt with
    | None -> Ok old.network_mode
    | Some raw ->
      match network_mode_of_string raw with
      | Some nm -> Ok nm
      | None ->
        Error
          (Printf.sprintf "invalid network_mode: %S (expected: inherit or none)" raw)
  with
  | Error msg -> tool_result_error msg
  | Ok network_mode ->
  let autoboot_enabled =
    match p.autoboot_enabled_opt, p.profile_defaults.autoboot_enabled with
    | Some value, _ -> value
    | None, Some value -> value
    | None, None -> old.autoboot_enabled
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
        (match p.profile_defaults.tool_access with
         | Some tools -> normalize_tool_names tools
         | None -> old.tool_access)
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
    match p.will_opt with
    | Some w -> w
    | None ->
        if preserve_prompt_defaults then old.will
        else if String.trim old.will <> "" then old.will
        else Option.value ~default:(Env_config_core.keeper_will ()) p.profile_defaults.will
  in
  let new_needs =
    match p.needs_opt with
    | Some n -> n
    | None ->
        if preserve_prompt_defaults then old.needs
        else if String.trim old.needs <> "" then old.needs
        else Option.value ~default:(Env_config_core.keeper_needs ()) p.profile_defaults.needs
  in
  let new_desires =
    match p.desires_opt with
    | Some d -> d
    | None ->
        if preserve_prompt_defaults then old.desires
        else if String.trim old.desires <> "" then old.desires
        else Option.value ~default:(Env_config_core.keeper_desires ()) p.profile_defaults.desires
  in
  (* Layer 1 boundary check: warn (not truncate) when an update brings a
     persona field above the prompt-render cap.  Skip when the value
     equals [old.*] — a silent read-back must not spam logs.  Disk
     preserves the raw value; only prompt rendering applies the cap. *)
  let warn_personality_cap field old_value new_value =
    if not (String.equal old_value new_value) then
      let len = String.length new_value in
      if len > Keeper_config.prompt_render_max_bytes then
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string TurnUpUpdateFailures)
          ~labels:[("keeper", old.name); ("site", Keeper_turn_up_update_failure_site.(to_label Prompt_cap))]
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
  (* Clear any persisted livelock attempt counter on every update_keeper run,
     not only the resume-paused branch.  Older turn-livelock guards only
     recorded a `pause_human` receipt, while current guards may persist
     [meta.paused = true].  A follow-up `masc_keeper_up` should clear the
     stale in-memory counter in both cases. *)
  Keeper_turn_livelock.reset_keeper_livelock ~keeper:old.name;
  (* ETA-LIVELOCK: align typed-escalation classifier with the
     livelock counter reset so an operator-triggered keeper_up
     restores the next block to ERROR (not silent DEBUG demotion
     from a previous threshold_park). *)
  Keeper_livelock_state.reset_for_keeper ~keeper:old.name;
  if old.paused && not resume_paused_keeper then
    Log.Keeper.warn
      "update_keeper kept %s paused because an approval/reconcile gate is pending"
      old.name;
  let updated = { old with
    goal;
    short_goal;
    mid_goal;
    long_goal;
    will = new_will;
    needs = new_needs;
    desires = new_desires;
    instructions =
      (match p.instructions_arg with
       | Some v -> v
       | None ->
           if preserve_prompt_defaults then old.instructions
           else
             Option.value
               ~default:
                 (if String.trim old.instructions <> "" then old.instructions
                  else Option.value ~default:"" p.profile_defaults.instructions)
               p.instructions_opt);
    allowed_paths;
    sandbox_profile;
    network_mode;
    tool_access;
    tool_denylist;
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
    mention_targets;
    telemetry_feedback_enabled =
      Dashboard_utils.first_some p.profile_defaults.telemetry_feedback_enabled
        old.telemetry_feedback_enabled;
    telemetry_feedback_window_hours =
      Dashboard_utils.first_some p.profile_defaults.telemetry_feedback_window_hours
        old.telemetry_feedback_window_hours;
    always_approve =
      Dashboard_utils.first_some p.profile_defaults.always_approve old.always_approve;
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
      keep_recent_tool_results = old.compaction.keep_recent_tool_results;
    };
    auto_handoff = Option.value ~default:old.auto_handoff p.auto_handoff_opt;
    handoff_threshold = Option.value ~default:old.handoff_threshold p.handoff_threshold_opt;
    handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec p.handoff_cooldown_sec_opt;
    max_context_override = (match p.max_context_override_opt with Some _ as v -> v | None -> old.max_context_override);
    updated_at = now_iso ();
  } in
  match
    validate_sandbox_settings ~allowed_paths
  with
  | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string TurnUpUpdateFailures)
        ~labels:[("keeper", p.name); ("site", Keeper_turn_up_update_failure_site.(to_label Sandbox_validation))]
        ();
      Log.Keeper.warn "update_keeper failed sandbox validation for %s: %s"
        p.name err;
      tool_result_error err
  | Ok () ->
      (match
         Keeper_sandbox_runtime.ensure_keeper_startup_preflight
           ~timeout_sec:(Env_config_sandbox.Preflight.max_timeout_sec ())
           ~sandbox_profile
       with
       | Error err ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string TurnUpUpdateFailures)
             ~labels:[("keeper", p.name); ("site", Keeper_turn_up_update_failure_site.(to_label Sandbox_preflight))]
             ();
           Log.Keeper.warn "update_keeper failed sandbox preflight for %s: %s"
             p.name err;
           tool_result_error err
       | Ok () ->
         let runtime_assignment_result =
           match p.runtime_id_opt with
           | None -> Ok ()
           | Some runtime_id ->
             Runtime.set_runtime_id_for_keeper
               ~keeper_name:p.name
               ~runtime_id
               ()
         in
         (match runtime_assignment_result with
          | Error err ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string TurnUpUpdateFailures)
              ~labels:
                [ ( "keeper", p.name )
                ; ( "site"
                  , Keeper_turn_up_update_failure_site.(to_label Runtime_assignment)
                  )
                ]
              ();
            Log.Keeper.warn
              "update_keeper failed runtime assignment for %s: %s"
              p.name
              err;
            tool_result_error err
          | Ok () ->
            (match write_meta ~force ctx.config updated with
             | Error e ->
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string WriteMetaFailures)
                   ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
                   ();
                 tool_result_error e
             | Ok () ->
               stop_keepalive ~base_path:ctx.config.base_path updated.name;
               start_keepalive ctx updated;
               tool_result_ok (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json updated)))))
