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

let after_stop_join_hook_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let after_candidate_write_hook_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let launch_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let supersession_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let phase_b_admission_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let durable_revalidation_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let runtime_rollback_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let candidate_write_failure_hook_key : string Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let after_runtime_assignment_hook_key : (unit -> unit) Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let invoke_after_stop_join_hook () =
  Option.iter
    (fun after_stop_join -> after_stop_join ())
    (Eio.Fiber.get after_stop_join_hook_key)
;;

let invoke_after_candidate_write_hook () =
  Option.iter
    (fun after_candidate_write -> after_candidate_write ())
    (Eio.Fiber.get after_candidate_write_hook_key)
;;

let invoke_after_runtime_assignment_hook () =
  Option.iter
    (fun hook -> hook ())
    (Eio.Fiber.get after_runtime_assignment_hook_key)
;;

module For_testing = struct
  let with_after_stop_join ~after_stop_join fn =
    Eio.Fiber.with_binding after_stop_join_hook_key after_stop_join fn
  ;;

  let with_after_candidate_write ~after_candidate_write fn =
    Eio.Fiber.with_binding
      after_candidate_write_hook_key
      after_candidate_write
      fn
  ;;

  let with_launch_failure ~detail fn =
    Eio.Fiber.with_binding launch_failure_hook_key detail fn
  ;;

  let with_supersession_failure ~detail fn =
    Eio.Fiber.with_binding supersession_failure_hook_key detail fn
  ;;

  let with_phase_b_admission_failure ~detail fn =
    Eio.Fiber.with_binding phase_b_admission_failure_hook_key detail fn
  ;;

  let with_durable_revalidation_failure ~detail fn =
    Eio.Fiber.with_binding durable_revalidation_failure_hook_key detail fn
  ;;

  let with_runtime_rollback_failure ~detail fn =
    Eio.Fiber.with_binding runtime_rollback_failure_hook_key detail fn
  ;;

  let with_candidate_write_failure ~detail fn =
    Eio.Fiber.with_binding candidate_write_failure_hook_key detail fn
  ;;

  let with_after_runtime_assignment ~after_runtime_assignment fn =
    Eio.Fiber.with_binding
      after_runtime_assignment_hook_key
      after_runtime_assignment
      fn
  ;;
end

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

type revival_decision = {
  dead_revival_requested : bool;
  clear_pause_state : bool;
}

let revival_decision ~(latched_reason : Keeper_latched_reason.t option)
    ~(paused : bool) : revival_decision =
  let dead_revival_requested =
    match latched_reason with
    | Some Keeper_latched_reason.Dead_tombstone -> true
    | Some
        ( Keeper_latched_reason.Operator_paused _
        | Keeper_latched_reason.Transcript_corruption_reset_required )
    | None ->
      false
  in
  {
    dead_revival_requested;
    clear_pause_state = dead_revival_requested;
  }

let dead_revival_error_kind error =
  let open Keeper_dead_revival_transaction in
  match error with
  | Reservation_conflict _ -> "reservation_conflict"
  | Nonce_allocation_failed _ -> "nonce_allocation_failed"
  | Journal_conflict _ -> "journal_conflict"
  | Journal_ownership_changed _ -> "journal_ownership_changed"
  | Journal_publication_indeterminate _ -> "journal_publication_indeterminate"
  | Journal_published_with_failure _ -> "journal_published_with_failure"
  | Journal_published_with_warnings _ -> "journal_published_with_warnings"
  | Journal_read_settlement_failed _ -> "journal_read_settlement_failed"
  | Journal_write_failed _ -> "journal_write_failed"
  | Runtime_assignment_failed _ -> "runtime_assignment_failed"
  | Payload_operation_failed _ -> "payload_operation_failed"
  | Transaction_lock_failed _ -> "transaction_lock_failed"
  | Post_commit_cleanup_required _ -> "post_commit_cleanup_required"
  | Durable_snapshot_missing -> "durable_snapshot_missing"
  | Durable_snapshot_changed -> "durable_snapshot_changed"
  | Registry_conflict _ -> "registry_conflict"
  | Durable_commit_failed _ -> "durable_commit_failed"
  | Durable_commit_unreadable _ -> "durable_commit_unreadable"
  | Launch_failed _ -> "launch_failed"
  | Rollback_failed _ -> "rollback_failed"
;;

let registry_entry_commit_evidence_json
      (entry : Keeper_registry.registry_entry)
  =
  `Assoc
    [ "name", `String entry.name
    ; "meta", Keeper_meta_json.meta_to_json entry.meta
    ; "phase", `String (Keeper_state_machine.phase_to_string entry.phase)
    ; "transition_seq", `Int entry.transition_seq
    ]
;;

