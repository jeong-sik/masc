type access = Read_only | Read_write

type path_rejection =
  | Outside_source
  | Non_directory_component
  | Non_regular_file
  | Identity_changed
  | Recovery_directory_not_private

type recovery_disposition =
  | Original_restored
  | Quarantine_retained
  | Original_restored_with_quarantine_retained

type cancellation_stage =
  | Quarantine_settlement
  | After_quarantine
  | After_verification
  | Snapshot_refresh

type recovery_cause =
  | Recovery_operation_failed of string
  | Recovery_cancelled of cancellation_stage

type delete_unpublished_reason =
  | Publication_failed of string
  | Publication_cancelled

type loaded =
  { reference : Skill_reference.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; source_text : string
  ; access : access
  }

type preview =
  { profile : Keeper_skill_observability.profile
  ; diagnostics : string list
  }

type save_outcome =
  | Unchanged of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Saved_and_published of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Saved_but_unpublished of
      { preview : preview
      ; reason : string
      }

type writable_source = { source_id : Skill_source_config.source_id }

type create_outcome =
  | Created_and_published of
      { preview : preview
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      }
  | Created_but_unpublished of
      { preview : preview
      ; reason : string
      }

type delete_outcome =
  | Deleted_and_published of
      { reference : Skill_reference.t
      ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
      ; recovery_id : string
      ; disposition : recovery_disposition
      }
  | Deleted_but_unpublished of
      { reference : Skill_reference.t
      ; reason : delete_unpublished_reason
      ; recovery_id : string
      ; disposition : recovery_disposition
      }

type error =
  | Invalid_workspace
  | Snapshot_not_registered
  | Snapshot_uninitialized
  | Reference_not_current
  | Source_not_ready
  | Source_file_missing
  | Source_read_failed
  | Source_path_rejected of path_rejection
  | Source_read_only
  | Confirmation_required
  | Package_already_exists
  | Invalid_package_id of string
  | Revision_conflict of { actual : Skill_reference.content_revision }
  | Delete_revision_conflict of
      { actual : Skill_reference.content_revision
      ; recovery_id : string
      ; disposition : recovery_disposition
      }
  | Source_too_large of { bytes : int; max_bytes : int }
  | Validation_failed of string
  | Write_failed of string
  | Quarantine_failed of
      { candidate_moved : bool
      ; recovery_id : string option
      ; disposition : recovery_disposition option
      ; cause : recovery_cause
      }
  | Recovery_required of
      { observed : Skill_reference.content_revision option
      ; recovery_id : string
      ; disposition : recovery_disposition
      ; cause : recovery_cause
      }

type target =
  { snapshot : Skill_catalog_snapshot.t
  ; entry : Skill_catalog_snapshot.entry
  ; source_root : string
  ; path : string
  ; access : access
  }

let ( let* ) = Result.bind

let access_to_string = function
  | Read_only -> "read_only"
  | Read_write -> "read_write"
;;

let path_rejection_to_string = function
  | Outside_source -> "outside_source"
  | Non_directory_component -> "non_directory_component"
  | Non_regular_file -> "non_regular_file"
  | Identity_changed -> "identity_changed"
  | Recovery_directory_not_private -> "recovery_directory_not_private"
;;

let recovery_disposition_to_string = function
  | Original_restored -> "original_restored"
  | Quarantine_retained -> "quarantine_retained"
  | Original_restored_with_quarantine_retained ->
    "original_restored_with_quarantine_retained"
;;

let cancellation_stage_to_string = function
  | Quarantine_settlement -> "quarantine_settlement"
  | After_quarantine -> "after_quarantine"
  | After_verification -> "after_verification"
  | Snapshot_refresh -> "snapshot_refresh"
;;

let recovery_cause_to_string = function
  | Recovery_operation_failed detail -> detail
  | Recovery_cancelled stage ->
    "cancelled:" ^ cancellation_stage_to_string stage
;;

let delete_unpublished_reason_to_string = function
  | Publication_failed reason -> reason
  | Publication_cancelled -> "snapshot refresh cancelled"
;;

let recovery_cause_to_yojson = function
  | Recovery_operation_failed detail ->
    `Assoc [ "kind", `String "operation_failed"; "detail", `String detail ]
  | Recovery_cancelled stage ->
    `Assoc
      [ "kind", `String "cancelled"
      ; "stage", `String (cancellation_stage_to_string stage)
      ]
;;

