(** Record files of the publication recovery store: where one obligation
    record lives in an area, and the file operations on it. Read a record
    while checking that it is a regular file with the expected identity and
    permissions; create it exclusively; install it or confirm that an
    existing file holds exactly the same bytes; verify and remove a source
    record; and raise the failures for a missing record or an existing record
    that differs.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it. *)

open Capability_recovery_record
open Capability_recovery_store_model
open Capability_recovery_store_layout

let area_capability (store : store) = function
  | Active -> store.active
  | Owned -> store.owned
  | Forensic -> store.forensic
;;

let area_directory store area =
  match area_capability store area with
  | Area_available directory -> directory
  | Area_unavailable error -> raise (Transition_failed error)
;;

let record_path (store : store) area operation_id =
  Eio.Path.
    (area_directory store area / record_name operation_id)
;;

let record_subject (store : store) area operation_id =
  Record (area, store.owner, operation_id)
;;

let capture_failure ~operation ~subject f =
  try
    f ();
    []
  with
  | Store_failure failure -> [ failure ]
  | Eio.Cancel.Cancelled _ as cancelled ->
    Printexc.raise_with_backtrace cancelled (Printexc.get_raw_backtrace ())
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    [ make_failure ~operation ~subject exception_ backtrace ]
;;

let close_resource_failures ~subject resource =
  capture_failure ~operation:Close_record ~subject (fun () ->
    Eio.Resource.close resource)
;;

let read_raw_record ~store ~area ~operation_id ~store_effect =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let lexical =
    raise_io ~operation:Inspect_record ~subject (fun () ->
      Eio.Path.stat ~follow:false path)
  in
  if lexical.kind <> `Regular_file
  then
    raise_validation
      ~operation:Inspect_record
      ~subject
      (Record_kind_mismatch
         { expected = `Regular_file; actual = lexical.kind });
  let lexical_identity = identity_of_stat lexical in
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    let resource = ref None in
    let cleanup () =
      match !resource with
      | None -> []
      | Some file ->
        resource := None;
        close_resource_failures ~subject file
    in
    try
      let file =
        raise_io ~operation:Open_record ~subject (fun () ->
          Eio.Path.open_in ~sw path)
      in
      Resource_scope.track_close ~sw file;
      resource := Some file;
      let opened =
        raise_io ~operation:Inspect_record ~subject (fun () ->
          Eio.File.stat file)
      in
      if opened.kind <> `Regular_file
      then
        raise_validation
          ~operation:Inspect_record
          ~subject
          (Record_kind_mismatch
             { expected = `Regular_file; actual = opened.kind });
      let opened_identity = identity_of_stat opened in
      if not (equal_identity lexical_identity opened_identity)
      then
        raise_validation
          ~operation:Verify_record_identity
          ~subject
          (Record_identity_mismatch
             { expected = lexical_identity; actual = opened_identity });
      let opened_permissions = opened.perm land 0o7777 in
      if opened_permissions <> record_permissions
      then
        raise_validation
          ~operation:Inspect_record
          ~subject
          (Record_permissions_mismatch
             { expected = record_permissions; actual = opened_permissions });
      let raw =
        raise_io ~operation:Read_record ~subject (fun () ->
          Eio.Flow.read_all file)
      in
      let after =
        raise_io ~operation:Verify_record_identity ~subject (fun () ->
          Eio.File.stat file)
      in
      let after_identity = identity_of_stat after in
      if after.kind <> `Regular_file
      then
        raise_validation
          ~operation:Verify_record_identity
          ~subject
          (Record_kind_mismatch
             { expected = `Regular_file; actual = after.kind });
      if not (equal_identity opened_identity after_identity)
      then
        raise_validation
          ~operation:Verify_record_identity
          ~subject
          (Record_identity_mismatch
             { expected = opened_identity; actual = after_identity });
      raise_io ~operation:Close_record ~subject (fun () ->
        Eio.Resource.close file);
      resource := None;
      raw, opened_identity
    with
    | Eio.Cancel.Cancelled reason as cancellation ->
      let backtrace = Printexc.get_raw_backtrace () in
      let cleanup_failures = Eio.Cancel.protect cleanup in
      if cleanup_failures = []
      then Printexc.raise_with_backtrace cancellation backtrace
      else
        Printexc.raise_with_backtrace
          (Eio.Cancel.Cancelled
             (Recovery_store_cancelled
                (reason, store_effect, cleanup_failures)))
          backtrace
    | Store_failure failure ->
      let cleanup_failures = Eio.Cancel.protect cleanup in
      if cleanup_failures = []
      then raise (Store_failure failure)
      else
        raise
          (Transition_failed
             { store_effect; failure; cleanup_failures })
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let cleanup_failures = Eio.Cancel.protect cleanup in
      let failure =
        make_failure ~operation:Read_record ~subject exception_ backtrace
      in
      raise
        (Transition_failed
           { store_effect; failure; cleanup_failures })
  in
  let release_failure =
    Option.map
      (resource_scope_failure ~operation:Close_record ~subject)
      outcome.scope_failure
  in
  match outcome.callback with
  | None ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       raise_resource_scope_cancellation
         ~default_effect:store_effect
         ~release_failure:None
         cancellation
     | None ->
       (match outcome.scope_failure with
        | Some raised ->
          raise_resource_scope_exception ~store_effect raised
        | None -> raise Internal_resource_scope_callback_not_entered))
  | Some (Resource_scope.Cancelled cancellation) ->
    raise_resource_scope_cancellation
      ~default_effect:store_effect
      ~release_failure
      cancellation
  | Some (Resource_scope.Raised raised) ->
    raise_resource_scope_exception ?release_failure ~store_effect raised
  | Some (Resource_scope.Returned value) ->
    (match outcome.parent_cancellation, release_failure with
     | Some cancellation, release_failure ->
       raise_resource_scope_cancellation
         ~default_effect:store_effect
         ~release_failure
         cancellation
     | None, Some failure ->
       raise
         (Transition_failed
            { store_effect; failure; cleanup_failures = [] })
     | None, None -> value)
