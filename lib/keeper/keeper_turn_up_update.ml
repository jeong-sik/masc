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

let update_keeper ?(preserve_prompt_defaults = false)
    (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result
    =
  match resolve_active_goal_ids ctx.config p old.active_goal_ids with
  | Error msg -> tool_result_error msg
  | Ok active_goal_ids ->
  let profile_default_text opt fallback =
    match opt with
    | Some value when String.trim value <> "" -> value
    | _ -> fallback
  in
  let goal =
    match p.goal_opt with
    | Some g -> normalize_goal_text g
    | None ->
        if preserve_prompt_defaults then old.goal
        else
          profile_default_text p.profile_defaults.goal
            (if String.trim old.goal <> "" then old.goal else "")
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
      ~mention_targets_opt:p.mention_targets_opt
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
  Keeper_turn_livelock.reset_keeper_livelock
    ~base_path:ctx.config.base_path
    ~keeper:old.name;
  (* ETA-LIVELOCK: align typed-escalation classifier with the
     livelock counter reset so an operator-triggered keeper_up
     restores the next block to ERROR (not silent DEBUG demotion
     from a previous threshold_park). *)
  Keeper_livelock_state.reset_for_keeper ~keeper:old.name;
  if old.paused && not resume_paused_keeper then
    Log.Keeper.warn
      "update_keeper kept %s paused because an approval/reconcile gate is pending"
      old.name;
  let source_meta_result =
    if resume_paused_keeper then
      Keeper_unified_turn_no_progress.clear_for_operator_resume
        ~base_path:ctx.config.base_path
        old
    else Ok old
  in
  match source_meta_result with
  | Error err ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string TurnUpUpdateFailures)
      ~labels:
        [ ( "keeper", p.name )
        ; ( "site"
          , Keeper_turn_up_update_failure_site.(to_label No_progress_resume_clear)
          )
        ]
      ();
    Log.Keeper.warn
      "update_keeper failed no_progress resume clear for %s: %s"
      p.name
      err;
    tool_result_error err
  | Ok source_meta ->
  let updated = { source_meta with
    goal;
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
           source_meta.runtime with
           last_blocker = None;
         }
       else source_meta.runtime);
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
      mode = old.compaction.mode;
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
    max_context_override =
      (if p.max_context_override_present then p.max_context_override_opt
       else old.max_context_override);
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
            (* CAS-merge instead of a force write: a dashboard/turn-up edit
               builds [updated] from a meta snapshot ([old]), so a concurrent
               keeper turn that bumped cumulative usage counters between the
               read and this write would otherwise be silently rewound
               (total_turns 385->370, 2026-06-10). [heartbeat_fields_from_disk]
               keeps the caller's edited fields but takes the monotonic
               counters as [max latest caller]. *)
            (match
               write_meta_with_merge
                 ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
                 ctx.config
                 updated
             with
             | Error e ->
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string WriteMetaFailures)
                   ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
                   ();
                 tool_result_error e
             | Ok () ->
               (* RFC-0315 P3 W0: goals that newly entered active_goal_ids
                  wake the keeper once at the assignment edge. Enqueue is
                  durable, so the keepalive restart below delivers it on the
                  new fiber's first cycle. Removals never wake. *)
               let (_ : string list) =
                 Keeper_goal_assignment_wake.enqueue_goal_assigned_wakes
                   ~config:ctx.config
                   ~keeper_name:updated.name
                   ~assigned_by:"keeper_up"
                   ~old_ids:old.active_goal_ids
                   ~new_ids:updated.active_goal_ids
                   ()
               in
               stop_keepalive ~base_path:ctx.config.base_path updated.name;
               start_keepalive ctx updated;
               tool_result_ok (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json updated)))))