let error_code = function
  | Invalid_workspace -> "invalid_workspace"
  | Snapshot_not_registered -> "snapshot_not_registered"
  | Snapshot_uninitialized -> "snapshot_uninitialized"
  | Reference_not_current -> "reference_not_current"
  | Source_not_ready -> "source_not_ready"
  | Source_file_missing -> "source_file_missing"
  | Source_read_failed -> "source_read_failed"
  | Source_path_rejected _ -> "source_path_rejected"
  | Source_read_only -> "source_read_only"
  | Confirmation_required -> "confirmation_required"
  | Package_already_exists -> "package_already_exists"
  | Invalid_package_id _ -> "invalid_package_id"
  | Revision_conflict _ | Delete_revision_conflict _ -> "revision_conflict"
  | Source_too_large _ -> "source_too_large"
  | Validation_failed _ -> "validation_failed"
  | Write_failed _ -> "write_failed"
  | Quarantine_failed _ -> "quarantine_failed"
  | Recovery_required _ -> "recovery_required"
;;

let error_to_string = function
  | Invalid_workspace -> "Skill workspace is invalid"
  | Snapshot_not_registered -> "Skill snapshot workspace is not registered"
  | Snapshot_uninitialized -> "Skill snapshot has not been published"
  | Reference_not_current -> "Skill reference is not current"
  | Source_not_ready -> "Skill source is not ready"
  | Source_file_missing -> "SKILL.md is missing"
  | Source_read_failed -> "SKILL.md could not be read safely"
  | Source_path_rejected rejection ->
    "Skill path was rejected: " ^ path_rejection_to_string rejection
  | Source_read_only -> "Skill source is read-only"
  | Confirmation_required -> "Skill deletion requires explicit confirmation"
  | Package_already_exists -> "Skill package already exists"
  | Invalid_package_id detail -> "Invalid Skill package id: " ^ detail
  | Revision_conflict { actual } ->
    "SKILL.md changed after this editor loaded it; current revision is "
    ^ Skill_reference.content_revision_to_string actual
  | Delete_revision_conflict { actual; recovery_id; disposition } ->
    Printf.sprintf
      "SKILL.md changed before quarantine; current revision is %s; recovery_id=%s; \
       disposition=%s"
      (Skill_reference.content_revision_to_string actual)
      recovery_id
      (recovery_disposition_to_string disposition)
  | Source_too_large { bytes; max_bytes } ->
    Printf.sprintf "SKILL.md is too large: %d bytes (maximum %d)" bytes max_bytes
  | Validation_failed detail -> "Skill validation failed: " ^ detail
  | Write_failed detail -> "Skill durable write failed: " ^ detail
  | Quarantine_failed { candidate_moved; recovery_id; disposition = _; cause } ->
    Printf.sprintf
      "Skill quarantine failed after candidate move=%b%s; cause=%s"
      candidate_moved
      (match recovery_id with
       | None -> ""
       | Some recovery_id -> "; recovery_id=" ^ recovery_id)
      (recovery_cause_to_string cause)
  | Recovery_required { recovery_id; disposition; observed = _; cause } ->
    Printf.sprintf
      "Skill deletion stopped with preserved recovery data; recovery_id=%s; \
       disposition=%s; cause=%s"
      recovery_id
      (recovery_disposition_to_string disposition)
      (recovery_cause_to_string cause)
;;

let error_recovery = function
  | Delete_revision_conflict { recovery_id; disposition; _ }
  | Recovery_required { recovery_id; disposition; _ } ->
    Some (recovery_id, disposition)
  | Quarantine_failed
      { candidate_moved = true
      ; recovery_id = Some recovery_id
      ; disposition = Some disposition
      ; _
      } ->
    Some (recovery_id, disposition)
  | Invalid_workspace | Snapshot_not_registered | Snapshot_uninitialized
  | Reference_not_current | Source_not_ready | Source_file_missing
  | Source_read_failed | Source_path_rejected _ | Source_read_only
  | Confirmation_required | Package_already_exists | Invalid_package_id _
  | Revision_conflict _ | Source_too_large _ | Validation_failed _
  | Write_failed _ | Quarantine_failed _ ->
    None
;;

let current_snapshot ~base_path =
  match Server_skill_snapshot_runtime.lookup ~base_path with
  | Error _ -> Error Invalid_workspace
  | Ok Not_registered -> Error Snapshot_not_registered
  | Ok Uninitialized -> Error Snapshot_uninitialized
  | Ok (Ready snapshot) -> Ok snapshot
;;

let resolve_target ~base_path reference =
  let* snapshot = current_snapshot ~base_path in
  let* entry =
    match Skill_catalog_snapshot.resolve_reference snapshot reference with
    | Ok entry -> Ok entry
    | Error (Skill_catalog_snapshot.Identity_not_found _) ->
      Error Reference_not_current
    | Error (Content_revision_mismatch { observed; _ }) ->
      Error (Revision_conflict { actual = observed })
  in
  let* source_scan =
    match List.nth_opt (Skill_catalog_snapshot.sources snapshot) entry.source_index with
    | Some source -> Ok source
    | None -> Error Source_not_ready
  in
  let* source_root =
    match source_scan.observation with
    | Skill_catalog_snapshot.Source_ready { resolved_path; _ } -> Ok resolved_path
    | Source_missing _
    | Source_not_directory _
    | Source_unavailable _
    | Source_unresolved _ ->
      Error Source_not_ready
  in
  let access =
    match source_scan.source.source.access with
    | Skill_source_config.Read_only -> Read_only
    | Read_write -> Read_write
  in
  let path =
    Filename.concat source_root (Filename.concat entry.directory "SKILL.md")
  in
  Ok { snapshot; entry; source_root; path; access }