;;

let write_record_payload ~subject file raw =
  match
    Blocking_write.write_string
      ~label:"fs-compat-recovery-record-write"
      file
      raw
  with
  | Ok () -> Eio.Fiber.check ()
  | Error Blocking_write.Open_file_posix_descriptor_unavailable ->
    let exception_ = Internal_posix_descriptor_unavailable in
    let backtrace = Printexc.get_callstack 16 in
    raise
      (Store_failure
         (make_failure ~operation:Write_record ~subject exception_ backtrace))
  | Error
      (Blocking_write.Open_file_operation_failed
        { exception_; backtrace; bytes_written }) ->
    raise
      (Store_failure
         { operation = Write_record
         ; subject
         ; cause = Write_failed { exception_; backtrace; bytes_written }
         })
;;

let apply_record_permissions ~subject file =
  raise_io ~operation:Apply_permissions ~subject (fun () ->
    match Eio_unix.Resource.fd_opt file with
    | None -> raise Internal_posix_descriptor_unavailable
    | Some fd ->
      Systhread_host.run
        ~label:"fs-compat-recovery-record-fchmod"
        (fun () ->
           Eio_unix.Fd.use_exn
             "fs-compat-recovery-record-fchmod"
             fd
             (fun unix_fd -> Unix.fchmod unix_fd record_permissions));
      let stat = Eio.File.stat file in
      let actual = stat.perm land 0o7777 in
      if actual <> record_permissions
      then
        raise
          (Record_validation_failed
             (Record_permissions_mismatch
                { expected = record_permissions; actual }));
      Eio.Fiber.check ())
;;

