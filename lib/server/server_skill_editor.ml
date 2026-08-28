type access = Read_only | Read_write

type loaded =
  { reference : Skill_reference.t
  ; snapshot_revision : Skill_catalog_snapshot.snapshot_revision
  ; source_text : string
  ; access : access
  }

type preview =
  { reference : Skill_reference.t
  ; profile : Keeper_skill_observability.profile
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

type error =
  | Invalid_workspace
  | Snapshot_not_registered
  | Snapshot_uninitialized
  | Reference_not_current
  | Source_not_ready
  | Source_file_missing
  | Source_read_failed
  | Source_read_only
  | Package_already_exists
  | Invalid_package_id of string
  | Revision_conflict of { actual : Skill_reference.content_revision }
  | Source_too_large of { bytes : int; max_bytes : int }
  | Validation_failed of string
  | Write_failed of string

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

let error_code = function
  | Invalid_workspace -> "invalid_workspace"
  | Snapshot_not_registered -> "snapshot_not_registered"
  | Snapshot_uninitialized -> "snapshot_uninitialized"
  | Reference_not_current -> "reference_not_current"
  | Source_not_ready -> "source_not_ready"
  | Source_file_missing -> "source_file_missing"
  | Source_read_failed -> "source_read_failed"
  | Source_read_only -> "source_read_only"
  | Package_already_exists -> "package_already_exists"
  | Invalid_package_id _ -> "invalid_package_id"
  | Revision_conflict _ -> "revision_conflict"
  | Source_too_large _ -> "source_too_large"
  | Validation_failed _ -> "validation_failed"
  | Write_failed _ -> "write_failed"
;;

let error_to_string = function
  | Invalid_workspace -> "Skill workspace is invalid"
  | Snapshot_not_registered -> "Skill snapshot workspace is not registered"
  | Snapshot_uninitialized -> "Skill snapshot has not been published"
  | Reference_not_current -> "Skill reference is not current"
  | Source_not_ready -> "Skill source is not ready"
  | Source_file_missing -> "SKILL.md is missing"
  | Source_read_failed -> "SKILL.md could not be read safely"
  | Source_read_only -> "Skill source is read-only"
  | Package_already_exists -> "Skill package already exists"
  | Invalid_package_id detail -> "Invalid Skill package id: " ^ detail
  | Revision_conflict { actual } ->
    "SKILL.md changed after this editor loaded it; current revision is "
    ^ Skill_reference.content_revision_to_string actual
  | Source_too_large { bytes; max_bytes } ->
    Printf.sprintf "SKILL.md is too large: %d bytes (maximum %d)" bytes max_bytes
  | Validation_failed detail -> "Skill validation failed: " ^ detail
  | Write_failed detail -> "Skill durable write failed: " ^ detail
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
    | Error _ -> Error Reference_not_current
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
  | Error _ -> Error Source_read_failed
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

let diagnostics_of_conformance = function
  | Agent_core.Skill_document.Conformant -> []
  | Runtime_compatible diagnostics ->
    List.map Agent_core.Skill_document.diagnostic_to_string diagnostics
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
      { reference = candidate_reference
      ; profile =
          Keeper_skill_observability.of_skill_with_reference candidate_reference skill
      ; diagnostics = diagnostics_of_conformance skill.conformance
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
                     Skill_catalog_snapshot.resolve_reference snapshot preview.reference
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
        { reference
        ; profile = Keeper_skill_observability.of_skill_with_reference reference skill
        ; diagnostics = diagnostics_of_conformance skill.conformance
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
          Eio_guard.run_in_systhread (fun () ->
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
            Eio_guard.run_in_systhread (fun () -> Unix.rmdir package_dir);
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
              (match Skill_catalog_snapshot.resolve_reference published preview.reference with
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

let preview_to_yojson (preview : preview) =
  `Assoc
    [ "reference", Skill_reference.to_yojson preview.reference
    ; "profile", Keeper_skill_observability.to_yojson preview.profile
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
