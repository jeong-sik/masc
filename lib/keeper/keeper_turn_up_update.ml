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
  let resume_paused_keeper = old.paused in
  let dead_revival_requested =
    resume_paused_keeper
    &&
    match old.latched_reason with
    | Some Keeper_latched_reason.Dead_tombstone -> true
    | Some (Keeper_latched_reason.Operator_paused _)
    | None -> false
  in
  if resume_paused_keeper then (
    let blocker_class, blocker_detail =
      match old.runtime.last_blocker with
      | Some info -> blocker_class_to_string info.klass, info.detail
      | None -> "none", ""
    in
    Log.Keeper.warn
      "update_keeper resumed paused keeper %s; clearing \
       last_blocker.klass=%s last_blocker.detail=%S"
      old.name blocker_class blocker_detail);
  let source_meta = old in
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
    autoboot_enabled;
    active_goal_ids;
    paused = if resume_paused_keeper then false else old.paused;
    (* Operator-sanctioned resume clears the terminal latch (Dead_tombstone
       included) so a sanctioned keeper_up revives a latched keeper.  Without
       this [latched_reason] survives a paused-clearing resume and every
       latch-keyed lifecycle admission keeps denying revival forever even after
       [paused] is cleared. *)
    latched_reason =
      if resume_paused_keeper then None else source_meta.latched_reason;
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
    always_allow =
      Dashboard_utils.first_some p.profile_defaults.always_allow old.always_allow;
    proactive = {
      enabled =
        (match p.proactive_enabled_opt with
         | Some v -> v
         | None ->
             (match p.profile_defaults.proactive_enabled with
              | Some v -> v
              | None -> old.proactive.enabled));
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
          p.compaction_cooldown_sec_opt
        |> normalize_compaction_cooldown_sec;
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
            let enqueue_goal_assignment_wakes (meta : keeper_meta) =
              let (_ : string list) =
                Keeper_goal_assignment_wake.enqueue_goal_assigned_wakes
                  ~config:ctx.config
                  ~keeper_name:meta.name
                  ~assigned_by:"keeper_up"
                  ~old_ids:old.active_goal_ids
                  ~new_ids:meta.active_goal_ids
                  ()
              in
              ()
            in
            if dead_revival_requested
            then
              (match
                 Keeper_dead_revival_transaction.revive
                   ctx
                   ~original:old
                   ~candidate:updated
               with
               | Error error ->
                 Otel_metric_store.inc_counter
                   Keeper_metrics.(to_string TurnUpUpdateFailures)
                   ~labels:[ "keeper", updated.name; "site", "dead_revival_transaction" ]
                   ();
                 tool_result_error
                   (Keeper_dead_revival_transaction.error_to_string error)
               | Ok success ->
                 enqueue_goal_assignment_wakes success.meta;
                 tool_result_ok_data (Keeper_meta_json.meta_to_json success.meta))
            else
            (* CAS-merge instead of a force write: a dashboard/turn-up edit
               builds [updated] from a meta snapshot ([old]), so a concurrent
               keeper turn that bumped cumulative usage counters between the
               read and this write would otherwise be silently rewound
               (total_turns 385->370, 2026-06-10). This is an explicit operator
               lifecycle action, so it owns pause/resume fields while taking
               cumulative counters as [max latest caller]. *)
            (match
               write_meta_with_merge
                 ~merge:Keeper_meta_merge.monotonic_usage_counters
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
               enqueue_goal_assignment_wakes updated;
               let stop_outcome =
                 stop_keepalive_and_await
                   ~base_path:ctx.config.base_path
                   updated.name
               in
               let launch_outcome = start_keepalive ctx updated in
               (match launch_outcome with
                | Keepalive_started _ ->
                  tool_result_ok_data (Keeper_meta_json.meta_to_json updated)
                | Keepalive_already_registered entry ->
                  let stop_detail =
                    match stop_outcome with
                    | Keeper_not_registered -> "keeper was not registered before restart"
                    | Keeper_joined _ -> "previous keeper lane joined"
                  in
                  tool_result_error
                    (Printf.sprintf
                       "keeper update launch conflicted after %s: %s"
                       stop_detail
                       (start_keepalive_outcome_to_string
                          (Keepalive_already_registered entry)))
                | ( Keepalive_persistence_denied _
                  | Keepalive_lifecycle_denied _
                  | Keepalive_identity_unrepairable
                  | Keepalive_registration_rejected _
                  | Keepalive_fiber_start_rejected _
                  | Keepalive_lane_ownership_lost
                  | Keepalive_fork_rejected _ ) as rejected ->
                  tool_result_error
                    (Printf.sprintf
                       "keeper metadata was updated but lane restart failed: %s"
                       (start_keepalive_outcome_to_string rejected)))))