let cleanup_created_record
      ~store
      ~area
      ~operation_id
      ~resource
      ~created_identity
      ~entry_created
  =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let failures = ref [] in
  let add more = failures := !failures @ more in
  (match !resource with
   | None -> ()
   | Some file ->
     resource := None;
     add (close_resource_failures ~subject file));
  let removed = ref false in
  (match !entry_created, !created_identity with
   | false, _ -> ()
   | true, None ->
       let exception_ = Internal_created_record_identity_unavailable in
       let backtrace = Printexc.get_callstack 16 in
       add
         [ make_failure
             ~operation:Verify_record_identity
             ~subject
             exception_
             backtrace
         ]
   | true, Some expected ->
     let identity_failures =
       capture_failure ~operation:Verify_record_identity ~subject (fun () ->
         let actual = Eio.Path.stat ~follow:false path in
         if actual.kind <> `Regular_file
         then raise (Internal_unexpected_resource_kind actual.kind);
         let actual_identity = identity_of_stat actual in
         if not (equal_identity expected actual_identity)
         then
           raise
             (Internal_resource_identity_changed (expected, actual_identity)))
     in
     add identity_failures;
     if identity_failures = []
     then (
       let remove_failures =
         capture_failure ~operation:Remove_record ~subject (fun () ->
           Eio.Path.unlink path)
       in
       add remove_failures;
       if remove_failures = [] then removed := true));
  let removal_sync_failures =
    if not !removed
    then []
    else
      capture_failure
        ~operation:Sync_directory
        ~subject:(Area (area, store.owner))
        (fun () ->
           sync_directory
             ~subject:(Area (area, store.owner))
             (area_directory store area))
  in
  add removal_sync_failures;
  let record_absent_durable =
    (not !entry_created) || (!removed && removal_sync_failures = [])
  in
  !failures, record_absent_durable
;;

type exclusive_write_result =
  | Record_created
  | Record_exists

let create_record_exclusive
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~success_effect
      ~unknown_effect
  =
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  Eio.Cancel.protect @@ fun () ->
  let outcome =
    Resource_scope.run_resource_only @@ fun sw ->
    let resource = ref None in
    let created_identity = ref None in
    let entry_created = ref false in
    try
      let opened =
        try
          Some
            (raise_io ~operation:Create_record ~subject (fun () ->
               Eio.Path.open_out
                 ~sw
                 ~create:(`Exclusive record_permissions)
                 path))
        with
        | Store_failure
            { cause =
                Io_failed
                  { exception_ =
                      Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _)
                  ; _
                  }
            ; _
            } ->
          None
      in
      match opened with
      | None -> Record_exists
      | Some file ->
        Resource_scope.track_close ~sw file;
        entry_created := true;
        resource := Some file;
        let stat =
          raise_io ~operation:Inspect_record ~subject (fun () ->
            Eio.File.stat file)
        in
        if stat.kind <> `Regular_file
        then
          raise_validation
            ~operation:Inspect_record
            ~subject
            (Record_kind_mismatch
               { expected = `Regular_file; actual = stat.kind });
        created_identity := Some (identity_of_stat stat);
        apply_record_permissions ~subject file;
        write_record_payload ~subject file raw;
        raise_io ~operation:Sync_record ~subject (fun () -> Eio.File.sync file);
        raise_io ~operation:Close_record ~subject (fun () ->
          Eio.Resource.close file);
        resource := None;
        sync_directory
          ~subject:(Area (area, store.owner))
          (area_directory store area);
        Record_created
    with
    | Eio.Cancel.Cancelled reason as cancellation ->
      let backtrace = Printexc.get_raw_backtrace () in
      let cleanup_failures, record_absent_durable =
        cleanup_created_record
          ~store
          ~area
          ~operation_id
          ~resource
          ~created_identity
          ~entry_created
      in
      let store_effect =
        if record_absent_durable then base_effect else unknown_effect
      in
      if store_effect = No_record_change && cleanup_failures = []
      then Printexc.raise_with_backtrace cancellation backtrace
      else
        Printexc.raise_with_backtrace
          (Eio.Cancel.Cancelled
             (Recovery_store_cancelled
                (reason, store_effect, cleanup_failures)))
          backtrace
    | Store_failure failure ->
      let cleanup_failures, record_absent_durable =
        cleanup_created_record
          ~store
          ~area
          ~operation_id
          ~resource
          ~created_identity
          ~entry_created
      in
      let store_effect =
        if record_absent_durable then base_effect else unknown_effect
      in
      raise (Transition_failed { store_effect; failure; cleanup_failures })
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let cleanup_failures, record_absent_durable =
        cleanup_created_record
          ~store
          ~area
          ~operation_id
          ~resource
          ~created_identity
          ~entry_created
      in
      let store_effect =
        if record_absent_durable then base_effect else unknown_effect
      in
      let failure =
        make_failure ~operation:Write_record ~subject exception_ backtrace
      in
      raise (Transition_failed { store_effect; failure; cleanup_failures })
  in
  let release_failure =
    Option.map
      (resource_scope_failure ~operation:Close_record ~subject)
      outcome.scope_failure
  in
  match outcome.callback with
  | None ->
    (match outcome.parent_cancellation with
     | Some cancellation ->
       raise_resource_scope_cancellation
         ~default_effect:base_effect
         ~release_failure:None
         cancellation
     | None ->
       (match outcome.scope_failure with
        | Some raised ->
          raise_resource_scope_exception ~store_effect:base_effect raised
        | None -> raise Internal_resource_scope_callback_not_entered))
  | Some (Resource_scope.Cancelled cancellation) ->
    raise_resource_scope_cancellation
      ~default_effect:base_effect
      ~release_failure
      cancellation
  | Some (Resource_scope.Raised raised) ->
    raise_resource_scope_exception
      ?release_failure
      ~store_effect:unknown_effect
      raised
  | Some (Resource_scope.Returned result) ->
    let completed_effect =
      match result with
      | Record_created -> success_effect
      | Record_exists -> base_effect
    in
    (match outcome.parent_cancellation, release_failure with
     | Some cancellation, release_failure ->
       raise_resource_scope_cancellation
         ~default_effect:completed_effect
         ~release_failure
         cancellation
     | None, Some failure ->
       raise
         (Transition_failed
            { store_effect = completed_effect
            ; failure
            ; cleanup_failures = []
            })
     | None, None -> result)
