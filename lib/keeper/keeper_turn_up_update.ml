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

let resume_operator_pause
    (ctx : _ context)
    (old : keeper_meta)
  =
  match old.paused, old.latched_reason with
  | true, (None | Some (Keeper_latched_reason.Operator_paused _)) ->
    let request : Keeper_paused_work_resume_transaction.request =
      { owner_nonce = old.runtime.nonce
      ; operator_operation_id =
          Random_id.prefixed ~prefix:"keeper-up-resume-" ~bytes:16
      }
    in
    (match
       Keeper_paused_work_resume_transaction.resume
         ctx.config
         ~keeper_name:old.name
         request
     with
     | Error error ->
       Error
         ("explicit keeper up could not resume operator pause: "
          ^ Keeper_paused_work_resume_transaction.error_to_string error)
     | Ok _ ->
       (match
          Keeper_owner_registry.get
            ~base_path:ctx.config.base_path
            ~keeper_name:old.name
        with
        | Error error ->
          Error
            ("resumed Keeper owner lookup failed: "
             ^ Keeper_owner_registry.lookup_error_to_string error)
        | Ok owner ->
          (match Keeper_owner.exact_projection owner with
           | Error error ->
             Error
               ("resumed Keeper owner projection failed: "
                ^ Keeper_owner.error_to_string error)
           | Ok { meta = None; _ } -> Error "resumed Keeper metadata disappeared"
           | Ok { meta = Some resumed; _ } when resumed.paused ->
             Error "explicit keeper up committed but pause remained set"
           | Ok { meta = Some resumed; _ } -> Ok resumed)))
  | false, _
  | true, Some Keeper_latched_reason.Transcript_corruption_reset_required ->
    Ok old
;;

