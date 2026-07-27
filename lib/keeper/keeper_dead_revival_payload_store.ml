open Keeper_dead_revival_payload_types
open Keeper_dead_revival_payload_domain
open Keeper_dead_revival_payload_codec

let payload_directory config =
  Filename.concat
    (Filename.concat
       (Workspace.masc_root_dir config)
       "keeper-lifecycle-transactions")
    payload_root_leaf
;;

let payload_shard_directory config authority_leaf =
  Filename.concat (payload_directory config) authority_leaf
;;

let reraise_fatal exception_ backtrace =
  match exception_ with
  | Out_of_memory | Stack_overflow | Sys.Break ->
    Printexc.raise_with_backtrace exception_ backtrace
  | _ -> ()
;;

let directory_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed
      (Keeper_fs_durable_directory.Non_directory_ancestor { path }) ->
    "non-directory ancestor: " ^ path
  | Directory_chain_failed (Outside_ownership_root { ownership_root; path }) ->
    Printf.sprintf
      "path %s is outside ownership root %s"
      path
      ownership_root
  | Directory_chain_failed (Missing_root { path }) ->
    "ownership root is missing: " ^ path
  | Directory_chain_failed (Creation_not_observed { path }) ->
    "directory creation was not observed: " ^ path
  | Operation_failed (exception_, backtrace) ->
    reraise_fatal exception_ backtrace;
    Printexc.to_string exception_
;;

let rec prepare_payload_shard config authority_leaf =
  if not (valid_authority_leaf authority_leaf)
  then Error (Invalid_binding "authority_leaf is not a canonical revival authority leaf")
  else
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_capability_unavailable
  | Some _ ->
    let ownership_root = Workspace.masc_root_dir config in
    let directory = payload_shard_directory config authority_leaf in
    (match
       Keeper_fs_durable_directory.ensure
         ~before_prepare:Fun.id
         ~before_directory_fsync:(fun _ -> ())
         ~ownership_root
         directory
     with
     | Error failure ->
       Error
         (Directory_prepare_failed
            (directory_failure_to_string failure))
     | Ok lease ->
       if Keeper_fs_durable_directory.lease_is_current lease
       then Ok directory
       else prepare_payload_shard config authority_leaf)
;;

let with_parent directory fn =
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_capability_unavailable
  | Some fs ->
    (try Eio.Path.with_open_dir Eio.Path.(fs / directory) fn with
     | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
     | exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       reraise_fatal exception_ backtrace;
       Error (Parent_open_failed (Printexc.to_string exception_)))
;;

let injected_create_failure target_effect =
  let exception_ =
    Failure "injected revival payload exclusive-create failure"
  in
  let backtrace = Printexc.get_callstack 1 in
  { Fs_compat.operation = Fs_compat.Create_exclusive_operation
  ; target_effect
  ; primary_failure =
      Fs_compat.Write_primary_failure
        { stage = Fs_compat.Create_target_entry
        ; cause =
            Fs_compat.Operation_failed
              { exception_; backtrace }
        }
  ; cleanup_failures = []
  }
;;

let create_exclusive ~parent ~leaf ~permissions bytes =
  match Eio.Fiber.get testing_hooks_key with
  | None ->
    Fs_compat.create_capability_file_exclusive
      ~parent
      ~leaf
      ~permissions
      bytes
  | Some { create_target_effect = Some target_effect; _ } ->
    Error (injected_create_failure target_effect)
  | Some { create_target_effect = None; _ } ->
    Fs_compat.create_capability_file_exclusive
      ~parent
      ~leaf
      ~permissions
      bytes
;;

type observation_failure =
  | Observation_read_failed of
      Fs_compat.Capability_exact_read.failure
  | Observation_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list

type reconciliation_observation_failure =
  | Reconciliation_observation_failed of observation_failure
  | Observation_injected_read_failed of string

let observe_reference ~parent reference =
  let read () =
    Fs_compat.Capability_exact_read.read
      ~parent
      ~leaf:reference.transaction_leaf
      ~expected_length:reference.byte_count
      ~max_length:(Int64.of_int Sys.max_string_length)
  in
  let observe () =
    match read () with
    | Error failure -> Error (Observation_read_failed failure)
    | Ok observation ->
      let warnings =
        Fs_compat.Capability_exact_read.observation_settlement_warnings
          observation
      in
      if warnings = []
      then
        Ok
          (Fs_compat.Capability_exact_read.observation_bytes observation)
      else Error (Observation_settlement_failed warnings)
  in
  observe ()
;;

let observe_reference_for_reconciliation ~parent reference =
  let observe () =
    observe_reference ~parent reference
    |> Result.map_error (fun failure ->
      Reconciliation_observation_failed failure)
  in
  match Eio.Fiber.get testing_hooks_key with
  | Some hooks ->
    (match hooks.reconciliation_read () with
     | `Fail detail -> Error (Observation_injected_read_failed detail)
     | `Use_production -> observe ())
  | None -> observe ()
;;

type parent_sync_failure =
  | Parent_sync_failed of
      Fs_compat.capability_directory_sync_error
  | Parent_sync_injected of string

let sync_parent_for_reconciliation parent =
  let sync () =
    Fs_compat.sync_directory_capability parent
    |> Result.map_error (fun failure -> Parent_sync_failed failure)
  in
  match Eio.Fiber.get testing_hooks_key with
  | None -> sync ()
  | Some hooks ->
    (match hooks.parent_sync () with
     | `Fail detail -> Error (Parent_sync_injected detail)
     | `Use_production -> sync ())
;;

