open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Result.Syntax
open Keeper_tool_read_window
open Keeper_tool_filesystem_guidance
include Keeper_tool_filesystem_runtime_shared
include Keeper_tool_filesystem_runtime_read
include Keeper_tool_filesystem_runtime_owned_read
include Keeper_tool_filesystem_runtime_write_target
include Keeper_tool_filesystem_runtime_write_types
include Keeper_tool_filesystem_runtime_test_seams
include Keeper_tool_filesystem_runtime_created_directory
include Keeper_tool_filesystem_runtime_append
include Keeper_tool_filesystem_runtime_write_gate
include Keeper_tool_filesystem_runtime_capability_failure
include Keeper_tool_filesystem_runtime_created_directory_report
include Keeper_tool_filesystem_runtime_publication

let store_edit_snapshots ~config ~before ~after =
  let store = Tool_blob_store.create ~base_path:config.Workspace.base_path in
  let persist bytes =
    Option.iter (fun hook -> hook ()) (Eio.Fiber.get before_edit_snapshot_key);
    Tool_blob_store.put_durable store ~bytes ~mime:"application/octet-stream"
    |> fun reference -> Tool_output.with_preview reference ""
    |> Tool_output.normalized_artifact_ref_to_json
  in
  try
    let before = persist before in
    let after = persist after in
    `Assoc [ "status", `String "stored"; "before", before; "after", after ]
  with
  | Sys_error detail ->
    `Assoc [ "status", `String "unavailable"; "detail", `String detail ]
  | Unix.Unix_error _ as exn ->
    `Assoc [ "status", `String "unavailable"; "detail", `String (Printexc.to_string exn) ]
;;