let turn_in_flight_rejection ~keeper_name
    (info : Keeper_owner.turn_in_flight) : tool_result =
  tool_result_error_data
    ~class_:Tool_result.Workflow_rejection
    (`Assoc
       [ "error", `String "keeper_turn_in_flight"
       ; "keeper", `String keeper_name
       ; ( "block"
         , Keeper_owner.autonomous_block_to_yojson
             (Keeper_owner.Turn_busy (Some info)) )
       ; "metadata_committed", `Bool true
       ; ( "message"
         , `String
             "keeper metadata was updated but the keepalive lane was not \
              restarted: a turn holds this keeper's slot. A keeper's own \
              turn always holds the slot, so masc_keeper_up cannot restart \
              its caller from inside that turn. Retry masc_keeper_up when \
              the keeper is idle to restart the lane." )
       ])
;;

(* The lane swap tears down the registry entry a live turn's finalize path
   still needs: a swap that raced an admitted turn left that turn's slot
   permanently held after its provider run completed (#26542 — a keeper
   calling masc_keeper_up on itself mid-turn locked itself out of every
   subsequent turn until process restart). The swap therefore requires an
   idle Owner, enforced with the same lifecycle reservation the shutdown
   path uses:

   - [begin_shutdown] fences new admissions and samples the current holder
     in one critical section; a published holder rejects the swap (typed,
     no waiting) — a keeper's own turn always holds the slot, so a
     mid-turn self keeper_up lands on that rejection by construction.
   - A holder that acquired the slot but has not yet published bounces at
     its publish-time fence check without running a turn body, so the
     fenced swap window stays turn-free.
   - The fence is rolled back before [start_keepalive]:
     [commit_registration_if_open] refuses lane registration under any
     fence.
   - [Shutdown_already_reserved] with an idle slot proceeds without a
     fence of our own: that is the durable blocked-shutdown supersession
     path (metadata commit takes ownership of the foreign fence), and the
     concurrent-update race it also matches is absorbed by the existing
     launch-conflict arm. *)
let swap_keepalive_lane_fenced (ctx : _ context) (updated : keeper_meta)
  : (joined_stop_result * start_keepalive_outcome, tool_result) result =
  let base_path = ctx.config.base_path in
  let keeper_name = updated.name in
  let rollback ~operation_id =
    match
      Keeper_owner_registry.rollback_shutdown
        ~base_path
        ~keeper_name
        ~operation_id
    with
    | Ok Keeper_owner.Shutdown_rolled_back
    | Ok Keeper_owner.Shutdown_not_reserved
    | Ok (Keeper_owner.Shutdown_reserved_by_other _)
    | Error _ -> ()
  in
  let swap () = stop_keepalive_and_await ~base_path keeper_name in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  match
    Keeper_owner_registry.begin_shutdown ~base_path ~keeper_name ~operation_id
  with
  | Error error ->
    Error
      (tool_result_error
         (Keeper_owner_registry.command_error_to_string error))
  | Ok (Keeper_owner.Shutdown_reserved { in_flight = Some info; _ }) ->
    rollback ~operation_id;
    Error (turn_in_flight_rejection ~keeper_name info)
  | Ok (Keeper_owner.Shutdown_already_reserved
      { in_flight = Some info; _ }) ->
    Error (turn_in_flight_rejection ~keeper_name info)
  | Ok (Keeper_owner.Shutdown_reserved { in_flight = None; _ }) ->
    let stop_outcome =
      match swap () with
      | outcome ->
        rollback ~operation_id;
        outcome
      | exception exn ->
        rollback ~operation_id;
        raise exn
    in
    Ok (stop_outcome, start_keepalive ctx updated)
  | Ok (Keeper_owner.Shutdown_already_reserved { in_flight = None; _ }) ->
    Ok (swap (), start_keepalive ctx updated)
;;

let update_keeper ?(preserve_prompt_defaults = false)
    (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result
    =
  match resume_operator_pause ctx old with
  | Error message -> tool_result_error message
  | Ok old ->
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
  let source_meta = old in
  let updated = { source_meta with
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
    autonomous_instructions = p.autonomous_instructions_opt;
    allowed_paths;
    sandbox_profile;
    network_mode;
    autoboot_enabled;
    paused = old.paused;
    latched_reason = source_meta.latched_reason;
    runtime = source_meta.runtime;
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
            (match
               Keeper_shutdown_supersession.preflight
                 ~config:ctx.config
                 ~keeper_name:updated.name
                 ~actor:ctx.agent_name
             with
             | Error error ->
               tool_result_error
                 (Keeper_shutdown_supersession.error_to_string error)
             | Ok supersession ->
             (match
                Keeper_turn_up_config_persistence.persist
                  ~config:ctx.config
                  ~parsed:p
                  ~meta:updated
              with
              | Error e ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string TurnUpUpdateFailures)
                 ~labels:
                   [ ( "keeper", p.name )
                   ; ( "site"
                     , Keeper_turn_up_update_failure_site.(to_label Config_persistence)
                     )
                   ]
                 ();
               tool_result_error
                 (Printf.sprintf "declarative keeper config write failed: %s" e)
              | Ok _ ->
            (match
               Keeper_owner_registry.apply_meta
                 ~base_path:ctx.config.base_path
                 ~keeper_name:updated.name
                 (Keeper_owner_reducer.Update_profile
                    { instructions = updated.instructions
                    ; autonomous_instructions = updated.autonomous_instructions
                    ; sandbox_profile = updated.sandbox_profile
                    ; sandbox_image = updated.sandbox_image
                    ; network_mode = updated.network_mode
                    ; allowed_paths = updated.allowed_paths
                    ; mention_targets = updated.mention_targets
                    ; proactive_enabled = updated.proactive.enabled
                    ; max_context_override = updated.max_context_override
                    ; autoboot_enabled = updated.autoboot_enabled
                    ; telemetry_feedback_enabled = updated.telemetry_feedback_enabled
                    ; telemetry_feedback_window_hours =
                        updated.telemetry_feedback_window_hours
                    ; always_allow = updated.always_allow
                    ; agent_core_env = updated.agent_core_env
                    ; updated_at = updated.updated_at
                    })
             with
             | Error error ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string WriteMetaFailures)
                 ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
                 ();
               tool_result_error
                 (Keeper_owner_registry.command_error_to_string error)
             | Ok None ->
               tool_result_error "Keeper owner metadata disappeared during update"
             | Ok (Some updated) ->
               (match
                  Keeper_shutdown_supersession.commit_after_metadata_update
                    ~config:ctx.config
                    supersession
                with
                | Error error ->
                  tool_result_error
                    (Keeper_shutdown_supersession.error_to_string error)
                | Ok
                    ( Keeper_shutdown_supersession.No_shutdown_admission
                    | Keeper_shutdown_supersession.Shutdown_superseded _ ) ->
               (* RFC-0315 P3 W0: goals that newly entered active_goal_ids
                  wake the keeper once at the assignment edge. Enqueue is
                  durable, so the keepalive restart below delivers it on the
                  new fiber's first cycle. Removals never wake. *)
               (match swap_keepalive_lane_fenced ctx updated with
                | Error rejection -> rejection
                | Ok (stop_outcome, launch_outcome) ->
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
                | ( Keepalive_lifecycle_denied _
                  | Keepalive_identity_unrepairable
                  | Keepalive_registration_rejected _
                  | Keepalive_fiber_start_rejected _
                  | Keepalive_memory_lane_not_ready _
                  | Keepalive_launch_callback_failed _
                  | Keepalive_lane_ownership_lost
                  | Keepalive_fork_rejected _ ) as rejected ->
                  tool_result_error
                    (Printf.sprintf
                       "keeper metadata was updated but lane restart failed: %s"
                       (start_keepalive_outcome_to_string rejected)))))))))