let create config prepared =
  let reference = prepared.reference in
  let* directory =
    prepare_payload_shard config reference.authority_leaf
  in
  with_parent directory (fun parent ->
    match
      create_exclusive
        ~parent
        ~leaf:reference.transaction_leaf
        ~permissions:0o600
        prepared.bytes
    with
    | Ok () -> Ok (Created prepared)
    | Error initial_failure ->
      (match initial_failure.target_effect with
       | Fs_compat.Target_created_incomplete
       | Target_state_unknown
       | Target_replaced
       | Target_unchanged ->
         Error (Create_unsettled { prepared; initial_failure })
       | Target_created ->
         (match
            observe_reference_for_reconciliation ~parent reference
          with
          | Ok observed when String.equal observed prepared.bytes ->
            (match sync_parent_for_reconciliation parent with
             | Ok () ->
               Ok
                 (Reconciled_created
                    { prepared; initial_failure })
             | Error (Parent_sync_failed failure) ->
               Error
                 (Create_reconciliation_failed
                    { prepared
                    ; initial_failure
                    ; reconciliation_failure =
                        Reconciliation_parent_sync_failed failure
                    })
             | Error (Parent_sync_injected detail) ->
               Error
                 (Create_reconciliation_failed
                    { prepared
                    ; initial_failure
                    ; reconciliation_failure =
                        Reconciliation_parent_sync_injected detail
                    }))
          | Ok _ ->
            Error (Create_conflict { prepared; initial_failure })
          | Error
              (Reconciliation_observation_failed
                 (Observation_read_failed failure)) ->
            (match failure.error with
             | Fs_compat.Capability_exact_read.Length_mismatch _ ->
               Error (Create_conflict { prepared; initial_failure })
             | _ ->
               Error
                 (Create_reconciliation_failed
                    { prepared
                    ; initial_failure
                    ; reconciliation_failure =
                        Reconciliation_read_failed failure
                    }))
          | Error
              (Reconciliation_observation_failed
                 (Observation_settlement_failed warnings)) ->
            Error
              (Create_reconciliation_failed
                 { prepared
                 ; initial_failure
                 ; reconciliation_failure =
                     Reconciliation_read_settlement_failed warnings
                 })
          | Error (Observation_injected_read_failed detail) ->
            Error
              (Create_reconciliation_failed
                 { prepared
                 ; initial_failure
                 ; reconciliation_failure =
                     Reconciliation_read_injected detail
                 }))))
;;

let validate_reference (reference : immutable_ref) =
  if not (valid_authority_leaf reference.authority_leaf)
  then Error (Malformed_ref "authority_leaf is not canonical")
  else if not (valid_transaction_leaf reference.transaction_leaf)
  then Error (Malformed_ref "transaction_leaf is not canonical")
  else if not (is_lowercase_sha256 reference.sha256)
  then Error (Malformed_ref "sha256 is not a lowercase SHA-256")
  else if Int64.compare reference.byte_count 0L <= 0
  then Error (Malformed_ref "byte_count must be positive")
  else Ok ()
;;

let validate_reference_binding
      reference
      ~keeper_name
      ~expected_authority_leaf
      ~transaction_id
  =
  let* () = validate_reference reference in
  let* shard = authority_shard_for_keeper ~keeper_name in
  if not (String.equal expected_authority_leaf shard.authority_leaf)
  then
    Error
      (Invalid_binding
         "expected_authority_leaf does not match canonical keeper authority")
  else if not (String.equal reference.authority_leaf shard.authority_leaf)
  then Error Payload_binding_mismatch
  else
    let* expected_transaction_leaf =
      transaction_leaf_for_id ~transaction_id
    in
    if
      String.equal
        reference.transaction_leaf
        expected_transaction_leaf
    then Ok shard
    else Error Payload_binding_mismatch
;;

let read
      config
      ~expected_ref
      ~expected_authority_leaf
      ~transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
  =
  let* shard =
    validate_reference_binding
      expected_ref
      ~keeper_name
      ~expected_authority_leaf
      ~transaction_id
  in
  let directory =
    payload_shard_directory config shard.authority_leaf
  in
  let* bytes =
    with_parent directory (fun parent ->
      match observe_reference ~parent expected_ref with
      | Ok bytes -> Ok bytes
      | Error (Observation_read_failed failure) ->
        Error (Read_failed failure)
      | Error (Observation_settlement_failed warnings) ->
        Error (Read_settlement_failed warnings))
  in
  if not (String.equal expected_ref.sha256 (payload_digest bytes))
  then Error Payload_digest_mismatch
  else
    let* observed_payload = payload_of_bytes bytes in
    if
      String.equal observed_payload.transaction_id transaction_id
      && String.equal observed_payload.owner_id owner_id
      && String.equal observed_payload.keeper_name keeper_name
      && Keeper_id.Trace_id.equal
           observed_payload.expected_trace_id
           expected_trace_id
      && Int.equal
           observed_payload.expected_generation
           expected_generation
    then Ok observed_payload
    else Error Payload_binding_mismatch
;;

let delete
      config
      ~keeper_name
      ~expected_authority_leaf
      ~transaction_id
      reference
  =
  let* shard =
    validate_reference_binding
      reference
      ~keeper_name
      ~expected_authority_leaf
      ~transaction_id
  in
  let directory =
    payload_shard_directory config shard.authority_leaf
  in
  let path = Filename.concat directory reference.transaction_leaf in
  Keeper_fs.remove_file_durable
    ~ownership_root:(Workspace.masc_root_dir config)
    path
  |> Result.map_error (fun failure -> Delete_failed failure)
;;

let authority_shard_is_valid shard =
  valid_authority_leaf shard.authority_leaf
  &&
  match shard.keeper_name with
  | None -> true
  | Some keeper_name ->
    String.equal
      shard.authority_leaf
      (canonical_authority_leaf keeper_name)
;;