;;

let read_current target =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:target.source_root
      target.path
  with
  | Error { Fs_compat.failure; _ } ->
    (match failure with
     | Ownership_boundary_rejected { rejection; _ } ->
       (match rejection with
        | Fs_compat.Owned_path_outside_root _ ->
          Error (Source_path_rejected Outside_source)
        | Owned_path_non_directory _ ->
          Error (Source_path_rejected Non_directory_component))
     | Path_is_not_regular_file _ ->
       Error (Source_path_rejected Non_regular_file)
     | Filesystem_identity_changed _ ->
       Error (Source_path_rejected Identity_changed)
     | Owned_file_operation_failed _ -> Error Source_read_failed)
  | Ok None -> Error Source_file_missing
  | Ok (Some source_text) ->
    let actual = Skill_reference.content_revision_of_source_text source_text in
    Ok (source_text, actual)
;;

let require_expected_revision reference actual =
  if Skill_reference.equal_content_revision reference.Skill_reference.content_revision actual
  then Ok ()
  else Error (Revision_conflict { actual })
;;

let max_source_bytes = 1_048_576

let validate_candidate target reference source_text =
  if String.length source_text > max_source_bytes
  then
    Error
      (Source_too_large
         { bytes = String.length source_text; max_bytes = max_source_bytes })
  else
  match Keeper_skill_catalog.parse_skill ~directory:target.entry.directory source_text with
  | Error error -> Error (Validation_failed (Keeper_skill_catalog.error_to_string error))
  | Ok skill ->
    let candidate_reference =
      Skill_reference.make
        ~identity:reference.Skill_reference.identity
        ~content_revision:(Skill_reference.content_revision_of_source_text source_text)
    in
    Ok
      { profile =
          Keeper_skill_observability.of_skill_with_reference candidate_reference skill
      ; diagnostics = []
      }
;;

let load ~base_path reference =
  let* target = resolve_target ~base_path reference in
  let* source_text, actual = read_current target in
  let* () = require_expected_revision reference actual in
  Ok
    { reference
    ; snapshot_revision = Skill_catalog_snapshot.snapshot_revision target.snapshot
    ; source_text
    ; access = target.access
    }
;;

let preview ~base_path reference ~source_text =
  let* target = resolve_target ~base_path reference in
  let* _, actual = read_current target in
  let* () = require_expected_revision reference actual in
  validate_candidate target reference source_text
;;

let with_path_lock path f =
  let lock = Keeper_fs.acquire_path_lock path in
  Fun.protect
    ~finally:(fun () -> Keeper_fs.release_path_lock path lock)
    (fun () -> Eio.Mutex.use_rw ~protect:true (Keeper_fs.path_lock_mutex lock) f)
;;

let published_snapshot = function
  | Skill_catalog_snapshot_service.Published snapshot
  | Unchanged snapshot -> Ok snapshot
  | Workspace_retired -> Error "workspace retired during Skill publication"
;;

let save ~base_path ~reference ~source_text ~refresh =
  let* initial_target = resolve_target ~base_path reference in
  if initial_target.access = Read_only
  then Error Source_read_only
  else
    with_path_lock initial_target.path (fun () ->
      let* target = resolve_target ~base_path reference in
      if target.access = Read_only
      then Error Source_read_only
      else
        let* current_source, actual = read_current target in
        let* () = require_expected_revision reference actual in
        let* preview = validate_candidate target reference source_text in
        if String.equal current_source source_text
        then
          Ok
            (Unchanged
               { preview
               ; snapshot_revision = Skill_catalog_snapshot.snapshot_revision target.snapshot
               })
        else
          match
            Keeper_fs.save_bytes_durable_atomic
              ~ownership_root:target.source_root
              target.path
              source_text
          with
          | Error error ->
            Error (Write_failed (Keeper_fs.durable_write_error_to_string error))
          | Ok () ->
            (match refresh () with
             | Error reason -> Ok (Saved_but_unpublished { preview; reason })
             | Ok publication ->
               (match published_snapshot publication with
                | Error reason -> Ok (Saved_but_unpublished { preview; reason })
                | Ok snapshot ->
                  (match
                     Skill_catalog_snapshot.resolve_reference
                       snapshot
                       preview.profile.reference
                   with
                   | Error _ ->
                     Ok
                       (Saved_but_unpublished
                          { preview
                          ; reason = "candidate revision was not present after publication"
                          })
                   | Ok _ ->
                     Ok
                       (Saved_and_published
                          { preview
                          ; snapshot_revision =
                              Skill_catalog_snapshot.snapshot_revision snapshot
                          })))))