let committed_with_cleanup_required_json
      ~(committed : keeper_meta)
      ~(entry : Keeper_registry.registry_entry)
      ~(cleanup_error : Keeper_dead_revival_transaction.error)
  =
  `Assoc
    [ "outcome", `String "dead_revival_committed_with_cleanup_required"
    ; "launch_committed", `Bool true
    ; "transaction_cleanup_required", `Bool true
    ; "retry_disposition", `String "do_not_retry_revival"
    ; "committed", Keeper_meta_json.meta_to_json committed
    ; "registry_entry", registry_entry_commit_evidence_json entry
    ; ( "cleanup_error"
      , `Assoc
          [ "kind", `String (dead_revival_error_kind cleanup_error)
          ; ( "message"
            , `String
                (Keeper_dead_revival_transaction.error_to_string
                   cleanup_error) )
          ] )
    ]
;;

let update_keeper ?(preserve_prompt_defaults = false)
    (ctx : _ context) (p : parsed_args) (old : keeper_meta) : tool_result
    =
  match resolve_active_goal_ids ctx.config p old.active_goal_ids with
  | Error msg -> tool_result_error msg
  | Ok validated_active_goal_ids ->
  let active_goal_ids_for (source_meta : keeper_meta) =
    match p.active_goal_ids_opt with
    | Some _ -> validated_active_goal_ids
    | None ->
      Option.value
        ~default:source_meta.active_goal_ids
        p.profile_defaults.active_goal_ids
  in
  let allowed_paths_for (source_meta : keeper_meta) =
    match p.allowed_paths_opt with
    | Some allowed_paths -> allowed_paths
    | None -> source_meta.allowed_paths
  in
  match
    match p.sandbox_profile_opt with
    | None -> Ok None
    | Some raw ->
      match sandbox_profile_of_string raw with
      | Some sp -> Ok (Some sp)
      | None ->
        Error
          (Printf.sprintf "invalid sandbox_profile: %S (expected: local or docker)" raw)
  with
  | Error msg -> tool_result_error msg
  | Ok sandbox_profile_override ->
  match
    match p.network_mode_opt with
    | None -> Ok None
    | Some raw ->
      match network_mode_of_string raw with
      | Some nm -> Ok (Some nm)
      | None ->
        Error
          (Printf.sprintf "invalid network_mode: %S (expected: inherit or none)" raw)
  with
  | Error msg -> tool_result_error msg
  | Ok network_mode_override ->
  let { dead_revival_requested; clear_pause_state } =
    revival_decision ~latched_reason:old.latched_reason ~paused:old.paused
  in
  if clear_pause_state then (
    let blocker_class, blocker_detail =
      match old.runtime.last_blocker with
      | Some info -> blocker_class_to_string info.klass, info.detail
      | None -> "none", ""
    in
    Log.Keeper.warn
      "update_keeper reviving dead keeper %s; clearing \
       last_blocker.klass=%s last_blocker.detail=%S"
      old.name blocker_class blocker_detail);
  let build_updated ~clear_pause_state source_meta =
    let allowed_paths = allowed_paths_for source_meta in
    let sandbox_profile =
      Option.value
        ~default:source_meta.sandbox_profile
        sandbox_profile_override
    in
    let network_mode =
      Option.value
        ~default:source_meta.network_mode
        network_mode_override
    in
    let autoboot_enabled =
      match p.autoboot_enabled_opt, p.profile_defaults.autoboot_enabled with
      | Some value, _ -> value
      | None, Some value -> value
      | None, None -> source_meta.autoboot_enabled
    in
    let mention_targets =
      resolve_mention_targets
        ~mention_targets_opt:p.mention_targets_opt
        ~fallback_targets:
          (if source_meta.mention_targets <> []
           then source_meta.mention_targets
           else p.profile_defaults.mention_targets)
        ~name:p.name
    in
    { source_meta with
      instructions =
        (match p.instructions_arg with
         | Some value -> value
         | None ->
           if preserve_prompt_defaults
           then source_meta.instructions
           else
             Option.value
               ~default:
                 (if String.trim source_meta.instructions <> ""
                  then source_meta.instructions
                  else
                    Option.value
                      ~default:""
                      p.profile_defaults.instructions)
               p.instructions_opt)
    ; allowed_paths
    ; sandbox_profile
    ; network_mode
    ; autoboot_enabled
    ; active_goal_ids = active_goal_ids_for source_meta
    ; paused = if clear_pause_state then false else source_meta.paused
    ; (* The dedicated Dead-tombstone revival clears the terminal latch together
         with [paused]. Ordinary keeper_up reconfiguration preserves both fields;
         it cannot impersonate the receipt-first Resume_owner transaction. *)
      latched_reason =
        if clear_pause_state then None else source_meta.latched_reason
    ; runtime =
        (if clear_pause_state
         then { source_meta.runtime with last_blocker = None }
         else source_meta.runtime)
    ; mention_targets
    ; telemetry_feedback_enabled =
        Dashboard_utils.first_some
          p.profile_defaults.telemetry_feedback_enabled
          source_meta.telemetry_feedback_enabled
    ; telemetry_feedback_window_hours =
        Dashboard_utils.first_some
          p.profile_defaults.telemetry_feedback_window_hours
          source_meta.telemetry_feedback_window_hours
    ; always_allow =
        Dashboard_utils.first_some
          p.profile_defaults.always_allow
          source_meta.always_allow
    ; proactive =
        { enabled =
            (match p.proactive_enabled_opt with
             | Some value -> value
             | None ->
               Option.value
                 ~default:source_meta.proactive.enabled
                 p.profile_defaults.proactive_enabled)
        }
    ; max_context_override =
        (if p.max_context_override_present
         then p.max_context_override_opt
         else source_meta.max_context_override)
    ; updated_at = now_iso ()
    }
  in
  let updated = build_updated ~clear_pause_state old in
  match
    validate_sandbox_settings ~allowed_paths:updated.allowed_paths
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
         let enqueue_goal_assignment_wakes ~old_ids (meta : keeper_meta) =
           let (_ : string list) =
             Keeper_goal_assignment_wake.enqueue_goal_assigned_wakes
               ~config:ctx.config
               ~keeper_name:meta.name
               ~assigned_by:"keeper_up"
               ~old_ids
               ~new_ids:meta.active_goal_ids
               ()
           in
           ()
         in
         if dead_revival_requested
         then
           match
             Keeper_dead_revival_transaction.revive
               ?runtime_id:p.runtime_id_opt
               ctx
               ~original:old
               ~candidate:updated
           with
           | Error
               (Keeper_dead_revival_transaction.Post_commit_cleanup_required
                  { committed; entry; cleanup_error }) ->
             enqueue_goal_assignment_wakes
               ~old_ids:old.active_goal_ids
               committed;
             tool_result_ok_data
               (committed_with_cleanup_required_json
                  ~committed
                  ~entry
                  ~cleanup_error)
           | Error error ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string TurnUpUpdateFailures)
               ~labels:
                 [ "keeper", updated.name
                 ; "site", "dead_revival_transaction"
                 ]
               ();
             tool_result_error
               (Keeper_dead_revival_transaction.error_to_string error)
           | Ok success ->
             enqueue_goal_assignment_wakes
               ~old_ids:old.active_goal_ids
               success.meta;
             tool_result_ok_data
               (Keeper_meta_json.meta_to_json success.meta)
          else
           let same_lane
                 (left : Keeper_registry.registry_entry)
                 (right : Keeper_registry.registry_entry)
             =
             Keeper_lane.Id.equal
               (Keeper_lane.id left.lane)
               (Keeper_lane.id right.lane)
           in
           let same_identity
                 (entry : Keeper_registry.registry_entry)
                 (meta : keeper_meta)
             =
             Keeper_id.Trace_id.equal
               entry.meta.runtime.trace_id
               meta.runtime.trace_id
             && Int.equal entry.meta.runtime.nonce meta.runtime.nonce
           in
           let autonomous_admitted (meta : keeper_meta) =
             match
               Keeper_lifecycle_admission.state
                 ~paused:meta.paused
                 ~latched_reason:meta.latched_reason
               |> Keeper_lifecycle_admission.admit_autonomous
             with
             | Keeper_lifecycle_admission.Autonomous_admitted -> true
             | Keeper_lifecycle_admission.Autonomous_denied _ -> false
           in
           let admission_error reason =
             tool_result_error
               ("keeper update blocked by lifecycle authority: "
                ^ Keeper_lifecycle_admission.Durable_transaction
                  .blocked_reason_to_wire
                    reason)
           in
           let prepare_exact_stop _permit =
             match
               Keeper_lifecycle_reservation.current
                 ~base_path:ctx.config.base_path
                 ~keeper_name:updated.name
             with
             | Some owner ->
               Error
                 (tool_result_error
                    ("keeper update blocked by lifecycle reservation: "
                     ^ Keeper_lifecycle_reservation.snapshot_to_string owner))
             | None ->
               (match Keeper_meta_store.read_meta ctx.config updated.name with
                | Error detail ->
                  Error
                    (tool_result_error
                       ("keeper update durable pre-stop read failed: " ^ detail))
                | Ok None ->
                  Error
                    (tool_result_error
                       "keeper update durable pre-stop read found no metadata")
                | Ok (Some latest) ->
                  let latest_revival =
                    revival_decision
                      ~latched_reason:latest.latched_reason
                      ~paused:latest.paused
                  in
                  if latest_revival.dead_revival_requested
                  then
                    Error
                      (tool_result_error
                         "keeper update durable state became Dead; retry through \
                          the dead-revival transaction")
                  else
                    let candidate =
                      build_updated ~clear_pause_state:false latest
                    in
                    (match
                       validate_sandbox_settings
                         ~allowed_paths:candidate.allowed_paths
                     with
                     | Error detail -> Error (tool_result_error detail)
                     | Ok () ->
                       (match
                          Keeper_registry.get
                            ~base_path:ctx.config.base_path
                            updated.name
                        with
                        | None ->
                          (match
                             Keeper_lifecycle_reservation.acquire
                               ~base_path:ctx.config.base_path
                               ~keeper_name:updated.name
                               ~expected_generation:latest.runtime.nonce
                               ~purpose:Keeper_lifecycle_reservation.Keeper_update
                           with
                           | Error
                               (Keeper_lifecycle_reservation.Already_reserved
                                  owner) ->
                             Error
                               (tool_result_error
                                  ("keeper update could not reserve lifecycle: "
                                   ^ Keeper_lifecycle_reservation
                                     .snapshot_to_string
                                       owner))
                           | Ok token -> Ok (latest, None, token))
                        | Some entry when same_identity entry latest ->
                          (match
                             Keeper_lifecycle_reservation.acquire
                               ~base_path:ctx.config.base_path
                               ~keeper_name:updated.name
                               ~expected_generation:latest.runtime.nonce
                               ~purpose:Keeper_lifecycle_reservation.Keeper_update
                           with
                           | Error
                               (Keeper_lifecycle_reservation.Already_reserved
                                  owner) ->
                             Error
                               (tool_result_error
                                  ("keeper update could not reserve lifecycle: "
                                   ^ Keeper_lifecycle_reservation
                                     .snapshot_to_string
                                       owner))
                           | Ok token ->
                             request_entry_stop entry;
                             Ok (latest, Some entry, token))
                        | Some replacement ->
                          Error
                            (tool_result_error
                               (Printf.sprintf
                                  "keeper update refused to stop a lane with \
                                   different durable identity: %s"
                                  (start_keepalive_outcome_to_string
                                     (Keepalive_already_registered
                                        replacement)))))))
           in
           let phase_a =
             match
               Keeper_lifecycle_admission.Durable_transaction
               .with_durable_lifecycle_admission
                 ctx.config
                 ~keeper_name:updated.name
                 prepare_exact_stop
             with
             | Keeper_lifecycle_admission.Durable_transaction
               .Admission_completed result ->
               result
             | Keeper_lifecycle_admission.Durable_transaction
               .Admission_completed_with_attention (result, failure) ->
               Log.Keeper.error
                 "keeper update pre-stop admission release requires attention \
                  keeper=%s failure=%s"
                 updated.name
                 (Keeper_lifecycle_admission.Durable_transaction
                  .authority_failure_to_wire
                    failure);
               result
             | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked
                 reason ->
               Error (admission_error reason)
           in
           let run_transaction () =
             match phase_a with
             | Error result -> result
  | Ok (_phase_a_meta, stop_ticket, update_token) ->
               let token_released = ref false in
               let restart_current_requested = ref None in
               let release_update_token () =
                 if not !token_released
                 then (
                   token_released := true;
                   match Keeper_lifecycle_reservation.release update_token with
                   | Keeper_lifecycle_reservation.Released -> ()
                   | Keeper_lifecycle_reservation.Release_missing ->
                     Log.Keeper.warn
                       "keeper update lifecycle reservation disappeared \
                        keeper=%s"
                       updated.name
                   | Keeper_lifecycle_reservation.Release_not_owner owner ->
                     Log.Keeper.error
                       "keeper update lifecycle reservation changed keeper=%s \
                        owner=%s"
                       updated.name
                       (Keeper_lifecycle_reservation.snapshot_to_string owner))
               in
               let request_current_restart failure =
                 restart_current_requested := Some failure;
                 tool_result_error failure
               in
               Option.iter
                 (fun (entry : Keeper_registry.registry_entry) ->
                   let _lane_exit = Keeper_lane.await_exit entry.lane in
                   let _terminal = Eio.Promise.await entry.done_p in
                   ())
                 stop_ticket;
               invoke_after_stop_join_hook ();
               let run_update_owned permit =
                 match
                   Keeper_lifecycle_reservation.authorize
                     ~token:update_token
                     ~base_path:ctx.config.base_path
                     ~keeper_name:updated.name
                     ()
                 with
                 | Error owner ->
                   request_current_restart
                     ("keeper update phase-B lost lifecycle reservation: "
                      ^ Keeper_lifecycle_reservation.snapshot_to_string owner)
                 | Ok () ->
                   let replacement =
                     match
                       Keeper_registry.get
                         ~base_path:ctx.config.base_path
                         updated.name,
                       stop_ticket
                     with
                     | None, _ -> None
                     | Some current, Some expected
                       when same_lane current expected ->
                       None
                     | Some current, _ -> Some current
                   in
                   (match replacement with
                    | Some current ->
                      tool_result_error
                        (Printf.sprintf
                           "keeper update rejected because a replacement lane \
                            won after the exact join: %s"
                           (start_keepalive_outcome_to_string
                              (Keepalive_already_registered current)))
                    | None ->
                      let restart_meta (meta : keeper_meta) =
                        if not (autonomous_admitted meta)
                        then Ok ()
                        else
                          match
                            start_keepalive_under_admission
                              ~lifecycle_token:update_token
                              ~durable_meta_bootstrap:
                                Durable_meta_already_committed
                              permit
                              ctx
                              meta
                          with
                          | Keepalive_started _ -> Ok ()
                          | Keepalive_already_registered entry
                            when not
                                   (Keeper_registry.lane_has_exited entry) ->
                            Ok ()
                          | Keepalive_registration_rejected
                              (Keeper_registry
                               .Registration_shutdown_reserved _) ->
                            Ok ()
                          | rejected ->
                            Error
                              (start_keepalive_outcome_to_string rejected)
                      in
                      let fail_and_restart meta failure =
                        match restart_meta meta with
                        | Ok () -> tool_result_error failure
                        | Error detail ->
                          tool_result_error
                            (failure
                             ^ "; lane rollback failed: "
                             ^ detail)
                      in
                      (match
                         match
                           Eio.Fiber.get
                             durable_revalidation_failure_hook_key
                         with
                         | Some detail -> Error detail
                         | None ->
                           Keeper_meta_store.read_meta
                             ctx.config
                             updated.name
                       with
                       | Error detail ->
                         request_current_restart
                           ("keeper update durable revalidation failed: "
                            ^ detail)
                       | Ok None ->
                         tool_result_error
                           "keeper update durable revalidation found no metadata"
                       | Ok (Some latest) ->
                         let latest_revival =
                           revival_decision
                             ~latched_reason:latest.latched_reason
                             ~paused:latest.paused
                         in
                         if latest_revival.dead_revival_requested
                         then
                           tool_result_error
                             "keeper update durable state became Dead; retry \
                              through the dead-revival transaction"
                         else
                           let candidate =
                             build_updated ~clear_pause_state:false latest
                           in
                           (match
                              validate_sandbox_settings
                                ~allowed_paths:candidate.allowed_paths
                            with
                            | Error detail ->
                              fail_and_restart latest detail
                            | Ok () ->
                              (match
                                 Keeper_shutdown_supersession.preflight
                                   ~config:ctx.config
                                   ~keeper_name:candidate.name
                                   ~actor:ctx.agent_name
                               with
                               | Error error ->
                                 fail_and_restart
                                   latest
                                   (Keeper_shutdown_supersession
                                    .error_to_string
                                      error)
                                 | Ok supersession ->
                                   let previous_runtime =
                                     Runtime.runtime_id_for_keeper candidate.name
                                   in
                                   let candidate_runtime =
                                     match p.runtime_id_opt with
                                     | None -> previous_runtime
                                     | Some runtime_id -> Some runtime_id
                                   in
                                   (match
                                      Keeper_runtime_meta_transaction.prepare
                                        ~operation:
                                          Keeper_runtime_meta_journal.Update
                                        ~shutdown_supersession:
                                          (Some supersession)
                                        ~config:ctx.config
                                        ~keeper_name:candidate.name
                                        ~previous_runtime
                                        ~candidate_runtime
                                        ~previous_meta:(Some latest)
                                        ~candidate_meta:candidate
                                    with
                                    | Error failure ->
                                      fail_and_restart
                                        latest
                                        (Keeper_runtime_meta_transaction
                                         .recovery_failure_to_string
                                           failure)
                                    | Ok runtime_meta_intent ->
                                   let same_runtime_target target =
                                     Option.equal
                                       String.equal
                                       (Runtime.runtime_id_for_keeper candidate.name)
                                       target
                                   in
                                   let gate = ref None in
                                   let launch_committed = ref false in
                                   let last_recovery_failure = ref None in
                                   let settle_registered_lane () =
                                     Option.iter abort_launch_gate !gate;
                                     match
                                       Keeper_registry.get
                                         ~base_path:ctx.config.base_path
                                         candidate.name
                                     with
                                     | None -> ()
                                     | Some entry ->
                                       request_entry_stop entry;
                                       let _lane_exit =
                                         Keeper_lane.await_exit entry.lane
                                       in
                                       let _terminal =
                                         Eio.Promise.await entry.done_p
                                       in
                                       ()
                                   in
                                   let recover failure =
                                     settle_registered_lane ();
                                     match
                                       Keeper_runtime_meta_transaction.recover
                                         ~lifecycle_token:update_token
                                         permit
                                         ctx.config
                                         runtime_meta_intent
                                         ~prefer:
                                           (match
                                              Eio.Fiber.get
                                                runtime_rollback_failure_hook_key
                                            with
                                            | Some _ -> `Forward
                                            | None -> `Rollback)
                                     with
                                     | Error recovery_failure ->
                                       let detail =
                                         Keeper_runtime_meta_transaction
                                         .recovery_failure_to_string
                                           recovery_failure
                                       in
                                       last_recovery_failure := Some detail;
                                       Log.Keeper.error
                                         "keeper update exact recovery failed \
                                          keeper=%s detail=%s"
                                         candidate.name
                                         detail;
                                       tool_result_error
                                         (failure
                                          ^ "; recovery failed: "
                                          ^ detail)
                                     | Ok _ ->
                                       let restart_result =
                                         match
                                           Keeper_meta_store.read_meta
                                             ctx.config
                                             candidate.name
                                         with
                                         | Error detail -> Error detail
                                         | Ok None ->
                                           Error
                                             "recovered metadata is missing"
                                         | Ok (Some current) ->
                                           if autonomous_admitted current
                                           then restart_meta current
                                           else Ok ()
                                       in
                                       (match restart_result with
                                        | Ok () ->
                                          last_recovery_failure := None;
                                          tool_result_error failure
                                        | Error detail ->
                                          last_recovery_failure := Some detail;
                                          tool_result_error
                                            (failure
                                             ^ "; recovered lane restart failed: "
                                             ^ detail))
                                   in
                                   let complete_forward () =
                                     Keeper_runtime_meta_transaction
                                     .complete_forward
                                       ~lifecycle_token:update_token
                                       permit
                                       ctx.config
                                       runtime_meta_intent
                                     |> Result.map_error
                                          Keeper_runtime_meta_transaction
                                          .recovery_failure_to_string
                                   in
                                 let apply_runtime_assignment () =
                                   match p.runtime_id_opt with
                                   | None -> Ok ()
                                   | Some runtime_id
                                     when Option.equal
                                            String.equal
                                            previous_runtime
                                            (Some runtime_id) ->
                                     Ok ()
                                     | Some runtime_id ->
                                       (match
                                          Runtime.set_runtime_id_for_keeper
                                            ~keeper_name:candidate.name
                                            ~runtime_id
                                            ()
                                        with
                                        | Ok () -> Ok ()
                                        | Error detail ->
                                          if
                                            same_runtime_target
                                              (Some runtime_id)
                                          then Ok ()
                                          else Error detail)
                                 in
                                 let commit_candidate () =
                                   match apply_runtime_assignment () with
                                   | Error detail ->
                                     recover
                                       ("keeper update runtime assignment \
                                         failed: "
                                        ^ detail)
                                   | Ok () ->
                                     invoke_after_runtime_assignment_hook ();
                                     let candidate_write =
                                       match
                                         Eio.Fiber.get
                                           candidate_write_failure_hook_key
                                       with
                                       | Some detail -> Error detail
                                       | None ->
                                         write_meta_for_lifecycle
                                           permit
                                           update_token
                                           ctx.config
                                           candidate
                                     in
                                     (match candidate_write
                                      with
                                      | Error detail ->
                                        Otel_metric_store.inc_counter
                                          Keeper_metrics.(
                                            to_string WriteMetaFailures)
                                          ~labels:
                                            [ "keeper", candidate.name
                                            ; "phase", "update_keeper"
                                            ]
                                          ();
                                        recover detail
                                      | Ok () ->
                                        invoke_after_candidate_write_hook ();
                                        let supersession_result =
                                          match
                                            Eio.Fiber.get
                                              supersession_failure_hook_key
                                          with
                                          | Some detail ->
                                            `Injected_failure detail
                                          | None ->
                                            (match
                                               Keeper_shutdown_supersession
                                               .commit_after_metadata_update
                                                 ~config:ctx.config
                                                 supersession
                                             with
                                             | Ok committed ->
                                               `Committed committed
                                             | Error
                                                 (Keeper_shutdown_supersession
                                                  .Metadata_committed_admission_owned_by_other
                                                    operation_id) ->
                                               `Newer_shutdown operation_id
                                             | Error error ->
                                               `Failure
                                                 (Keeper_shutdown_supersession
                                                  .error_to_string
                                                    error))
                                        in
                                        (match supersession_result with
                                         | `Injected_failure detail
                                         | `Failure detail ->
                                           recover detail
                                           | `Newer_shutdown operation_id ->
                                             launch_committed := true;
                                             enqueue_goal_assignment_wakes
                                               ~old_ids:latest.active_goal_ids
                                               candidate;
                                             let detail =
                                               Printf.sprintf
                                                 "keeper metadata was updated, \
                                                  but newer shutdown operation \
                                                  %s owns lane admission"
                                                 (Keeper_shutdown_types
                                                  .Operation_id.to_string
                                                    operation_id)
                                             in
                                             (match complete_forward () with
                                              | Ok () ->
                                                tool_result_error detail
                                              | Error cleanup_detail ->
                                                tool_result_error
                                                  (detail
                                                   ^ "; runtime/meta authority \
                                                      cleanup failed: "
                                                   ^ cleanup_detail))
                                         | `Committed
                                             (Keeper_shutdown_supersession
                                              .No_shutdown_admission
                                             | Keeper_shutdown_supersession
                                               .Shutdown_superseded _) ->
                                           (match
                                              Keeper_meta_store.read_meta
                                                ctx.config
                                                candidate.name
                                            with
                                            | Error detail ->
                                              recover
                                                ("committed keeper update \
                                                  could not be reread: "
                                                 ^ detail)
                                            | Ok None ->
                                              recover
                                                "committed keeper update \
                                                 disappeared before launch"
                                            | Ok (Some committed) ->
                                              if
                                                not
                                                  (autonomous_admitted
                                                     committed)
                                              then (
                                                launch_committed := true;
                                                enqueue_goal_assignment_wakes
                                                  ~old_ids:
                                                    latest.active_goal_ids
                                                  committed;
                                                match complete_forward () with
                                                | Ok () ->
                                                  tool_result_ok_data
                                                    (Keeper_meta_json
                                                     .meta_to_json
                                                       committed)
                                                | Error detail ->
                                                  tool_result_error
                                                    ("keeper update committed but \
                                                      runtime/meta authority cleanup \
                                                      failed: "
                                                     ^ detail))
                                              else
                                                (match
                                                   Eio.Fiber.get
                                                     launch_failure_hook_key
                                                 with
                                                 | Some detail ->
                                                   recover
                                                     ("keeper update launch \
                                                       failed: "
                                                      ^ detail)
                                                 | None ->
                                                   let launch_gate =
                                                     create_launch_gate ()
                                                   in
                                                   gate := Some launch_gate;
                                                   (match
                                                      start_keepalive_under_admission
                                                        ~lifecycle_token:
                                                          update_token
                                                        ~launch_gate
                                                        ~durable_meta_bootstrap:
                                                          Durable_meta_already_committed
                                                        permit
                                                        ctx
                                                        committed
                                                    with
                                                    | Keepalive_started _ ->
                                                      commit_launch_gate
                                                        launch_gate;
                                                      launch_committed := true;
                                                      gate := None;
                                                      enqueue_goal_assignment_wakes
                                                        ~old_ids:
                                                          latest.active_goal_ids
                                                        committed;
                                                      (match complete_forward () with
                                                       | Ok () ->
                                                         tool_result_ok_data
                                                           (Keeper_meta_json
                                                            .meta_to_json
                                                              committed)
                                                       | Error detail ->
                                                         tool_result_error
                                                           ("keeper update committed \
                                                             but runtime/meta authority \
                                                             cleanup failed: "
                                                            ^ detail))
                                                    | rejected ->
                                                      recover
                                                        (Printf.sprintf
                                                           "keeper update \
                                                            launch failed: %s"
                                                           (start_keepalive_outcome_to_string
                                                              rejected)))))))
                                 in
                                 (try commit_candidate () with
                                   | Eio.Cancel.Cancelled cause ->
                                     let backtrace =
                                       Printexc.get_raw_backtrace ()
                                     in
                                     if not !launch_committed
                                     then
                                      ignore
                                        (recover
                                             "keeper update cancelled before \
                                              launch commit"
                                            : tool_result);
                                     let cancelled =
                                       match !last_recovery_failure with
                                       | None -> Eio.Cancel.Cancelled cause
                                       | Some detail ->
                                         Eio.Cancel.Cancelled
                                           (Failure
                                              (Printf.sprintf
                                                 "keeper update cancellation \
                                                  recovery failed: %s; original=%s"
                                                 detail
                                                 (Printexc.to_string cause)))
                                     in
                                     Printexc.raise_with_backtrace cancelled backtrace))))))
               in
               let run_update permit =
                 try
                   let result = run_update_owned permit in
                   release_update_token ();
                   result
                 with
                 | exception_ ->
                   let backtrace = Printexc.get_raw_backtrace () in
                   Eio.Cancel.protect release_update_token;
                   Printexc.raise_with_backtrace exception_ backtrace
               in
               let restart_current_after_failure detail =
                 release_update_token ();
                 let restart_current permit =
                   match
                     Keeper_meta_store.read_meta
                       ctx.config
                       updated.name
                   with
                   | Error reread_detail ->
                     Error
                       ("exact current metadata reread failed: "
                        ^ reread_detail)
                   | Ok None ->
                     Error "exact current metadata is missing"
                   | Ok (Some current) ->
                     if not (autonomous_admitted current)
                     then Ok ()
                     else
                       (match
                          start_keepalive_under_admission
                            ~durable_meta_bootstrap:
                              Durable_meta_already_committed
                            permit
                            ctx
                            current
                        with
                        | Keepalive_started _
                        | Keepalive_already_registered _ ->
                          Ok ()
                        | Keepalive_registration_rejected
                            (Keeper_registry
                             .Registration_shutdown_reserved _) ->
                          Ok ()
                        | rejected ->
                          Error
                            (start_keepalive_outcome_to_string rejected))
                 in
                 let restart_result =
                   match
                     Keeper_lifecycle_admission.Durable_transaction
                     .with_durable_lifecycle_admission
                       ctx.config
                       ~keeper_name:updated.name
                       restart_current
                   with
                   | Keeper_lifecycle_admission.Durable_transaction
                     .Admission_completed result ->
                     result
                   | Keeper_lifecycle_admission.Durable_transaction
                     .Admission_completed_with_attention
                       (result, failure) ->
                     Log.Keeper.error
                       "keeper update exact-current restart admission release \
                        requires attention keeper=%s failure=%s"
                       updated.name
                       (Keeper_lifecycle_admission.Durable_transaction
                        .authority_failure_to_wire
                          failure);
                     result
                   | Keeper_lifecycle_admission.Durable_transaction
                     .Admission_blocked reason ->
                     Error
                       (Keeper_lifecycle_admission.Durable_transaction
                        .blocked_reason_to_wire
                          reason)
                 in
                 match restart_result with
                 | Ok () -> tool_result_error detail
                 | Error restart_detail ->
                   tool_result_error
                     (detail
                      ^ "; exact current lane restart failed: "
                      ^ restart_detail)
               in
               let restart_after_admission_failure detail =
                 restart_current_after_failure detail
               in
               let phase_b =
                 match Eio.Fiber.get phase_b_admission_failure_hook_key with
                 | Some detail -> `Injected_failure detail
                 | None ->
                   `Admission
                     (Keeper_lifecycle_admission.Durable_transaction
                      .with_durable_lifecycle_admission
                        ctx.config
                        ~keeper_name:updated.name
                        run_update)
               in
               match phase_b with
               | `Injected_failure detail ->
                 restart_after_admission_failure
                   ("keeper update phase-B admission failed: " ^ detail)
               | `Admission
                   (Keeper_lifecycle_admission.Durable_transaction
                    .Admission_completed result) ->
                 (match !restart_current_requested with
                  | None -> result
                  | Some detail -> restart_current_after_failure detail)
               | `Admission
                   (Keeper_lifecycle_admission.Durable_transaction
                    .Admission_completed_with_attention (result, failure)) ->
                 Log.Keeper.error
                   "keeper update lifecycle admission release requires \
                    attention keeper=%s failure=%s"
                   updated.name
                   (Keeper_lifecycle_admission.Durable_transaction
                    .authority_failure_to_wire
                      failure);
                 (match !restart_current_requested with
                  | None -> result
                  | Some detail -> restart_current_after_failure detail)
               | `Admission
                   (Keeper_lifecycle_admission.Durable_transaction
                    .Admission_blocked reason) ->
                 restart_after_admission_failure
                   ("keeper update phase-B admission blocked: "
                    ^ Keeper_lifecycle_admission.Durable_transaction
                      .blocked_reason_to_wire
                        reason)
               (*
                 Keeper_lifecycle_admission.Durable_transaction
                 .with_durable_lifecycle_admission
                   ctx.config
                   ~keeper_name:updated.name
                   run_update
               with
               | Keeper_lifecycle_admission.Durable_transaction
                 .Admission_completed result ->
                 result
               | Keeper_lifecycle_admission.Durable_transaction
                 .Admission_completed_with_attention (result, failure) ->
                 Log.Keeper.error
                   "keeper update lifecycle admission release requires \
                    attention keeper=%s failure=%s"
                   updated.name
                   (Keeper_lifecycle_admission.Durable_transaction
                    .authority_failure_to_wire
                      failure);
                 result
               | Keeper_lifecycle_admission.Durable_transaction
                 .Admission_blocked reason ->
                 admission_error reason
               *)
           in
           let result = Eio.Cancel.protect run_transaction in
           Eio.Fiber.check ();
           result