;;

type ensure_record_result =
  | Installed_record
  | Existing_exact_record

let ensure_exact_record
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~success_effect
      ~unknown_effect
  =
  match
    create_record_exclusive
      ~store
      ~area
      ~operation_id
      ~raw
      ~base_effect
      ~success_effect
      ~unknown_effect
  with
  | Record_created -> Installed_record
  | Record_exists ->
    let existing_raw, _ =
      read_raw_record ~store ~area ~operation_id ~store_effect:base_effect
    in
    if not (String.equal raw existing_raw)
    then (
      let subject = record_subject store area operation_id in
      let exception_ = Internal_existing_record_does_not_match in
      let backtrace = Printexc.get_callstack 16 in
      raise
        (Store_failure
           (make_failure ~operation:Decode_record ~subject exception_ backtrace)));
    sync_directory
      ~subject:(Area (area, store.owner))
      (area_directory store area);
    Existing_exact_record
;;

let verify_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~store_effect
  =
  let actual_raw, identity =
    read_raw_record ~store ~area ~operation_id ~store_effect
  in
  if not (String.equal expected_raw actual_raw)
  then (
    let subject = record_subject store area operation_id in
    let exception_ = Internal_existing_record_does_not_match in
    let backtrace = Printexc.get_callstack 16 in
    raise
      (Store_failure
         (make_failure ~operation:Decode_record ~subject exception_ backtrace)));
  identity
;;

let remove_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~effect_before
      ~removal_transition
  =
  Eio.Cancel.protect @@ fun () ->
  let subject = record_subject store area operation_id in
  let path = record_path store area operation_id in
  let expected_identity =
    verify_exact_source
      ~store
      ~area
      ~operation_id
      ~expected_raw
      ~store_effect:effect_before
  in
  let removed = ref false in
  try
    let actual =
      raise_io ~operation:Verify_record_identity ~subject (fun () ->
        Eio.Path.stat ~follow:false path)
    in
    if actual.kind <> `Regular_file
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_kind_mismatch
           { expected = `Regular_file; actual = actual.kind });
    let actual_identity = identity_of_stat actual in
    if not (equal_identity expected_identity actual_identity)
    then
      raise_validation
        ~operation:Verify_record_identity
        ~subject
        (Record_identity_mismatch
           { expected = expected_identity; actual = actual_identity });
    raise_io ~operation:Remove_record ~subject (fun () -> Eio.Path.unlink path);
    removed := true;
    (match Eio.Fiber.get discharge_cancellation_key with
     | Some fault when equal_owner store.owner fault.discharge_owner
         && removal_transition = fault.discharge_transition ->
       Printexc.raise_with_backtrace
         (Eio.Cancel.Cancelled fault.discharge_reason) fault.discharge_backtrace
     | None | Some _ -> ());
    sync_directory
      ~subject:(Area (area, store.owner))
      (area_directory store area)
  with
  | Eio.Cancel.Cancelled reason ->
    let backtrace = Printexc.get_raw_backtrace () in
    let original_reason, prior_effect, cleanup_failures =
      match reason with
      | Recovery_store_cancelled (original_reason, prior_store_effect, cleanup_failures) ->
        original_reason, prior_store_effect, cleanup_failures
      | original_reason -> original_reason, effect_before, []
    in
    let store_effect =
      if !removed
      then Source_removal_durability_unknown removal_transition
      else prior_effect
    in
    Printexc.raise_with_backtrace
      (Eio.Cancel.Cancelled
         (Recovery_store_cancelled (original_reason, store_effect, cleanup_failures)))
      backtrace
  | Store_failure failure ->
    let store_effect =
      if !removed
      then Source_removal_durability_unknown removal_transition
      else effect_before
    in
    raise
      (Transition_failed
         { store_effect; failure; cleanup_failures = [] })
;;

let record_kind ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  raise_io ~operation:Inspect_record ~subject (fun () ->
    Eio.Path.kind ~follow:false (record_path store area operation_id))
;;

let raise_missing_record ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  let exception_ = Internal_missing_record in
  let backtrace = Printexc.get_callstack 16 in
  raise
    (Store_failure
       (make_failure ~operation:Inspect_record ~subject exception_ backtrace))
;;

let raise_existing_record_mismatch ~store ~area ~operation_id =
  let subject = record_subject store area operation_id in
  let exception_ = Internal_existing_record_does_not_match in
  let backtrace = Printexc.get_callstack 16 in
  raise
    (Store_failure
       (make_failure ~operation:Decode_record ~subject exception_ backtrace))
;;