;;

let ready_source_root source_scan =
  match source_scan.Skill_catalog_snapshot.observation with
  | Skill_catalog_snapshot.Source_ready { resolved_path; _ } -> Ok resolved_path
  | Source_missing _
  | Source_not_directory _
  | Source_unavailable _
  | Source_unresolved _ ->
    Error Source_not_ready
;;

let writable_sources ~base_path =
  let* snapshot = current_snapshot ~base_path in
  Ok
    (snapshot
     |> Skill_catalog_snapshot.sources
     |> List.filter_map (fun (source_scan : Skill_catalog_snapshot.source_scan) ->
       match source_scan.source.source.access, ready_source_root source_scan with
       | Skill_source_config.Read_write, Ok _ ->
         Some { source_id = source_scan.source.source.id }
       | Read_only, _ | _, Error _ -> None))
;;

let find_writable_source snapshot source_id =
  let source_id_text = Skill_source_config.source_id_to_string source_id in
  snapshot
  |> Skill_catalog_snapshot.sources
  |> List.find_opt (fun (source_scan : Skill_catalog_snapshot.source_scan) ->
    String.equal
      (Skill_source_config.source_id_to_string source_scan.source.source.id)
      source_id_text)
  |> function
  | None -> Error Source_not_ready
  | Some source_scan ->
    (match source_scan.source.source.access with
     | Skill_source_config.Read_only -> Error Source_read_only
     | Read_write ->
       let* source_root = ready_source_root source_scan in
       Ok source_root)
;;

let package_id_error_to_string = function
  | Skill_reference.Empty_package_id -> "must not be empty"
  | Current_directory_package_id -> "must not be ."
  | Parent_directory_package_id -> "must not be .."
  | Package_id_contains_separator -> "must be one directory name"
  | Package_id_contains_nul -> "must not contain NUL"
;;

let preview_new ~source_id ~package_id source_text =
  if String.length source_text > max_source_bytes
  then
    Error
      (Source_too_large
         { bytes = String.length source_text; max_bytes = max_source_bytes })
  else
    let* parsed_package_id =
      Skill_reference.package_id_of_directory package_id
      |> Result.map_error (fun error ->
        Invalid_package_id (package_id_error_to_string error))
    in
    match Keeper_skill_catalog.parse_skill ~directory:package_id source_text with
    | Error error -> Error (Validation_failed (Keeper_skill_catalog.error_to_string error))
    | Ok skill ->
      let identity =
        Skill_reference.make_identity
          ~source_id
          ~package_id:parsed_package_id
          ~name:skill.name
      in
      let reference =
        Skill_reference.make
          ~identity
          ~content_revision:(Skill_reference.content_revision_of_source_text source_text)
      in
      Ok
        { profile = Keeper_skill_observability.of_skill_with_reference reference skill
        ; diagnostics = []
        }
;;

let create ~base_path ~source_id ~package_id ~source_text ~refresh =
  let* snapshot = current_snapshot ~base_path in
  let* source_root = find_writable_source snapshot source_id in
  let* preview = preview_new ~source_id ~package_id source_text in
  let package_dir = Filename.concat source_root package_id in
  let path = Filename.concat package_dir "SKILL.md" in
  with_path_lock path (fun () ->
    let* latest = current_snapshot ~base_path in
    let* latest_root = find_writable_source latest source_id in
    if not (String.equal source_root latest_root)
    then Error Source_not_ready
    else
      let* () =
        (* fsync_directory is a blocking primitive whose contract is
           "call only from a system-thread boundary"; inline it here and
           the HTTP handler's fiber stalls the whole event loop for the
           fsync. Same envelope as keeper_fs: run the mkdir+fsync pair in
           a systhread, re-check cancellation after, and never fold
           Cancelled into a write failure. *)
        try
          Eio_guard.run_in_systhread ~label:"skill-editor-create-package-dir" (fun () ->
            Unix.mkdir package_dir 0o755;
            Keeper_fs_durable_directory.fsync_directory source_root);
          Eio_guard.check_if_ready ();
          Ok ()
        with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> Error Package_already_exists
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Write_failed (Printexc.to_string exn))
      in
      match
        Keeper_fs.save_bytes_durable_atomic
          ~ownership_root:source_root
          path
          source_text
      with
      | Error error ->
        let base_detail = Keeper_fs.durable_write_error_to_string error in
        (* A failed rollback is part of the answer: the leftover empty
           directory makes every retry report Package_already_exists, so
           the operator has to know it is there. *)
        let detail =
          try
            Eio_guard.run_in_systhread ~label:"skill-editor-remove-package-dir" (fun () -> Unix.rmdir package_dir);
            Eio_guard.check_if_ready ();
            base_detail
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | rollback_exn ->
            Printf.sprintf
              "%s; rollback left %s in place (%s), so retries will report \
               a package conflict until it is removed"
              base_detail
              package_dir
              (Printexc.to_string rollback_exn)
        in
        Error (Write_failed detail)
      | Ok () ->
        (match refresh () with
         | Error reason -> Ok (Created_but_unpublished { preview; reason })
         | Ok publication ->
           (match published_snapshot publication with
            | Error reason -> Ok (Created_but_unpublished { preview; reason })
            | Ok published ->
              (match
                 Skill_catalog_snapshot.resolve_reference
                   published
                   preview.profile.reference
               with
               | Ok _ ->
                 Ok
                   (Created_and_published
                      { preview
                      ; snapshot_revision =
                          Skill_catalog_snapshot.snapshot_revision published
                      })
               | Error _ ->
                 Ok
                   (Created_but_unpublished
                      { preview
                      ; reason = "candidate revision was not present after publication"
                      })))))
