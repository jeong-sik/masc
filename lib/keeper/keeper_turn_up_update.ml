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
      { operator_operation_id =
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
  | false, _ -> Ok old
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
      (tool_result_error ~class_:Tool_result.Runtime_failure
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

let config_revision_conflict_code = "keeper_config_revision_conflict"

let config_revision_conflict_data
      ({ expected; observed } : Keeper_turn_up_config_persistence.conflict)
  =
  `Assoc
    [ "code", `String config_revision_conflict_code
    ; "expected", Keeper_turn_up_config_persistence.config_revision_to_yojson expected
    ; "observed", Keeper_turn_up_config_persistence.config_revision_to_yojson observed
    ]
;;

let config_revision_conflict_of_result result =
  match Tool_result.data result with
  | `Assoc fields ->
    (match List.assoc_opt "code" fields with
     | Some (`String code)
       when String.equal code config_revision_conflict_code ->
       (match
          List.assoc_opt "expected" fields,
          List.assoc_opt "observed" fields
        with
        | Some expected_json, Some observed_json ->
          (match
             Keeper_turn_up_config_persistence.config_revision_of_yojson expected_json,
             Keeper_turn_up_config_persistence.config_revision_of_yojson observed_json
           with
           | Ok expected, Ok observed ->
             Some
               ({ expected; observed } :
                 Keeper_turn_up_config_persistence.conflict)
           | Error _, _ | _, Error _ -> None)
        | _ -> None)
     | Some _ | None -> None)
  | _ -> None
;;

let with_config_receipt ~revision ~warnings ~applied result =
  Tool_result.with_metadata
    (`Assoc
       [ ( "keeper_config_write"
         , `Assoc
             [ "revision", Keeper_turn_up_config_persistence.config_revision_to_yojson revision
             ; "applied", `Bool applied
             ; ( "warnings"
               , `List
                   (List.map
                      Keeper_turn_up_config_persistence.warning_to_yojson
                      warnings) )
             ] )
       ])
    result
;;

let reconciliation_authority_fields
      ({ path; detail; observed } :
        Keeper_turn_up_config_persistence.reconciliation)
  =
  let observed =
    match observed with
    | Keeper_turn_up_config_persistence.Observed_revision revision ->
      `Assoc
        [ "state", `String "revision"
        ; "revision", Keeper_turn_up_config_persistence.revision_to_yojson revision
        ]
    | Keeper_turn_up_config_persistence.Unreadable_manifest error ->
      `Assoc [ "state", `String "unreadable"; "detail", `String error ]
  in
  [ "path", `String path
  ; "detail", `String detail
  ; "observed", observed
  ]
;;

let reconciliation_required_data state =
  `Assoc
    (("code", `String "keeper_manifest_reconciliation_required")
     :: reconciliation_authority_fields state)
;;

let reconciliation_authority_data state =
  `Assoc (reconciliation_authority_fields state)
;;

let composite_reconciliation_required_data
      ({ manifest; runtime_assignment } :
        Keeper_turn_up_config_persistence.composite_reconciliation)
  =
  let manifest =
    match manifest with
    | None -> `Null
    | Some state -> reconciliation_authority_data state
  in
  let runtime_assignment =
    match runtime_assignment with
    | None -> `Null
    | Some state ->
      `Assoc
        [ ( "path"
          , match state.path with
            | None -> `Null
            | Some path -> `String path )
        ; "detail", `String state.detail
        ]
  in
  `Assoc
    [ "code", `String "keeper_config_composite_reconciliation_required"
    ; "manifest", manifest
    ; "runtime_assignment", runtime_assignment
    ]
;;