let handle_file_write_content_with_outcome
      ~content_source ~content
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ?prepared_edit
      ?prepared_write
      ~(args : Yojson.Safe.t)
      ()
  =
  let content () = match content with Some bytes -> bytes | None -> invalid_arg "Patch has no replacement content" in
  (* A tree the endpoint owns is not on this host: every capability below
     would write the bookkeeping bundle and miss the tree. Those writes go
     through the remote lane. *)
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Endpoint_owned ->
    Keeper_tool_filesystem_remote_write.handle
      ~declared_root_writes:
        (declared_root_writes ~config ~meta ?continuation_channel ?gate_context
           ?gate_grant ())
      ~turn_sandbox_factory
      ~config
      ~meta
      ~args
  | Keeper_types_profile_sandbox.Shared_mount ->
  let via_field =
    match turn_sandbox_factory with
    | Some _ ->
      [ "via", `String Keeper_sandbox_runner.sandbox_backend_via ]
    | None -> []
  in
  let path = Safe_ops.json_string ~default:"" "path" args in
  (* Absent, non-string and unknown modes are all rejected; see
     [Keeper_tool_write_mode.of_args] for why there is no default. *)
  let mode_result = Keeper_tool_write_mode.of_args args in
  let after_gate ~confined ~target ~input continue =
    Option.iter (fun hook -> hook ()) (Eio.Fiber.get before_write_authorization_key);
    if confined_write_is_keeper_playground ~config ~meta confined
    then (
      Log.Keeper.info
        ~keeper_name:meta.name
        "internal playground write authorized by confined capability path=%s"
        target;
      continue ())
    else
      match
        decide_file_write
          ~config
          ~meta
          ?continuation_channel
          ?gate_context
          ?gate_grant
          ~requested_target:target
          ~input
          ()
      with
      | Keeper_gate.Deferred { approval_id; reason; audit_receipts } ->
        Ok
          (Write_deferred
             (Keeper_gate_deferred_payload.create
                ~operation:gate_operation
                ~approval_id
                ~reason
                ~audit_receipts
                ~context:(`Assoc [ "path", `String target ])
                ()))
      | Keeper_gate.Unavailable reason ->
        Ok
          (Write_failed
             { payload =
                 error_json
                   ~fields:
                     [ "path", `String target
                     ; "error", `String "gate_unavailable"
                     ; "gate_reason"
                     , `String (Keeper_gate.unavailable_reason_to_string reason)
                     ]
                   (fs_guidance_text Gate_record_unavailable)
             ; class_ = Tool_result.Dependency_unavailable
             })
      | Keeper_gate.Allow authorization ->
        Log.Keeper.info
          ~keeper_name:meta.name
          "external effect authorized operation=filesystem_write source=%s"
          (Keeper_gate.authorization_source_to_string authorization.source);
        (match continue () with
         | Ok attempt -> Ok (Write_authorized (authorization, attempt))
         | Error message ->
           Ok
             (Write_authorized
                ( authorization
                , Write_failed
                    { payload = error_json ~fields:[ "path", `String target ] message
                    ; class_ = Tool_result.Runtime_failure
                    } )))
  in
  let protect_write ~target f =
    try f () with
    | Eio.Cancel.Cancelled
        (Fs_compat.Capability_write_cancelled (reason, cancellation)) as e ->
      let interrupted_primary =
        match cancellation.interrupted_primary_failure with
        | None -> `Null
        | Some failure -> capability_write_primary_failure_json failure
      in
      let interrupted_recovery =
        match cancellation.interrupted_recovery with
        | None -> `Null
        | Some failure -> capability_recovery_failure_json failure
      in
      Log.Keeper.error
        ~keeper_name:meta.name
        "WRITE_AUDIT: filesystem publication cancelled after observable state transition path=%s operation=%s target_effect=%s interrupted_primary=%s interrupted_recovery=%s cleanup_failures=%s reason=%s"
        target
        (Fs_compat.capability_write_operation_to_string cancellation.operation)
        (Fs_compat.capability_write_target_effect_to_string
           cancellation.target_effect)
        (Yojson.Safe.to_string interrupted_primary)
        (Yojson.Safe.to_string interrupted_recovery)
        (Yojson.Safe.to_string
           (`List
               (List.map
                  capability_write_cleanup_failure_json
                  cancellation.cleanup_failures)))
        (Printexc.to_string reason);
      Option.iter
        (observe_capability_write_primary_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_primary_failure;
      Option.iter
        (observe_capability_recovery_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.interrupted_recovery;
      List.iter
        (observe_capability_write_cleanup_failure
           ~keeper_name:meta.name
           ~target)
        cancellation.cleanup_failures;
      raise e
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Eio.Io _ as e ->
      Ok
        (Write_failed
           { payload =
               error_json ~fields:[ "path", `String target ] (Printexc.to_string e)
           ; class_ = Tool_result.Runtime_failure
           })
    | Invalid_argument e | Sys_error e ->
      Ok
        (Write_failed
           { payload = error_json ~fields:[ "path", `String target ] e
           ; class_ = Tool_result.Runtime_failure
           })
    | Unix.Unix_error (err, _, _) ->
      Ok
        (Write_failed
           { payload =
               error_json
                 ~fields:[ "path", `String target ]
                 (Unix.error_message err)
           ; class_ = Tool_result.Runtime_failure
           })
  in
  let finish_content_write ~confined ~target ~mode ~gate_effect write =
    let mode_label = fs_write_mode_to_string mode in
    let input =
      file_write_gate_input
        ~effect_json:(Keeper_alerting_path.path_effect_to_yojson gate_effect)
        ~requested_target:target
        ~content_source
        ~content:(content ())
        ()
    in
    after_gate ~confined ~target ~input
    @@ fun () ->
    protect_write ~target
    @@ fun () ->
    let finish_write_result result =
      match result with
    | Error (Content_write_capability { error; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_capability_write_error ~keeper_name:meta.name ~target error;
      Ok
        (Write_failed
           { payload = capability_write_error_payload ~target ~created_parents error
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_directory { failed_commit; created_parents }) ->
      List.iter
        (observe_created_directory_commit
           ~keeper_name:meta.name
           ~target)
        created_parents;
      observe_created_directory_commit
        ~keeper_name:meta.name
        ~target
        failed_commit;
      Ok
        (Write_failed
           { payload =
               created_directory_commit_payload
                 ~target
                 ~created_parents
                 failed_commit
           ; class_ = Tool_result.Runtime_failure
           })
    | Error (Content_write_append outcome) ->
      observe_append_write_outcome
        ~keeper_name:meta.name
        ~target
        outcome;
      Ok
        (Write_failed
           { payload = append_write_outcome_payload ~target outcome
           ; class_ = Tool_result.Runtime_failure
           })
    | Ok () ->
      Log.Keeper.info
        "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=%s bytes=%d"
        meta.name
        target
        mode_label
        (String.length (content ()));
      Ok
        (Write_succeeded
           { payload =
               `Assoc
                     ([ "ok", `Bool true
                      ; "path", `String target
                      ; "mode", `String mode_label
                      ; "bytes_written", `Int (String.length (content ()))
                      ]
                      @ via_field)
           ; file_change_evidence =
               (match mode with
                | Overwrite -> Some (Keeper_file_change_evidence.written (content ()))
                | Append | Patch -> None)
           })
    in
    match write with
    | Recovery_independent operation -> finish_write_result (operation ())
    | Recovery_guarded operation ->
      (match
         Keeper_publication_recovery_availability.with_access
           publication_recovery
           operation
       with
       | Ok outcome ->
         finish_recovery_guarded_write
           ~keeper_name:meta.name
           ~target
           ~observe_result:content_write_observation
           ~finish:finish_write_result
           outcome
       | Error unavailable ->
         Ok (publication_recovery_unavailable_attempt unavailable))
  in
  let parent_effect_scope ~parent_dir ~parent_components ~missing_parents =
    Keeper_alerting_path.path_effect_parent_scope
      ~parent_components
      ~resource:(Eio.Path.stat ~follow:true parent_dir)
      ~create_missing_parents:missing_parents
      ~created_directory_permissions
    |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
  in
  let with_write_parents ~operation confined consume =
    match prepared_write with
    | Some prepared ->
        Keeper_prepared_file.Write.with_parents ~operation ~config ~meta ~args
          ~confined prepared consume
    | None -> with_confined_write_parent confined consume
  in
  let handle_atomic_content_write ~mode ~make_effect =
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Lexical_entry
        ~raw_path:path
    with
    | Error (refusal : Keeper_alerting_path.path_refusal) ->
      Keeper_tool_execution.failure ~class_:refusal.failure_class (error_json refusal.message)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_write_parents ~operation:mode confined
        @@ fun ~root_dir:_ ~parent_dir ~parent_components ~missing_parents ~leaf ->
        let* parent =
          parent_effect_scope ~parent_dir ~parent_components ~missing_parents
        in
        let* result_file_permissions =
          if missing_parents = []
          then replacement_file_permissions ~parent_dir ~leaf
          else Ok created_file_permissions
        in
        let* projection =
          make_effect ~parent ~result_file_permissions confined
          |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
        in
        let gate_effect =
          Keeper_alerting_path.publication_gate_effect projection
        in
        let recovery_target =
          Keeper_alerting_path.capability_publication_target projection
        in
        finish_content_write
          ~confined
          ~target
          ~mode
          ~gate_effect
          (Recovery_guarded
             (fun publication_recovery_access ->
                with_created_parent_directories
                  ~on_interrupted:
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                  ~permissions:created_directory_permissions
                  parent_dir
                  missing_parents
                @@ fun ~created_parents final_parent ->
                Fs_compat.replace_capability_file
                  ~recovery:publication_recovery_access
                  ~parent:final_parent
                  ~target:recovery_target
                  (content ())
                |> Result.map_error (fun error ->
                  Content_write_capability { error; created_parents })))
      in
      (match
         Keeper_external_resource_lease.with_lease
           (Keeper_external_resource_lease.File_path target)
           run
       with
       | Ok attempt -> file_write_attempt_to_execution ~config attempt
       (* An untyped string from the write: the sandbox isolation invariant,
          the parent chain, file permissions, the effect projection. It also
          carries refusals the caller could correct (a directory at the
          target, a non-regular append or patch target, a file in the parent
          path), which have no type to tell them apart yet; none reached the
          September 2026 ledger. Runtime_failure until they are typed. *)
       | Error msg ->
         Keeper_tool_execution.failure
           ~class_:Tool_result.Runtime_failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  let handle_append () =
    match
      resolve_keeper_confined_write_path
        ~config
        ~meta
        ~endpoint:Keeper_alerting_path.Follow_referent
        ~raw_path:path
    with
    | Error (refusal : Keeper_alerting_path.path_refusal) ->
      Keeper_tool_execution.failure ~class_:refusal.failure_class (error_json refusal.message)
    | Ok confined ->
      let target = Keeper_alerting_path.confined_host_path confined in
      let run () =
        let* () =
          check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
        in
        with_write_parents ~operation:Append confined
        @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf:_ ->
        let create_missing_entry () =
          let* parent =
            parent_effect_scope ~parent_dir ~parent_components ~missing_parents
          in
          let* projection =
            Keeper_alerting_path.create_entry_exclusive_effect
              ~parent
              ~result_file_permissions:created_file_permissions
              confined
            |> Result.map_error Keeper_alerting_path.path_effect_projection_error_to_string
          in
          let gate_effect = Keeper_alerting_path.publication_gate_effect projection in
          let recovery_target = Keeper_alerting_path.capability_publication_target projection in
          finish_content_write
            ~confined
            ~target
            ~mode:Append
            ~gate_effect
            (Recovery_guarded
               (fun publication_recovery_access ->
                  with_created_parent_directories
                    ~on_interrupted:
                      (observe_created_directory_commit
                         ~keeper_name:meta.name
                         ~target)
                    ~permissions:created_directory_permissions
                    parent_dir
                    missing_parents
                  @@ fun ~created_parents final_parent ->
                  Fs_compat.create_capability_file_exclusive
                    ~recovery:publication_recovery_access
                    ~parent:final_parent
                    ~target:recovery_target
                    (content ())
                  |> Result.map_error (fun error ->
                    Content_write_capability { error; created_parents })))
        in
        if missing_parents <> []
        then create_missing_entry ()
        else
          let endpoint_components =
            Keeper_alerting_path.confined_endpoint_components confined
          in
          (match split_leaf_components endpoint_components with
           | None -> Error "filesystem append endpoint has no writable leaf"
           | Some (endpoint_parent_components, endpoint_leaf) ->
             with_open_directory_components
               ~on_missing:(fun () ->
                 Error "filesystem append endpoint parent does not exist")
               root_dir
               endpoint_parent_components
             @@ fun endpoint_parent_dir ->
             Eio.Switch.run @@ fun sw ->
             (match
                Fs_compat.open_capability_append_file
                  ~sw
                  ~parent:endpoint_parent_dir
                  ~leaf:endpoint_leaf
              with
              | Error Fs_compat.Capability_append_open_missing ->
                create_missing_entry ()
              | Error
                  (( Fs_compat.Capability_append_open_invalid_leaf _
                   | Fs_compat.Capability_append_open_failed _ ) as open_error) ->
                observe_capability_append_open_error
                  ~keeper_name:meta.name
                  ~target
                  open_error;
                Ok
                  (Write_failed
                     { payload =
                         capability_append_open_error_payload
                           ~target
                           open_error
                     ; class_ = Tool_result.Runtime_failure
                     })
              | Ok file ->
                let stat = Fs_compat.capability_append_file_stat file in
                if stat.kind <> `Regular_file
                then Error "filesystem append target is not a regular file"
                else
                  let* gate_effect =
                    Keeper_alerting_path.append_pinned_resource_effect
                      confined
                      stat
                    |> Result.map_error
                         Keeper_alerting_path.path_effect_projection_error_to_string
                  in
                  finish_content_write
                    ~confined
                    ~target
                    ~mode:Append
                    ~gate_effect
                    (Recovery_independent
                       (fun () ->
                          append_capability
                            ~on_cancelled:
                              (observe_append_write_outcome
                                 ~keeper_name:meta.name
                                 ~target)
                            file
                            (content ())))))
      in
      (match
         Keeper_external_resource_lease.with_lease
           (Keeper_external_resource_lease.File_path target)
           run
       with
       | Ok attempt -> file_write_attempt_to_execution ~config attempt
       (* An untyped string from the write: the sandbox isolation invariant,
          the parent chain, file permissions, the effect projection. It also
          carries refusals the caller could correct (a directory at the
          target, a non-regular append or patch target, a file in the parent
          path), which have no type to tell them apart yet; none reached the
          September 2026 ledger. Runtime_failure until they are typed. *)
       | Error msg ->
         Keeper_tool_execution.failure
           ~class_:Tool_result.Runtime_failure
           (error_json ~fields:[ "path", `String target ] msg))
  in
  if String.trim path = ""
  then
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json (fs_guidance_text Path_required))
  else (
    match mode_result with
    | Error mode_raw ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json (Keeper_tool_write_mode.rejection_message mode_raw))
    | Ok Patch ->
      let old_string = Safe_ops.json_string ~default:"" "old_string" args in
      let new_string = Safe_ops.json_string ~default:"" "new_string" args in
      let replace_all = Safe_ops.json_bool ~default:false "replace_all" args in
      (* A patch is one of two operations on the bytes read back. The Edit
         tool sends a replace; the memo tool sends an insert above a line.
         Neither present is the Edit caller's mistake the guidance names. *)
      let insert_before_line = Safe_ops.json_int ~default:0 "insert_before_line" args in
      let insert_text = Safe_ops.json_string ~default:"" "insert_text" args in
      let operation =
        if old_string <> ""
        then Some (Keeper_tool_patch.Replace { old_string; new_string; replace_all })
        else if insert_before_line > 0
        then Some (Keeper_tool_patch.Insert_before_line { line = insert_before_line; text = insert_text })
        else None
      in
      (match operation with
       | None ->
        Keeper_tool_execution.failure
          ~class_:Tool_result.Policy_rejection
          (error_json (fs_guidance_text Patch_requires_old_string))
       | Some operation ->
        (match
           resolve_keeper_confined_write_path
             ~config
             ~meta
             ~endpoint:Keeper_alerting_path.Follow_referent
             ~raw_path:path
         with
         | Error (refusal : Keeper_alerting_path.path_refusal) ->
           Keeper_tool_execution.failure
             ~class_:refusal.failure_class
             (error_json refusal.message)
         | Ok confined ->
              let target = Keeper_alerting_path.confined_host_path confined in
              let finish_write
                    ~gate_effect
                    ~before
                    ~updated
                    ~occurrence_count
                    ~line_occurrences
                    write
                =
                let input =
                  match operation with
                  | Keeper_tool_patch.Replace { old_string; new_string; replace_all } ->
                    file_write_gate_input
                      ~effect_json:(Keeper_alerting_path.path_effect_to_yojson gate_effect)
                      ~requested_target:target
                      ~content:updated
                      ~old_string
                      ~new_string
                      ~replace_all
                      ()
                  | Keeper_tool_patch.Insert_before_line { line; text } ->
                    file_write_gate_input
                      ~effect_json:(Keeper_alerting_path.path_effect_to_yojson gate_effect)
                      ~requested_target:target
                      ~content:updated
                      ~insert_before_line:line
                      ~insert_text:text
                      ()
                in
                after_gate ~confined ~target ~input
                @@ fun () ->
                protect_write ~target
                @@ fun () ->
                let finish_write_result result =
                  match result with
                | Error (Content_write_capability { error; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_capability_write_error
                    ~keeper_name:meta.name
                    ~target
                    error;
                  Ok
                    (Write_failed
                       { payload =
                           capability_write_error_payload
                             ~target
                             ~created_parents
                             error
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error
                    (Content_write_directory { failed_commit; created_parents }) ->
                  List.iter
                    (observe_created_directory_commit
                       ~keeper_name:meta.name
                       ~target)
                    created_parents;
                  observe_created_directory_commit
                    ~keeper_name:meta.name
                    ~target
                    failed_commit;
                  Ok
                    (Write_failed
                       { payload =
                           created_directory_commit_payload
                             ~target
                             ~created_parents
                             failed_commit
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Error (Content_write_append outcome) ->
                  observe_append_write_outcome
                    ~keeper_name:meta.name
                    ~target
                    outcome;
                  Ok
                    (Write_failed
                       { payload = append_write_outcome_payload ~target outcome
                       ; class_ = Tool_result.Runtime_failure
                       })
                | Ok () ->
                  (* The file has committed. Cancellation must not turn its
                     snapshot I/O into a failed tool result for an applied edit. *)
                  Eio.Cancel.protect (fun () ->
                  Log.Keeper.info
                    "WRITE_AUDIT: keeper=%s fs_edit path=%s mode=patch op=%s replace_all=%b \
                     occurrences=%d bytes=%d"
                    meta.name
                    target
                    (Keeper_tool_patch.operation_label operation)
                    replace_all
                    occurrence_count
                    (String.length updated);
                  let operation_fields =
                    match operation with
                    | Keeper_tool_patch.Replace { replace_all; _ } ->
                      [ "replace_all", `Bool replace_all ]
                    | Keeper_tool_patch.Insert_before_line { line; text } ->
                      [ "insert_before_line", `Int line; "inserted", `String text ]
                  in
                  Ok
                    (Write_succeeded
                       { payload =
                           `Assoc
                                 ([ "ok", `Bool true
                                  ; "path", `String target
                                  ; "mode", `String "patch"
                                  ; "changed", `Bool true
                                  ; "edit_snapshots", store_edit_snapshots ~config ~before ~after:updated
                                  ]
                                  @ operation_fields
                                  @ [ "occurrences", `Int occurrence_count
                                    ; "bytes_written", `Int (String.length updated)
                                    ]
                                  @ via_field)
                       ; file_change_evidence =
                           Some
                             (match line_occurrences with
                              | Some occurrences ->
                                Keeper_file_change_evidence.edited occurrences
                              | None ->
                                Keeper_file_change_evidence.edited_ranges_omitted
                                  ~occurrence_count)
                       }))
                in
                match
                  Keeper_publication_recovery_availability.with_access
                    publication_recovery
                    (fun publication_recovery_access ->
                       write publication_recovery_access updated)
                with
                | Ok outcome ->
                  finish_recovery_guarded_write
                    ~keeper_name:meta.name
                    ~target
                    ~observe_result:content_write_observation
                    ~finish:finish_write_result
                    outcome
                | Error unavailable ->
                  Ok (publication_recovery_unavailable_attempt unavailable)
              in
              let patch_current
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    current
                    write
                =
                match Keeper_tool_patch.apply operation current with
                | Error message ->
                  Ok (Write_failed
                    { payload = error_json ~fields:[ "path", `String target ] message
                    ; class_ = Tool_result.Workflow_rejection })
                | Ok application ->
                if String.equal current application.updated then
                  Ok (Write_unchanged (`Assoc
                    ([ "ok", `Bool true; "changed", `Bool false
                     ; "path", `String target; "mode", `String "patch"
                     ; "occurrences", `Int application.occurrence_count
                     ; "replace_all", `Bool replace_all
                     ; "bytes_written", `Int 0 ] @ via_field)))
                else
                let* projection =
                  Keeper_alerting_path.patch_then_atomic_replace_effect
                    ~parent
                    ~source_resource
                    ~result_file_permissions
                    confined
                  |> Result.map_error
                       Keeper_alerting_path.path_effect_projection_error_to_string
                in
                let gate_effect =
                  Keeper_alerting_path.publication_gate_effect projection
                in
                let recovery_target =
                  Keeper_alerting_path.capability_publication_target projection
                in
                finish_write
                  ~gate_effect
                  ~before:current
                  ~updated:application.updated
                  ~occurrence_count:application.occurrence_count
                  ~line_occurrences:application.line_occurrences
                  (fun publication_recovery_access updated ->
                     write
                       ~recovery_target
                       publication_recovery_access
                       updated)
              in
              let missing_target () =
                Ok
                  (Write_failed
                     { payload =
                         error_json
                           ~fields:[ "path", `String target ]
                           (fs_guidance_text Patch_target_missing)
                     ; class_ = Tool_result.Workflow_rejection
                     })
              in
              let run () =
                let* () =
                  check_invariant_sandbox_isolation ~turn_sandbox_factory ~confined
                in
                let with_parents consume =
                  match prepared_edit with
                  | Some prepared ->
                    Keeper_prepared_file.with_parents ~operation:Edit ~config ~meta ~args ~confined prepared consume
                  | None ->
                    with_confined_write_parent confined
                    @@ fun ~root_dir ~parent_dir ~parent_components ~missing_parents ~leaf ->
                    if missing_parents <> [] then missing_target ()
                    else
                      match split_leaf_components (Keeper_alerting_path.confined_endpoint_components confined) with
                      | None -> Error "filesystem patch source has no readable leaf"
                      | Some (source_parent_components, source_leaf) ->
                        with_open_directory_components ~on_missing:missing_target root_dir source_parent_components
                        @@ fun source_parent_dir ->
                        consume ~parent_dir ~parent_components ~leaf ~source_parent_dir ~source_leaf
                in
                with_parents @@ fun ~parent_dir ~parent_components ~leaf ~source_parent_dir ~source_leaf ->
                     Eio.Switch.run @@ fun sw ->
                     (match
                        try
                          Ok
                            (Eio.Path.open_in
                               ~sw
                               Eio.Path.(source_parent_dir / source_leaf))
                        with
                        | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
                          Error `Missing
                      with
                      | Error `Missing -> missing_target ()
                      | Ok source_file ->
                        let source_resource = Eio.File.stat source_file in
                        if source_resource.kind <> `Regular_file
                        then
                          Error
                            (Fmt.str
                               "filesystem patch target must resolve to a regular file; found %a"
                               Eio.File.Stat.pp_kind
                               source_resource.kind)
                        else
                          let current = load_open_file source_file in
                          let* result_file_permissions =
                            replacement_file_permissions ~parent_dir ~leaf
                          in
                          let* parent =
                            parent_effect_scope
                              ~parent_dir
                              ~parent_components
                              ~missing_parents:[]
                          in
                          patch_current
                            ~parent
                            ~source_resource
                            ~result_file_permissions
                            current
                            (fun ~recovery_target publication_recovery_access updated ->
                               Fs_compat.replace_capability_file
                                 ~recovery:publication_recovery_access
                                 ~parent:parent_dir
                                 ~target:recovery_target
                                 updated
                               |> Result.map_error (fun error ->
                                 Content_write_capability
                                   { error; created_parents = [] })))
              in
              (match
                 Keeper_external_resource_lease.with_lease
                   (Keeper_external_resource_lease.File_path target)
                   run
               with
               | Ok attempt -> file_write_attempt_to_execution ~config attempt
               (* Untyped, as for the atomic and append writes above. *)
               | Error msg ->
                 Keeper_tool_execution.failure
                   ~class_:Tool_result.Runtime_failure
                   (error_json ~fields:[ "path", `String target ] msg))))
    | Ok Overwrite ->
      handle_atomic_content_write
        ~mode:Overwrite
        ~make_effect:Keeper_alerting_path.atomic_replace_effect
    | Ok Append -> handle_append ()
  )
;;

module For_testing = struct
  let with_before_result_manifest hook f =
    Eio.Fiber.with_binding before_result_manifest_key hook f
  ;;

  let with_before_write_authorization hook f =
    Eio.Fiber.with_binding before_write_authorization_key hook f
  ;;

  let with_before_edit_snapshot hook f =
    Eio.Fiber.with_binding before_edit_snapshot_key hook f
  ;;

  type created_directory_fault_stage =
    | Before_create_directory
    | Before_inspect_created_directory
    | Before_apply_directory_permissions

  type created_directory_fault = created_directory_dispatch_fault

  let created_directory_fault ~stage ~exception_ =
    let fault_stage =
      match stage with
      | Before_create_directory -> Create_directory
      | Before_inspect_created_directory -> Inspect_created_directory
      | Before_apply_directory_permissions -> Apply_directory_permissions
    in
    { fault_stage; fault_exception = exception_ }
  ;;

  let with_created_directory_fault fault f =
    Eio.Fiber.with_binding created_directory_dispatch_fault_key fault f
  ;;

  let slice_read_window ~start_line ~max_lines ~first_line ~max_bytes ~scan_complete
      content =
    match
      slice_read_window
        ~window:({ start_line; max_lines } : read_line_window)
        ~first_line
        ~max_bytes
        ~scan_complete
        content
    with
    | Error `Offset_beyond_scan -> Error `Offset_beyond_scan
    | Ok (slice : read_window_slice) -> Ok (slice.window_content, slice.next_offset)
  ;;
end

let prepared_edit_scopes = Keeper_prepared_file.scopes
let release_prepared_edit = Keeper_prepared_file.release

let prepared_write_scopes = Keeper_prepared_file.Write.scopes
let release_prepared_write = Keeper_prepared_file.Write.release

let prepare_write ~sw ~config ~(meta : Keeper_meta_contract.keeper_meta) ~args =
  let selected = match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile,
                       Keeper_tool_write_mode.of_args args with
    | Shared_mount, Ok Overwrite -> Some (Overwrite, Keeper_alerting_path.Lexical_entry)
    | Shared_mount, Ok Append -> Some (Append, Keeper_alerting_path.Follow_referent)
    | Endpoint_owned, _ | Shared_mount, (Ok Patch | Error _) -> None in
  match selected with
  | None -> Ok None
  | Some (operation, endpoint) ->
      let path = Safe_ops.json_string ~default:"" "path" args in
      (match resolve_keeper_confined_write_path ~config ~meta ~endpoint ~raw_path:path with
       | Error (refusal : Keeper_alerting_path.path_refusal) -> Error refusal.message
       | Ok confined -> Keeper_prepared_file.Write.prepare ~sw ~operation ~config ~meta ~args ~confined)

let edit_preparation_error_to_execution = function
  | Edit_path_refused refusal ->
    Keeper_tool_execution.failure ~class_:refusal.failure_class (error_json refusal.message)
  | Edit_resource_unavailable message ->
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure (error_json message)
;;

let prepare_edit ~sw ~config ~(meta : Keeper_meta_contract.keeper_meta) ~args =
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile,
        Keeper_tool_write_mode.of_args args with
  | Shared_mount, Ok Patch ->
    let path = Safe_ops.json_string ~default:"" "path" args in
    (match resolve_keeper_confined_write_path ~config ~meta
        ~endpoint:Keeper_alerting_path.Follow_referent ~raw_path:path with
     | Error (refusal : Keeper_alerting_path.path_refusal) ->
       Error (Edit_path_refused refusal)
     | Ok confined ->
       Keeper_prepared_file.prepare ~sw ~operation:Edit ~config ~meta ~args ~confined
       |> Result.map_error (fun message -> Edit_resource_unavailable message))
  | Endpoint_owned, _ | Shared_mount, (Ok (Overwrite | Append) | Error _) -> Ok None
;;

let handle_file_write_with_outcome ~turn_sandbox_factory ~config ~(meta : Keeper_meta_contract.keeper_meta)
    ~publication_recovery ?continuation_channel ?gate_context ?gate_grant ?prepared_edit ?prepared_write ~args () =
  let tree = Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile in
  let prepared_supported = match tree, Keeper_tool_write_mode.of_args args with
    | Shared_mount, Ok Patch -> true
    | Endpoint_owned, _ | Shared_mount, (Ok (Overwrite | Append) | Error _) -> false in
  let prepared_write_supported = match tree, Keeper_tool_write_mode.of_args args with
    | Shared_mount, Ok (Overwrite | Append) -> true
    | Endpoint_owned, _ | Shared_mount, (Ok Patch | Error _) -> false in
  if Option.is_some prepared_write
     && (Option.is_some prepared_edit || not prepared_write_supported) then
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      (error_json "prepared Write cannot execute with another resource, tree or write mode")
  else if Option.is_some prepared_edit && not prepared_supported then
    Keeper_tool_execution.failure ~class_:Tool_result.Runtime_failure
      (error_json "prepared Edit cannot execute with another tree or write mode")
  else
  match Keeper_types_profile_sandbox.tree_location_of_profile meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Endpoint_owned ->
    Keeper_tool_filesystem_remote_write.handle
      ~declared_root_writes:
        (declared_root_writes ~config ~meta ?continuation_channel ?gate_context
           ?gate_grant ())
      ~turn_sandbox_factory ~config ~meta ~args
  | Keeper_types_profile_sandbox.Shared_mount ->
  match Keeper_write_content.of_args args with
  | Error error -> Keeper_write_content.failure error
  | Ok content_source ->
    (match Keeper_write_content.bytes ~config content_source with
     | Error error -> Keeper_write_content.failure error
     | Ok content -> handle_file_write_content_with_outcome ~content_source ~content
         ~turn_sandbox_factory ~config ~meta ~publication_recovery
         ?continuation_channel ?gate_context ?gate_grant ?prepared_edit ?prepared_write ~args ())
