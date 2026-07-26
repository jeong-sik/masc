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

let invoke_after_stop_join_hook () =
  Option.iter
    (fun after_stop_join -> after_stop_join ())
    (Eio.Fiber.get after_stop_join_hook_key)
;;

module For_testing = struct
  let with_after_stop_join ~after_stop_join fn =
    Eio.Fiber.with_binding after_stop_join_hook_key after_stop_join fn
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
  let active_goal_ids_for source_meta =
    match p.active_goal_ids_opt with
    | Some _ -> validated_active_goal_ids
    | None ->
      Option.value
        ~default:source_meta.active_goal_ids
        p.profile_defaults.active_goal_ids
  in
  let allowed_paths_for source_meta =
    Option.value ~default:source_meta.allowed_paths p.allowed_paths_opt
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
         let runtime_assignment () =
           match p.runtime_id_opt with
           | None -> Ok ()
           | Some runtime_id ->
             Runtime.set_runtime_id_for_keeper
               ~keeper_name:p.name
               ~runtime_id
               ()
         in
         let with_runtime_assignment fn =
           match runtime_assignment () with
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
           | Ok () -> fn ()
         in
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
           let stop_outcome =
             stop_keepalive_and_await
               ~base_path:ctx.config.base_path
               updated.name
           in
           invoke_after_stop_join_hook ();
           let run_update permit =
             match
               Keeper_registry.get
                 ~base_path:ctx.config.base_path
                 updated.name
             with
             | Some replacement ->
               tool_result_error
                 (Printf.sprintf
                    "keeper update rejected because a replacement lane raced \
                     the stopped lane: %s"
                    (start_keepalive_outcome_to_string
                       (Keepalive_already_registered replacement)))
             | None ->
               (match Keeper_meta_store.read_meta ctx.config updated.name with
                | Error detail ->
                  tool_result_error
                    ("keeper update durable revalidation failed: " ^ detail)
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
                      "keeper update durable state became Dead; retry through \
                       the dead-revival transaction"
                  else
                  let updated =
                    build_updated ~clear_pause_state:false latest
                  in
                  (match
                     validate_sandbox_settings
                       ~allowed_paths:updated.allowed_paths
                   with
                   | Error detail -> tool_result_error detail
                   | Ok () ->
               with_runtime_assignment (fun () ->
            (* The lane join intentionally happens before durable admission.
               Re-read and re-derive the caller's explicit intent after admission
               so a concurrent lifecycle mutation cannot be overwritten by the
               stale pre-join snapshot. Any later CAS conflict fails closed. *)
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
                  write_meta ctx.config updated
                with
                | Error e ->
                    Otel_metric_store.inc_counter
                      Keeper_metrics.(to_string WriteMetaFailures)
                      ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
                      ();
                    tool_result_error e
                | Ok () ->
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
               enqueue_goal_assignment_wakes
                 ~old_ids:latest.active_goal_ids
                 updated;
               let launch_outcome =
                 start_keepalive_under_admission permit ctx updated
               in
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
                  | Keepalive_transaction_admission_denied _
                  | Keepalive_identity_unrepairable
                  | Keepalive_registration_rejected _
                  | Keepalive_fiber_start_rejected _
                  | Keepalive_lane_ownership_lost
                  | Keepalive_fork_rejected _ ) as rejected ->
                  tool_result_error
                    (Printf.sprintf
                       "keeper metadata was updated but lane restart failed: %s"
                       (start_keepalive_outcome_to_string rejected))))))))
           in
           (match
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
                "keeper update lifecycle admission release requires attention \
                 keeper=%s failure=%s"
                updated.name
                (Keeper_lifecycle_admission.Durable_transaction
                 .authority_failure_to_wire
                   failure);
              result
            | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked
                reason ->
              tool_result_error
                ("keeper update blocked by lifecycle authority: "
                 ^ Keeper_lifecycle_admission.Durable_transaction
                   .blocked_reason_to_wire
                     reason))