let config_publication_rollback_result detail =
  tool_result_error_data
    ~class_:Tool_result.Runtime_failure
    (`Assoc
      [ "code", `String "keeper_config_publication_rolled_back"
      ; "detail", `String detail
      ])
;;

let config_publication_rollback_of_result result =
  match Tool_result.data result with
  | `Assoc fields ->
    (match List.assoc_opt "code" fields, List.assoc_opt "detail" fields with
     | Some (`String "keeper_config_publication_rolled_back"), Some (`String detail) ->
       Some detail
     | _ -> None)
  | _ -> None
;;

let config_reconciliation_required_of_result result =
  match Tool_result.data result with
  | `Assoc fields ->
    (match List.assoc_opt "code" fields with
     | Some
         (`String
           ( "keeper_manifest_reconciliation_required"
           | "keeper_config_composite_reconciliation_required" )) ->
       Some (`Assoc fields)
     | Some _ | None -> None)
  | _ -> None
;;

type manifest_publication =
  | Publication_rolled_back of
      Keeper_turn_up_config_persistence.outcome * tool_result
  | Publication_applied of
      Keeper_turn_up_config_persistence.outcome
      * keeper_meta
      * Keeper_turn_up_config_persistence.config_revision
  | Publication_applied_with_runtime_failure of
      Keeper_turn_up_config_persistence.outcome
      * Keeper_turn_up_config_persistence.config_revision
      * string

let profile_update_command (meta : keeper_meta) =
  Keeper_owner_reducer.Update_profile
    { instructions = meta.instructions
    ; sandbox_profile = meta.sandbox_profile
    ; sandbox_image = meta.sandbox_image
    ; network_mode = meta.network_mode
    ; mention_targets = meta.mention_targets
    ; proactive_enabled = meta.proactive.enabled
    ; max_context_override = meta.max_context_override
    ; autoboot_enabled = meta.autoboot_enabled
    ; telemetry_feedback_enabled = meta.telemetry_feedback_enabled
    ; telemetry_feedback_window_hours = meta.telemetry_feedback_window_hours
    ; always_allow = meta.always_allow
    ; agent_core_env = meta.agent_core_env
    ; updated_at = meta.updated_at
    }
;;

let finish_published_update ~supersession ctx updated =
  (* Metadata is already durable. A cancelled HTTP/MCP caller must not
     interrupt the matching shutdown supersession, temporary admission-fence
     rollback, or lane restart. *)
  Eio.Cancel.protect (fun () ->
    match
      Keeper_shutdown_supersession.commit_after_metadata_update
        ~config:ctx.config
        supersession
    with
    | Error error ->
      tool_result_error ~class_:Tool_result.Runtime_failure
        (Keeper_shutdown_supersession.error_to_string error)
    | Ok
        ( Keeper_shutdown_supersession.No_shutdown_admission
        | Keeper_shutdown_supersession.Shutdown_superseded _ ) ->
      (match swap_keepalive_lane_fenced ctx updated with
       | Error rejection -> rejection
       | Ok (stop_outcome, launch_outcome) ->
         (match launch_outcome with
          | Keepalive_started _ ->
            tool_result_ok_data (Keeper_meta_json.meta_to_json updated)
          | Keepalive_already_registered entry ->
            let stop_detail =
              match stop_outcome with
              | Keeper_not_registered ->
                "keeper was not registered before restart"
              | Keeper_joined _ -> "previous keeper lane joined"
            in
            tool_result_error ~class_:Tool_result.Workflow_rejection
              (Printf.sprintf
                 "keeper update launch conflicted after %s: %s"
                 stop_detail
                 (start_keepalive_outcome_to_string
                    (Keepalive_already_registered entry)))
          | ( Keepalive_lifecycle_denied _
            | Keepalive_registration_rejected _
            | Keepalive_fiber_start_rejected _
            | Keepalive_memory_lane_not_ready _
            | Keepalive_launch_callback_failed _
            | Keepalive_lane_ownership_lost
            | Keepalive_fork_rejected _ ) as rejected ->
            tool_result_error ~class_:Tool_result.Runtime_failure
              (Printf.sprintf
                 "keeper metadata was updated but lane restart failed: %s"
                 (start_keepalive_outcome_to_string rejected)))))
;;

let finish_publication_after_runtime_failure ~supersession ctx detail =
  Eio.Cancel.protect (fun () ->
    match
      Keeper_shutdown_supersession.commit_after_metadata_update
        ~config:ctx.config
        supersession
    with
    | Error error ->
      tool_result_error ~class_:Tool_result.Runtime_failure
        (Keeper_shutdown_supersession.error_to_string error)
    | Ok
        ( Keeper_shutdown_supersession.No_shutdown_admission
        | Keeper_shutdown_supersession.Shutdown_superseded _ ) ->
      tool_result_error ~class_:Tool_result.Runtime_failure detail)
;;

let update_keeper_with ~apply_profile ?(preserve_prompt_defaults = false)
    ~(expected_config_revision : Keeper_turn_up_config_persistence.config_revision)
    (ctx : _ context) (p : parsed_args)
    (old : keeper_meta) : tool_result
    =
  match
    match p.sandbox_profile_opt with
    (* Same precedence as [effective_meta_of_profile_defaults]: the TOML owns
       this field, and [old.sandbox_profile] is only a fallback. Reading [old]
       first meant a keeper whose meta came back from JSON carried the
       decoder's placeholder rather than its declaration -- so updating a
       keeper that states "microvm" in its TOML was refused for a profile it
       never asked for. *)
    | None ->
      (match p.profile_defaults.sandbox_profile with
       | Some profile -> Ok profile
       | None -> Ok old.sandbox_profile)
    | Some raw ->
      match sandbox_profile_of_string raw with
      | Some sp -> Ok sp
      | None ->
        Error
          (Printf.sprintf
             "invalid sandbox_profile: %S (expected: %s)"
             raw
             (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings))
  with
  | Error msg -> tool_result_error ~class_:Tool_result.Policy_rejection msg
  | Ok sandbox_profile ->
  match
    match p.network_mode_opt with
    | None ->
      (* Same non-durable pin as [sandbox_profile] above: the meta decoder
         fixes [network_mode] to the Local default, so trusting
         [old.network_mode] would flip a TOML-declared "none" to inherit on
         any field-only update. TOML declaration first, then the resolved
         profile's own default. *)
      Ok
        (resolve_network_mode
           ~sandbox_profile
           ~fallback:p.profile_defaults.network_mode)
    | Some raw ->
      match network_mode_of_string raw with
      | Some nm -> Ok nm
      | None ->
        Error
          (Printf.sprintf "invalid network_mode: %S (expected: inherit or none)" raw)
  with
  | Error msg -> tool_result_error ~class_:Tool_result.Policy_rejection msg
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
  (* The sandbox-profile gate that stood here rejected exactly one profile,
     [Local], and that profile no longer exists. What remains is reached the
     same way. *)
         (match
            Keeper_shutdown_supersession.preflight
              ~config:ctx.config
              ~keeper_name:updated.name
              ~actor:ctx.agent_name
          with
          | Error error ->
            tool_result_error ~class_:Tool_result.Runtime_failure
              (Keeper_shutdown_supersession.error_to_string error)
          | Ok supersession ->
            let publish runtime_transaction outcome =
              match
                apply_profile
                     ~base_path:ctx.config.base_path
                     ~keeper_name:updated.name
                     (profile_update_command updated)
              with
              | Error error ->
                   Otel_metric_store.inc_counter
                     Keeper_metrics.(to_string WriteMetaFailures)
                     ~labels:[("keeper", updated.name); ("phase", "update_keeper")]
                     ();
                Keeper_turn_up_config_persistence.Rollback
                  (Publication_rolled_back
                     ( outcome
                     , config_publication_rollback_result
                         (Keeper_owner_registry.command_error_to_string error) ))
              | Ok None ->
                Keeper_turn_up_config_persistence.Rollback
                  (Publication_rolled_back
                     ( outcome
                     , config_publication_rollback_result
                         "Keeper owner metadata disappeared during update" ))
              | Ok (Some published_meta) ->
                let runtime_assignment_result =
                  Runtime.commit_keeper_assignment runtime_transaction
                    ~runtime_id:
                      (match p.runtime_id_opt with
                       | Some runtime_id -> Some runtime_id
                       | None ->
                            (match expected_config_revision.runtime_assignment with
                             | Runtime.Runtime_config_missing -> None
                             | Runtime.Runtime_config_present { assignment; _ } ->
                               (match assignment with
                                | Runtime.Assignment_missing -> None
                                | Runtime.Assignment_present runtime_id -> Some runtime_id)))
                in
                (match runtime_assignment_result with
                    | Ok runtime_write ->
                      let runtime_warnings =
                        Keeper_turn_up_config_persistence
                        .warnings_of_runtime_assignment_write runtime_write
                      in
                      let runtime_assignment =
                        match runtime_write with
                        | Runtime.Assignment_unchanged revision -> revision
                        | Runtime.Assignment_committed { revision; _ } -> revision
                      in
                      let config_revision :
                          Keeper_turn_up_config_persistence.config_revision =
                        { Keeper_turn_up_config_persistence.manifest = outcome.revision
                        ; runtime_assignment
                        }
                      in
                      (match resume_operator_pause ctx published_meta with
                       | Error message ->
                         Keeper_turn_up_config_persistence.Commit_with_warnings
                           ( Publication_applied_with_runtime_failure
                               (outcome, config_revision, message)
                           , runtime_warnings )
                       | Ok resumed_meta ->
                         Keeper_turn_up_config_persistence.Commit_with_warnings
                           ( Publication_applied
                               (outcome, resumed_meta, config_revision)
                           , runtime_warnings ))
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
                      let rollback_profile =
                        apply_profile
                          ~base_path:ctx.config.base_path
                          ~keeper_name:old.name
                          (profile_update_command old)
                      in
                      let detail =
                        match rollback_profile with
                        | Ok (Some _) -> err
                        | Ok None ->
                          err ^ "; Keeper metadata disappeared during rollback"
                        | Error rollback_error ->
                          err ^ "; metadata rollback failed: "
                          ^ Keeper_owner_registry.command_error_to_string rollback_error
                      in
                      Keeper_turn_up_config_persistence.Rollback
                        (Publication_rolled_back
                           (outcome, config_publication_rollback_result detail)))
            in
            (match
               Keeper_turn_up_config_persistence.persist_with_publication
                 ~expected_revision:expected_config_revision
                 ~config:ctx.config
                 ~parsed:p
                 ~meta:updated
                 ~publish
                 ()
             with
             | Error
                 (Keeper_turn_up_config_persistence.Revision_conflict conflict) ->
               tool_result_error_data
                 ~class_:Tool_result.Workflow_rejection
                 (config_revision_conflict_data conflict)
             | Error (Keeper_turn_up_config_persistence.Io_error detail) ->
               Otel_metric_store.inc_counter
                 Keeper_metrics.(to_string TurnUpUpdateFailures)
                 ~labels:
                   [ ( "keeper", p.name )
                   ; ( "site"
                     , Keeper_turn_up_update_failure_site.(to_label Config_persistence)
                     )
                   ]
                 ();
               tool_result_error ~class_:Tool_result.Runtime_failure
                 (Printf.sprintf "declarative keeper config write failed: %s" detail)
             | Error
                 (Keeper_turn_up_config_persistence.Reconciliation_required state) ->
               tool_result_error_data
                 ~class_:Tool_result.Runtime_failure
                 (reconciliation_required_data state)
             | Error
                 (Keeper_turn_up_config_persistence.Composite_reconciliation_required
                    state) ->
               tool_result_error_data
                 ~class_:Tool_result.Runtime_failure
                 (composite_reconciliation_required_data state)
             | Error
                 (Keeper_turn_up_config_persistence.Publication_exception
                    { detail; _ }) ->
               tool_result_error ~class_:Tool_result.Runtime_failure
                 ("keeper config publication raised and was rolled back: " ^ detail)
             | Ok
                 { value = Publication_rolled_back (_outcome, result)
                 ; warnings
                 } ->
               with_config_receipt
                 ~revision:expected_config_revision
                 ~warnings
                 ~applied:false
                 result
             | Ok
                 { value = Publication_applied (_outcome, updated, revision)
                 ; warnings
                 } ->
               finish_published_update ~supersession ctx updated
               |> with_config_receipt
                    ~revision
                    ~warnings
                    ~applied:true
             | Ok
                 { value =
                     Publication_applied_with_runtime_failure
                       (_outcome, revision, detail)
                 ; warnings
                 } ->
               finish_publication_after_runtime_failure
                 ~supersession ctx detail
               |> with_config_receipt
                    ~revision
                    ~warnings
                    ~applied:true))

let update_keeper ?preserve_prompt_defaults ~expected_config_revision ctx p old =
  update_keeper_with
    ~apply_profile:(fun ~base_path ~keeper_name command ->
      Keeper_owner_registry.apply_meta ~base_path ~keeper_name command)
    ?preserve_prompt_defaults
    ~expected_config_revision
    ctx
    p
    old
;;

module For_testing = struct
  let composite_reconciliation_required_data =
    composite_reconciliation_required_data

  let update_keeper_with_apply_profile = update_keeper_with
end