;;

type quarantine =
  { recovery_id : string
  ; recovery_root : string
  ; directory : string
  ; path : string
  }

type restore_result =
  | Restored
  | Restore_recovery_required of recovery_disposition * recovery_cause

let recovery_root_name = ".masc-skill-delete-recovery"

let path_rejection_of_owned_directory = function
  | Fs_compat.Owned_path_outside_root _ -> Outside_source
  | Owned_path_non_directory _ -> Non_directory_component
;;

let run_quarantine_io operation =
  try
    let result = Eio_guard.run_in_systhread ~label:"skill-editor-operation" operation in
    Eio_guard.check_if_ready ();
    Ok result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let inspect_private_recovery_root ~source_root recovery_root =
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:source_root recovery_root with
  | Error rejection ->
    Error (Source_path_rejected (path_rejection_of_owned_directory rejection))
  | Ok Fs_compat.Owned_directory_missing -> Error Source_not_ready
  | Ok (Owned_directory stat) ->
    if stat.Unix.st_uid = Unix.geteuid () && stat.st_perm land 0o077 = 0
    then Ok recovery_root
    else Error (Source_path_rejected Recovery_directory_not_private)
;;

let ensure_private_recovery_root source_root =
  let recovery_root = Filename.concat source_root recovery_root_name in
  match run_quarantine_io (fun () ->
    match
      Fs_compat.inspect_owned_directory_chain ~ownership_root:source_root recovery_root
    with
    | Ok Fs_compat.Owned_directory_missing ->
      (try Unix.mkdir recovery_root 0o700 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      Keeper_fs_durable_directory.fsync_directory source_root
    | Ok (Owned_directory _) -> ()
    | Error rejection ->
      raise (Invalid_argument (Fs_compat.owned_directory_chain_rejection_to_string rejection)))
  with
  | Error detail ->
    Error
      (Quarantine_failed
         { candidate_moved = false
         ; recovery_id = None
         ; disposition = None
         ; cause = Recovery_operation_failed detail
         })
  | Ok () -> inspect_private_recovery_root ~source_root recovery_root
;;

let create_quarantine source_root =
  let* recovery_root = ensure_private_recovery_root source_root in
  let rec create () =
    let recovery_id = Random_id.prefixed ~prefix:"skill-delete-" ~bytes:16 in
    let directory = Filename.concat recovery_root recovery_id in
    let creation =
      try
        Eio_guard.run_in_systhread ~label:"skill-editor-create-dir" (fun () -> Unix.mkdir directory 0o700);
        Eio_guard.check_if_ready ();
        `Created
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> `Collision
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> `Failed (Printexc.to_string exn)
    in
    match creation with
    | `Collision -> create ()
    | `Failed detail ->
      Error
        (Quarantine_failed
           { candidate_moved = false
           ; recovery_id = Some recovery_id
           ; disposition = None
           ; cause = Recovery_operation_failed detail
           })
    | `Created ->
      (match run_quarantine_io (fun () ->
         Keeper_fs_durable_directory.fsync_directory recovery_root)
    with
    | Ok () ->
      Ok
        { recovery_id
        ; recovery_root
        ; directory
        ; path = Filename.concat directory "SKILL.md"
        }
      | Error detail ->
        Error
          (Quarantine_failed
             { candidate_moved = false
             ; recovery_id = Some recovery_id
             ; disposition = None
             ; cause = Recovery_operation_failed detail
             }))
  in
  create ()
;;

let cleanup_empty_quarantine quarantine =
  match run_quarantine_io (fun () ->
    Unix.rmdir quarantine.directory;
    Keeper_fs_durable_directory.fsync_directory quarantine.recovery_root)
  with
  | Ok () -> ()
  | Error detail ->
    Log.Dashboard.warn
      "Skill delete empty recovery cleanup failed recovery_id=%s error=%s"
      quarantine.recovery_id
      detail
;;

let quarantine_candidate ~before_quarantine ~after_move (target : target) =
  let* quarantine = create_quarantine target.source_root in
  let hook_result =
    try before_quarantine (); Ok () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  match hook_result with
  | Error detail ->
    cleanup_empty_quarantine quarantine;
    Error
      (Quarantine_failed
         { candidate_moved = false
         ; recovery_id = Some quarantine.recovery_id
         ; disposition = None
         ; cause = Recovery_operation_failed detail
         })
  | Ok () ->
    let moved = ref false in
    let move_result =
      try
        Eio.Cancel.protect (fun () ->
          Eio_guard.run_in_systhread ~label:"skill-editor-quarantine-rename" (fun () ->
            Unix.rename target.path quarantine.path;
            moved := true;
            after_move ();
            Keeper_fs_durable_directory.fsync_directory
              (Filename.dirname target.path);
            Keeper_fs_durable_directory.fsync_directory quarantine.directory);
          Eio_guard.check_if_ready ());
        `Moved
      with
      | Eio.Cancel.Cancelled _ as exn -> `Cancelled exn
      | exn -> `Failed (Printexc.to_string exn)
    in
    (match move_result with
     | `Moved -> Ok quarantine
     | `Cancelled exn when not !moved -> raise exn
     | `Cancelled _ ->
       Error
         (Quarantine_failed
            { candidate_moved = true
            ; recovery_id = Some quarantine.recovery_id
            ; disposition = Some Quarantine_retained
            ; cause = Recovery_cancelled Quarantine_settlement
            })
     | `Failed detail ->
       if not !moved then cleanup_empty_quarantine quarantine;
       Error
         (Quarantine_failed
            { candidate_moved = !moved
            ; recovery_id = Some quarantine.recovery_id
            ; disposition = if !moved then Some Quarantine_retained else None
            ; cause = Recovery_operation_failed detail
            }))
;;

let restore_quarantined_candidate (target : target) (quarantine : quarantine) =
  let linked = ref false in
  let retained_disposition () =
    if !linked
    then Original_restored_with_quarantine_retained
    else Quarantine_retained
  in
  try
    match run_quarantine_io (fun () ->
      Unix.link quarantine.path target.path;
      linked := true;
      Keeper_fs_durable_directory.fsync_directory (Filename.dirname target.path))
    with
    | Error detail ->
      Restore_recovery_required
        (retained_disposition (), Recovery_operation_failed detail)
    | Ok () ->
      (match
         Keeper_fs.remove_file_durable
           ~ownership_root:target.source_root
           quarantine.path
       with
       | Ok () ->
         cleanup_empty_quarantine quarantine;
         Restored
       | Error error ->
         let disposition =
           if error.removed
           then Original_restored
           else Original_restored_with_quarantine_retained
         in
         Restore_recovery_required
           ( disposition
           , Recovery_operation_failed
               (Keeper_fs.durable_remove_error_to_string error) ))
  with
  | Eio.Cancel.Cancelled _ ->
    Restore_recovery_required
      (retained_disposition (), Recovery_cancelled After_quarantine)
;;

let protect_quarantined_candidate quarantine operation =
  try Eio.Cancel.protect operation with
  | Eio.Cancel.Cancelled _ ->
    Error
      (Recovery_required
         { observed = None
         ; recovery_id = quarantine.recovery_id
         ; disposition = Quarantine_retained
         ; cause = Recovery_cancelled After_quarantine
         })
;;

let delete_with
      ~before_quarantine
      ~after_move
      ~after_quarantine
      ~after_verification
      ~base_path
      ~reference
      ~confirmed
      ~refresh
  =
  if not confirmed
  then Error Confirmation_required
  else
    let* initial_target = resolve_target ~base_path reference in
    if initial_target.access = Read_only
    then Error Source_read_only
    else
      with_path_lock initial_target.path (fun () ->
        let* target = resolve_target ~base_path reference in
        if target.access = Read_only
        then Error Source_read_only
        else
          let* _, actual = read_current target in
          let* () = require_expected_revision reference actual in
          let* quarantine =
            quarantine_candidate ~before_quarantine ~after_move target
          in
          protect_quarantined_candidate quarantine (fun () ->
          let after_quarantine_result =
            try after_quarantine (); Ok () with
            | Eio.Cancel.Cancelled _ ->
              Error (Recovery_cancelled After_quarantine)
            | exn -> Error (Recovery_operation_failed (Printexc.to_string exn))
          in
          (match after_quarantine_result with
           | Error cause ->
             Error
               (Recovery_required
                  { observed = None
                  ; recovery_id = quarantine.recovery_id
                  ; disposition = Quarantine_retained
                  ; cause
                  })
           | Ok () ->
             (match
                Fs_compat.load_owned_regular_file
                  ~ownership_root:target.source_root
                  quarantine.path
              with
           | Error error ->
             Error
               (Recovery_required
                  { observed = None
                  ; recovery_id = quarantine.recovery_id
                  ; disposition = Quarantine_retained
                  ; cause =
                      Recovery_operation_failed
                        (Fs_compat.owned_regular_file_read_error_to_string error)
                  })
           | Ok None ->
             Error
               (Recovery_required
                  { observed = None
                  ; recovery_id = quarantine.recovery_id
                  ; disposition = Quarantine_retained
                  ; cause =
                      Recovery_operation_failed
                        "quarantined candidate disappeared before verification"
                  })
           | Ok (Some quarantined_source) ->
             let observed =
               Skill_reference.content_revision_of_source_text quarantined_source
             in
             if not (Skill_reference.equal_content_revision reference.content_revision observed)
             then
               (match restore_quarantined_candidate target quarantine with
                | Restored ->
                  Error
                    (Delete_revision_conflict
                       { actual = observed
                       ; recovery_id = quarantine.recovery_id
                       ; disposition = Original_restored
                       })
                | Restore_recovery_required (disposition, cause) ->
                  Error
                    (Recovery_required
                       { observed = Some observed
                       ; recovery_id = quarantine.recovery_id
                       ; disposition
                       ; cause
                       }))
             else
               let after_verification_result =
                 try after_verification (); Ok () with
                 | Eio.Cancel.Cancelled _ ->
                   Error (Recovery_cancelled After_verification)
                 | exn ->
                   Error (Recovery_operation_failed (Printexc.to_string exn))
               in
               (match after_verification_result with
                | Error cause ->
                  Error
                    (Recovery_required
                       { observed = Some observed
                       ; recovery_id = quarantine.recovery_id
                       ; disposition = Quarantine_retained
                       ; cause
                       })
                | Ok () ->
                  let refresh_result =
                    try `Returned (refresh ()) with
                    | Eio.Cancel.Cancelled _ -> `Cancelled
                  in
                  (match refresh_result with
                   | `Cancelled ->
                     Ok
                       (Deleted_but_unpublished
                          { reference
                          ; reason = Publication_cancelled
                          ; recovery_id = quarantine.recovery_id
                          ; disposition = Quarantine_retained
                          })
                   | `Returned (Error reason) ->
                     Ok
                       (Deleted_but_unpublished
                          { reference
                          ; reason = Publication_failed reason
                          ; recovery_id = quarantine.recovery_id
                          ; disposition = Quarantine_retained
                          })
                   | `Returned (Ok publication) ->
                     (match published_snapshot publication with
                      | Error reason ->
                        Ok
                          (Deleted_but_unpublished
                             { reference
                             ; reason = Publication_failed reason
                             ; recovery_id = quarantine.recovery_id
                             ; disposition = Quarantine_retained
                             })
                      | Ok snapshot ->
                        (match
                           Skill_catalog_snapshot.resolve_reference snapshot reference
                         with
                         | Error _ ->
                           Ok
                             (Deleted_and_published
                                { reference
                                ; snapshot_revision =
                                    Skill_catalog_snapshot.snapshot_revision snapshot
                                ; recovery_id = quarantine.recovery_id
                                ; disposition = Quarantine_retained
                                })
                         | Ok _ ->
                           Ok
                             (Deleted_but_unpublished
                                { reference
                                ; reason =
                                    Publication_failed
                                      "deleted reference remained present after publication"
                                ; recovery_id = quarantine.recovery_id
                                ; disposition = Quarantine_retained
                                })))))))))
