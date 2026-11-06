(* The record model is [Capability_recovery_record], included here. Its JSON
   codec is [Capability_recovery_record_codec], opened here. Three more
   modules are included here: [Capability_recovery_store_model], the
   directory names and the failure vocabulary;
   [Capability_recovery_store_layout], the directory layout operations; and
   [Capability_recovery_store_scope], owner discovery and the scoped opening
   of one owner's store. *)
include Capability_recovery_record
open Capability_recovery_record_codec
include Capability_recovery_store_model
include Capability_recovery_store_layout
include Capability_recovery_store_scope

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
      Eio_unix.run_in_systhread
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

let ensure_input_owner ~store ~operation_id actual_owner =
  if not (equal_owner store.owner actual_owner)
  then
    raise_validation
      ~operation:Decode_record
      ~subject:(Record (Active, store.owner, operation_id))
      (Record_owner_mismatch
         { expected = store.owner; actual = actual_owner })
;;

let run_mutation ~initial_effect f =
  let observed_effect = ref initial_effect in
  try
    let value = Eio.Cancel.protect (fun () -> f observed_effect) in
    Eio.Fiber.check ();
    Ok value
  with
  | Eio.Cancel.Cancelled (Recovery_store_cancelled _) as cancellation ->
    (* An inner effect boundary knows more than this transaction's last
       completed step. Preserve its exact mutation and original authority. *)
    Printexc.raise_with_backtrace cancellation (Printexc.get_raw_backtrace ())
  | Eio.Cancel.Cancelled reason as cancellation ->
    let backtrace = Printexc.get_raw_backtrace () in
    if !observed_effect = No_record_change
    then Printexc.raise_with_backtrace cancellation backtrace
    else
      Printexc.raise_with_backtrace
        (Eio.Cancel.Cancelled
           (Recovery_store_cancelled (reason, !observed_effect, [])))
        backtrace
  | Transition_failed error -> Error error
  | Store_failure failure ->
    Error
      { store_effect = !observed_effect
      ; failure
      ; cleanup_failures = []
      }
;;

(* NDT-OK: UUID entropy names an exclusively-created obligation record;
   correctness comes from exclusive create plus exact collision handling. The
   nonce never drives recovery or publication policy. *)
let operation_id_rng = Domain.DLS.new_key Random.State.make_self_init

let fresh_operation_id () =
  Uuidm.v4_gen (Domain.DLS.get operation_id_rng) ()
;;

let prepare_with_operation_id_internal
      ~store
      ~operation_id
      ~publication
      ~locator
      ~permissions
  =
  let prepared = { owner = store.owner; operation_id; publication; locator; permissions } in
  let raw = encode_prepared prepared in
  (match record_kind ~store ~area:Owned ~operation_id with
   | `Not_found -> ()
   | _ -> raise_existing_record_mismatch ~store ~area:Owned ~operation_id);
  (match record_kind ~store ~area:Forensic ~operation_id with
   | `Not_found -> ()
   | _ -> raise_existing_record_mismatch ~store ~area:Forensic ~operation_id);
  ignore
    (ensure_exact_record
       ~store
       ~area:Active
       ~operation_id
       ~raw
       ~base_effect:No_record_change
       ~success_effect:Active_record_durable
       ~unknown_effect:Active_record_state_unknown);
  prepared
;;

let prepare ~(store : store) ~publication ~(locator : locator) ~(permissions : permissions) =
  let create_attempt () =
    let operation_id = fresh_operation_id () in
    let prepared = { owner = store.owner; operation_id; publication; locator; permissions } in
    let raw = encode_prepared prepared in
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    match
      create_record_exclusive
        ~store
        ~area:Active
        ~operation_id
        ~raw
        ~base_effect:No_record_change
        ~success_effect:Active_record_durable
        ~unknown_effect:Active_record_state_unknown
    with
    | Record_exists -> `Collision
    | Record_created ->
      observed_effect := Active_record_durable;
      let cross_area_collision =
        match record_kind ~store ~area:Owned ~operation_id with
        | `Not_found ->
          (match record_kind ~store ~area:Forensic ~operation_id with
           | `Not_found -> false
           | _ -> true)
        | _ -> true
      in
      if not cross_area_collision
      then `Prepared prepared
      else (
        remove_exact_source
          ~store
          ~area:Active
          ~operation_id
          ~expected_raw:raw
          ~effect_before:Active_record_durable
          ~removal_transition:Discharge_active;
        observed_effect := Active_record_discharged;
        `Collision)
  in
  let rec retry () =
    match create_attempt () with
    | Error _ as error -> error
    | Ok (`Prepared prepared) -> Ok prepared
    | Ok `Collision ->
      (* Collision retry is intentionally outside cancellation protection. The
         loop is meaning-based and unbounded, but it remains cancellable. *)
      Eio.Fiber.check ();
      retry ()
  in
  retry ()
;;

let bind ~(store : store) ~(prepared : prepared) ~stage_identity =
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  let bound = { prepared; stage_identity } in
  let active_raw = encode_prepared prepared in
  let owned_raw = encode_bound bound in
  (match record_kind ~store ~area:Active ~operation_id with
   | `Not_found ->
     (match record_kind ~store ~area:Owned ~operation_id with
      | `Regular_file ->
        ignore
          (verify_exact_source
             ~store
             ~area:Owned
             ~operation_id
             ~expected_raw:owned_raw
             ~store_effect:Owned_record_durable);
        (* Under this module's sole-writer protocol, an exact destination with
           no source is reachable only after the destination barrier. Record
           that causal state before repeating either idempotency barrier. *)
        observed_effect :=
          Source_removal_durability_unknown Active_to_owned;
        sync_directory
          ~subject:(Area (Owned, store.owner))
          (area_directory store Owned);
        sync_directory
          ~subject:(Area (Active, store.owner))
          (area_directory store Active);
        observed_effect := Owned_record_durable
      | `Not_found -> raise_missing_record ~store ~area:Active ~operation_id
      | _ ->
        raise_existing_record_mismatch ~store ~area:Owned ~operation_id)
   | `Regular_file ->
     ignore
       (verify_exact_source
          ~store
          ~area:Active
          ~operation_id
          ~expected_raw:active_raw
          ~store_effect:Active_record_durable);
     observed_effect := Active_record_durable;
     ignore
       (ensure_exact_record
          ~store
          ~area:Owned
          ~operation_id
          ~raw:owned_raw
          ~base_effect:Active_record_durable
          ~success_effect:Owned_record_durable_with_active
          ~unknown_effect:Owned_record_state_unknown_with_active);
     observed_effect := Owned_record_durable_with_active;
     remove_exact_source
       ~store
       ~area:Active
       ~operation_id
       ~expected_raw:active_raw
       ~effect_before:Owned_record_durable_with_active
       ~removal_transition:Active_to_owned;
     observed_effect := Owned_record_durable
   | _ -> raise_existing_record_mismatch ~store ~area:Active ~operation_id);
  bound
;;

type discharge_outcome =
  | Discharged
  | Already_discharged

let discharge_prepared ~(store : store) ~(prepared : prepared) =
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  match record_kind ~store ~area:Active ~operation_id with
  | `Not_found ->
    observed_effect :=
      Source_removal_durability_unknown Discharge_active;
    sync_directory
      ~subject:(Area (Active, store.owner))
      (area_directory store Active);
    observed_effect := Active_record_discharged;
    Already_discharged
  | `Regular_file ->
    observed_effect := Active_record_durable;
    remove_exact_source
      ~store
      ~area:Active
      ~operation_id
      ~expected_raw:(encode_prepared prepared)
      ~effect_before:Active_record_durable
      ~removal_transition:Discharge_active;
    observed_effect := Active_record_discharged;
    Discharged
  | _ -> raise_existing_record_mismatch ~store ~area:Active ~operation_id
;;

let discharge_bound ~(store : store) ~(bound : bound) =
  let prepared = bound.prepared in
  let operation_id = prepared.operation_id in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  ensure_input_owner ~store ~operation_id prepared.owner;
  match record_kind ~store ~area:Owned ~operation_id with
  | `Not_found ->
    observed_effect :=
      Source_removal_durability_unknown Discharge_owned;
    sync_directory
      ~subject:(Area (Owned, store.owner))
      (area_directory store Owned);
    observed_effect := Owned_record_discharged;
    Already_discharged
  | `Regular_file ->
    observed_effect := Owned_record_durable;
    remove_exact_source
      ~store
      ~area:Owned
      ~operation_id
      ~expected_raw:(encode_bound bound)
      ~effect_before:Owned_record_durable
      ~removal_transition:Discharge_owned;
    observed_effect := Owned_record_discharged;
    Discharged
  | _ -> raise_existing_record_mismatch ~store ~area:Owned ~operation_id
;;

type forensic_transition_source =
  | Active_forensic_source
  | Owned_forensic_source

let transition_to_forensic
      ~store
      ~operation_id
      ~source
      ~source_raw
      ~forensic
  =
  let forensic_raw = encode_forensic forensic in
  let source_area, source_effect, removal_transition =
    match source with
    | Active_forensic_source ->
      Active, Active_record_durable, Active_to_forensic
    | Owned_forensic_source ->
      Owned, Owned_record_durable, Owned_to_forensic
  in
  run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
  (match record_kind ~store ~area:source_area ~operation_id with
   | `Not_found ->
     (match record_kind ~store ~area:Forensic ~operation_id with
      | `Regular_file ->
        ignore
          (verify_exact_source
             ~store
             ~area:Forensic
             ~operation_id
             ~expected_raw:forensic_raw
             ~store_effect:Forensic_record_durable);
        (* See [bind]: source removal follows the durable destination barrier,
           so the exact resumed state is known before barrier repair. *)
        observed_effect :=
          Source_removal_durability_unknown removal_transition;
        sync_directory
          ~subject:(Area (Forensic, store.owner))
          (area_directory store Forensic);
        sync_directory
          ~subject:(Area (source_area, store.owner))
          (area_directory store source_area);
        observed_effect := Forensic_record_durable
      | `Not_found ->
        raise_missing_record ~store ~area:source_area ~operation_id
      | _ ->
        raise_existing_record_mismatch ~store ~area:Forensic ~operation_id)
   | `Regular_file ->
     ignore
       (verify_exact_source
          ~store
          ~area:source_area
          ~operation_id
          ~expected_raw:source_raw
          ~store_effect:source_effect);
     observed_effect := source_effect;
     ignore
       (ensure_exact_record
          ~store
          ~area:Forensic
          ~operation_id
          ~raw:forensic_raw
          ~base_effect:source_effect
          ~success_effect:Forensic_record_durable_with_source
          ~unknown_effect:Forensic_record_state_unknown_with_source);
     observed_effect := Forensic_record_durable_with_source;
     remove_exact_source
       ~store
       ~area:source_area
       ~operation_id
       ~expected_raw:source_raw
       ~effect_before:Forensic_record_durable_with_source
       ~removal_transition;
     observed_effect := Forensic_record_durable
   | _ ->
     raise_existing_record_mismatch ~store ~area:source_area ~operation_id);
  forensic
;;

let record_forensic_prepared
      ~(store : store)
      ~(prepared : prepared)
      ~outcome
  =
  let operation_id = prepared.operation_id in
  match
    protect_result ~store_effect:No_record_change (fun () ->
      ensure_input_owner ~store ~operation_id prepared.owner;
      match validate_prepared_recovery_outcome prepared outcome with
      | Ok () -> ()
      | Error error ->
        raise_validation
          ~operation:Decode_record
          ~subject:(Record (Forensic, store.owner, operation_id))
          error)
  with
  | Error _ as error -> error
  | Ok () ->
    let forensic = { source = Prepared_source (prepared, outcome) } in
    transition_to_forensic
      ~store
      ~operation_id
      ~source:Active_forensic_source
      ~source_raw:(encode_prepared prepared)
      ~forensic
;;

let preserve_unbound
      ~(store : store)
      ~(prepared : prepared)
      ~kind
      ~stage_identity
  =
  record_forensic_prepared
    ~store
    ~prepared
    ~outcome:(Preserved_unbound_stage { kind; identity = stage_identity })
;;

let record_forensic_bound ~(store : store) ~(bound : bound) ~outcome =
  let prepared = bound.prepared in
  let operation_id = prepared.operation_id in
  match
    protect_result ~store_effect:No_record_change (fun () ->
      ensure_input_owner ~store ~operation_id prepared.owner;
      match validate_bound_recovery_outcome bound outcome with
      | Ok () -> ()
      | Error error ->
        raise_validation
          ~operation:Decode_record
          ~subject:(Record (Forensic, store.owner, operation_id))
          error)
  with
  | Error _ as error -> error
  | Ok () ->
    let forensic = { source = Bound_source (bound, outcome) } in
    transition_to_forensic
      ~store
      ~operation_id
      ~source:Owned_forensic_source
      ~source_raw:(encode_bound bound)
      ~forensic
;;

module For_testing = struct
  type nonrec discharge_record = discharge_record = Prepared_record | Bound_record
  type nonrec discharge_cancellation = discharge_cancellation

  let discharge_cancellation ~owner ~record ~reason ~backtrace =
    match owner_of_string owner with
    | Error _ as error -> error
    | Ok discharge_owner ->
      let discharge_transition = match record with
        | Prepared_record -> Discharge_active
        | Bound_record -> Discharge_owned
      in
      Ok { discharge_owner; discharge_transition;
           discharge_reason = reason; discharge_backtrace = backtrace }
  ;;

  let with_discharge_cancellation fault f =
    Eio.Fiber.with_binding discharge_cancellation_key fault f
  ;;

  type nonrec lane_scope_release_fault = lane_scope_release_fault

  let lane_scope_release_fault ~owner ~exception_ =
    match owner_of_string owner with
    | Error _ as error -> error
    | Ok fault_owner -> Ok { fault_owner; fault_exception = exception_ }
  ;;

  let with_lane_scope_release_fault fault f =
    Eio.Fiber.with_binding lane_scope_release_fault_key fault f
  ;;

  let operation_id_of_uuid operation_id = operation_id

  let prepare_with_operation_id
        ~(store : store)
        ~operation_id
        ~publication
        ~(locator : locator)
        ~(permissions : permissions)
    =
    run_mutation ~initial_effect:No_record_change @@ fun observed_effect ->
    let prepared =
      prepare_with_operation_id_internal
        ~store
        ~operation_id
        ~publication
        ~locator
        ~permissions
    in
    observed_effect := Active_record_durable;
    prepared
  ;;

  let area_directory = area_directory
end

type corrupt_record =
  { area : area
  ; operation_id : operation_id
  ; raw : string
  ; validation_error : validation_error
  }

type inventory_row =
  | Unexpected_lane_entry of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_lane_entry of { name : string }
  | Lane_entry_unavailable of
      { name : string
      ; error : transition_error
      }
  | Area_inventory_unavailable of
      { area : area
      ; error : transition_error
      }
  | Active_record of prepared
  | Owned_record of bound
  | Forensic_record of forensic
  | Invalid_record_name of
      { area : area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : area
      ; operation_id : operation_id
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : area
      ; operation_id : operation_id
      }
  | Record_entry_unavailable of
      { area : area
      ; operation_id : operation_id
      ; error : transition_error
      }
  | Corrupt_record of corrupt_record

type inventory = inventory_row list

let corrupt_if_identity_invalid
      ~store
      ~area
      ~operation_id
      ~raw
      ~record_owner
      ~record_id
      make_row
  =
  match
    validate_record_owner_and_id
      ~owner:store.owner
      ~operation_id
      ~record_owner
      ~record_id
  with
  | Ok () -> make_row ()
  | Error validation_error ->
    Corrupt_record { area; operation_id; raw; validation_error }
;;

let inventory_regular_record ~store ~area ~operation_id =
  let raw, _ =
    read_raw_record
      ~store
      ~area
      ~operation_id
      ~store_effect:No_record_change
  in
  match area with
  | Active ->
    (match decode_prepared raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok prepared ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:prepared.owner
         ~record_id:prepared.operation_id
         (fun () -> Active_record prepared))
  | Owned ->
    (match decode_bound raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok bound ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:bound.prepared.owner
         ~record_id:bound.prepared.operation_id
         (fun () -> Owned_record bound))
  | Forensic ->
    (match decode_forensic raw with
     | Error validation_error ->
       Corrupt_record { area; operation_id; raw; validation_error }
     | Ok forensic ->
       corrupt_if_identity_invalid
         ~store
         ~area
         ~operation_id
         ~raw
         ~record_owner:(forensic_owner forensic)
         ~record_id:(forensic_operation_id forensic)
         (fun () -> Forensic_record forensic))
;;

let inventory_area ~store area =
  let directory = area_directory store area in
  let subject = Area (area, store.owner) in
  let names =
    raise_io ~operation:Read_directory ~subject (fun () ->
      Eio.Path.read_dir directory)
  in
  List.map
    (fun name ->
       match operation_id_of_string name with
       | Error _ -> Invalid_record_name { area; name }
       | Ok operation_id ->
         (try
            match record_kind ~store ~area ~operation_id with
            | `Not_found -> Missing_record_entry { area; operation_id }
            | `Regular_file ->
              inventory_regular_record ~store ~area ~operation_id
            | ( ( `Unknown
                | `Fifo
                | `Character_special
                | `Directory
                | `Block_device
                | `Symbolic_link
                | `Socket ) as
                kind ) ->
              Unexpected_record_kind { area; operation_id; kind }
          with
          | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
          | Transition_failed error ->
            Record_entry_unavailable { area; operation_id; error }
          | Store_failure failure ->
            Record_entry_unavailable
              { area
              ; operation_id
              ; error = transition_error ~store_effect:No_record_change failure
              }))
    names
;;

let inventory_row_of_lane_residue = function
  | Lane_residue_present { name; kind } ->
    Unexpected_lane_entry { name; kind }
  | Lane_residue_missing { name } -> Missing_lane_entry { name }
  | Lane_residue_unavailable { name; error } ->
    Lane_entry_unavailable { name; error }
;;

let inventory_area_rows ~store area =
  try inventory_area ~store area with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Transition_failed error -> [ Area_inventory_unavailable { area; error } ]
  | Store_failure failure ->
    [ Area_inventory_unavailable
        { area
        ; error = transition_error ~store_effect:No_record_change failure
        }
    ]
;;

let inventory store =
  protect_result ~store_effect:No_record_change (fun () ->
    List.map inventory_row_of_lane_residue store.lane_residues
    @ inventory_area_rows ~store Active
    @ inventory_area_rows ~store Owned
    @ inventory_area_rows ~store Forensic)
;;