;;

let delete ~base_path ~reference ~confirmed ~refresh =
  delete_with
    ~before_quarantine:(fun () -> ())
    ~after_move:(fun () -> ())
    ~after_quarantine:(fun () -> ())
    ~after_verification:(fun () -> ())
    ~base_path
    ~reference
    ~confirmed
    ~refresh
;;

module For_testing = struct
  let recovery_file_path ~source_root ~recovery_id =
    Filename.concat
      source_root
      (Filename.concat recovery_root_name (Filename.concat recovery_id "SKILL.md"))
  ;;

  let delete
        ~before_quarantine
        ~after_move
        ~after_quarantine
        ~after_verification
        ~base_path
        ~reference
        ~confirmed
        ~refresh
    =
    delete_with
      ~before_quarantine
      ~after_move
      ~after_quarantine
      ~after_verification
      ~base_path
      ~reference
      ~confirmed
      ~refresh
  ;;
end

let preview_to_yojson (preview : preview) =
  `Assoc
    [ "profile", Keeper_skill_observability.to_yojson preview.profile
    ; "diagnostics", `List (List.map (fun value -> `String value) preview.diagnostics)
    ]
;;

let loaded_to_yojson (loaded : loaded) =
  `Assoc
    [ "status", `String "ready"
    ; "reference", Skill_reference.to_yojson loaded.reference
    ; ( "snapshot_revision"
      , `String
          (Skill_catalog_snapshot.snapshot_revision_to_string loaded.snapshot_revision) )
    ; "source_text", `String loaded.source_text
    ; "access", `String (access_to_string loaded.access)
    ]
;;

let save_outcome_to_yojson = function
  | Unchanged { preview; snapshot_revision } ->
    `Assoc
      [ "status", `String "unchanged"
      ; "preview", preview_to_yojson preview
      ; ( "snapshot_revision"
        , `String (Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision) )
      ]
  | Saved_and_published { preview; snapshot_revision } ->
    `Assoc
      [ "status", `String "saved_and_published"
      ; "preview", preview_to_yojson preview
      ; ( "snapshot_revision"
        , `String (Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision) )
      ]
  | Saved_but_unpublished { preview; reason } ->
    `Assoc
      [ "status", `String "saved_but_unpublished"
      ; "preview", preview_to_yojson preview
      ; "reason", `String reason
      ]
;;

let writable_source_to_yojson source =
  `Assoc
    [ "source_id", `String (Skill_source_config.source_id_to_string source.source_id) ]
;;

let create_outcome_to_yojson = function
  | Created_and_published { preview; snapshot_revision } ->
    `Assoc
      [ "status", `String "created_and_published"
      ; "preview", preview_to_yojson preview
      ; ( "snapshot_revision"
        , `String (Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision) )
      ]
  | Created_but_unpublished { preview; reason } ->
    `Assoc
      [ "status", `String "created_but_unpublished"
      ; "preview", preview_to_yojson preview
      ; "reason", `String reason
      ]
;;

let delete_outcome_to_yojson = function
  | Deleted_and_published
      { reference; snapshot_revision; recovery_id; disposition } ->
    `Assoc
      [ "status", `String "deleted_and_published"
      ; "reference", Skill_reference.to_yojson reference
      ; ( "snapshot_revision"
        , `String (Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision) )
      ; "recovery_id", `String recovery_id
      ; ( "recovery_disposition"
        , `String (recovery_disposition_to_string disposition) )
      ]
  | Deleted_but_unpublished { reference; reason; recovery_id; disposition } ->
    `Assoc
      [ "status", `String "deleted_but_unpublished"
      ; "reference", Skill_reference.to_yojson reference
      ; "reason", `String (delete_unpublished_reason_to_string reason)
      ; "recovery_id", `String recovery_id
      ; ( "recovery_disposition"
        , `String (recovery_disposition_to_string disposition) )
      ]
;;

let error_to_yojson error =
  `Assoc
    ([ "ok", `Bool false
     ; "code", `String (error_code error)
     ; "error", `String (error_to_string error)
     ]
     @ match error with
       | Revision_conflict { actual } ->
         [ ( "actual_revision"
           , `String (Skill_reference.content_revision_to_string actual) )
         ]
       | Delete_revision_conflict { actual; recovery_id; disposition } ->
         [ ( "actual_revision"
           , `String (Skill_reference.content_revision_to_string actual) )
         ; "recovery_id", `String recovery_id
         ; ( "recovery_disposition"
           , `String (recovery_disposition_to_string disposition) )
         ]
       | Source_path_rejected rejection ->
         [ "path_rejection", `String (path_rejection_to_string rejection) ]
       | Quarantine_failed
           { candidate_moved; recovery_id; disposition; cause } ->
         [ "candidate_moved", `Bool candidate_moved
         ; ( "recovery_id"
           , match recovery_id with
             | None -> `Null
             | Some recovery_id -> `String recovery_id )
         ; ( "recovery_disposition"
           , match disposition with
             | None -> `Null
             | Some disposition ->
               `String (recovery_disposition_to_string disposition) )
         ; "cause", recovery_cause_to_yojson cause
         ]
       | Recovery_required { observed; recovery_id; disposition; cause } ->
         [ ( "actual_revision"
           , match observed with
             | None -> `Null
             | Some observed ->
               `String (Skill_reference.content_revision_to_string observed) )
         ; "recovery_id", `String recovery_id
         ; ( "recovery_disposition"
           , `String (recovery_disposition_to_string disposition) )
         ; "cause", recovery_cause_to_yojson cause
         ]
       | Invalid_workspace | Snapshot_not_registered | Snapshot_uninitialized
       | Reference_not_current | Source_not_ready | Source_file_missing
       | Source_read_failed | Source_read_only
       | Confirmation_required | Package_already_exists | Invalid_package_id _
       | Source_too_large _ | Validation_failed _ | Write_failed _ ->
         [])
;;
