include Keeper_lifecycle_nonce_types
open Keeper_lifecycle_nonce_storage

exception Injected_publication_settlement_warning
exception Injected_verified_publication_failure
exception Injected_publication_indeterminate

let identity ~owner_id ~nonce =
  if String.equal (String.trim owner_id) ""
  then Error Invalid_owner_id
  else if Int64.compare nonce 0L <= 0
  then Error (Invalid_floor nonce)
  else Ok { owner_id; nonce }
;;

let witness_base_path witness = witness.base_path
let witness_keeper_id witness = witness.keeper_id
let witness_source witness = witness.source
let witness_target witness = witness.target
let identity_owner_id identity = identity.owner_id
let identity_nonce identity = identity.nonce

let witness_of_nonce ~base_path ~keeper_id ~source ~owner_id nonce =
  { base_path; keeper_id; source; target = { owner_id; nonce } }
;;

let floor_for_create ~base_path ~keeper_id =
  match
    Keeper_shutdown_generation_floor.point_read
      ~base_path
      ~keeper_id
      ()
  with
  | Error error ->
    Error
      (Shutdown_floor_invalid
         (Keeper_shutdown_generation_floor.error_to_string error))
  | Ok None -> Ok 1L
  | Ok (Some floor) ->
    let generation = Keeper_shutdown_generation_floor.generation floor in
    if Int64.compare generation runtime_max_nonce >= 0
    then Error Nonce_exhausted
    else Ok (Int64.succ generation)
;;

let with_mutation_admission permit ~base_path ~keeper_id fn =
  match
    Keeper_lifecycle_admission.Durable_transaction.with_permit_lease
      permit
      ~base_path
      keeper_id
      fn
  with
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_completed
      result ->
    result
  | Keeper_lifecycle_admission.Durable_transaction.Permit_lease_denied ->
    Error Lifecycle_admission_mismatch
;;

let create_admitted ~base_path ~keeper_id ~owner_id () =
  let* floor = floor_for_create ~base_path ~keeper_id in
  let* nonce =
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap:Head.compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ~floor
      ()
  in
  Ok (witness_of_nonce ~base_path ~keeper_id ~source:None ~owner_id nonce)
;;

let create permit ~base_path ~keeper_id ~owner_id () =
  with_mutation_admission permit ~base_path ~keeper_id (fun () ->
    create_admitted ~base_path ~keeper_id ~owner_id ())
;;

let replace ~base_path ~keeper_id ~source ~owner_id () =
  let floor =
    if Int64.compare source.nonce runtime_max_nonce >= 0
    then Error Nonce_exhausted
    else Ok (Int64.succ source.nonce)
  in
  let* floor = floor in
  let compare_and_swap =
    match Eio.Fiber.get replacement_fault_key with
    | None -> Head.compare_and_swap
    | Some fault ->
      let hooks =
        match fault with
        | Publication_settlement_warning ->
          Head.For_testing.hooks
            ~on_resource_settlement:(fun () ->
              raise Injected_publication_settlement_warning)
            ()
        | Verified_publication_failure ->
          Head.For_testing.hooks
            ~after_verified:(fun () ->
              raise Injected_verified_publication_failure)
            ()
        | Publication_indeterminate ->
          Head.For_testing.hooks
            ~after_rename:(fun () ->
              raise Injected_publication_indeterminate)
            ()
        | Cancellation_after_publication ->
          Head.For_testing.hooks
            ~after_rename:(fun () ->
              raise
                (Eio.Cancel.Cancelled
                   (Failure
                      "injected lifecycle nonce cancellation after publication")))
            ()
      in
      Head.For_testing.compare_and_swap hooks
  in
  let* nonce =
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ~expected_source:source
      ~floor
      ()
  in
  Ok (witness_of_nonce ~base_path ~keeper_id ~source:(Some source) ~owner_id nonce)
;;

let recover_exact_admitted ~base_path ~keeper_id ~source ~target () =
  if Filename.is_relative base_path
  then Error (Invalid_base_path base_path)
  else
    let* root = prepare_root ~base_path in
    let* secure_random = entropy_source () in
    match
      with_head_parent root (fun parent ->
        Head.read
          ~secure_random
          ~parent
          ~leaf:(authority_leaf ~keeper_id))
    with
    | Error failure -> Error (Head_read_failed failure)
    | Ok snapshot ->
      let warnings = Head.snapshot_settlement_warnings snapshot in
      if warnings <> []
      then
        Error
          (Head_read_settlement_failed
             { cursor = Head.snapshot_cursor snapshot
             ; row = Head.snapshot_row snapshot
             ; observed_nonce =
                 observed_nonce ~keeper_id (Head.snapshot_row snapshot)
             ; warnings
             })
      else
        (match Head.snapshot_row snapshot with
         | None -> Error Authority_missing
         | Some raw ->
           let* row =
             decode_row ~keeper_id raw
             |> Result.map_error (fun corruption -> Corrupt_current corruption)
           in
           let row_target = { owner_id = row.allocated_to; nonce = row.nonce } in
           let row_source =
             match row.source_owner_id, row.source_nonce with
             | Some owner_id, Some nonce -> Some { owner_id; nonce }
             | None, None -> None
             | Some _, None | None, Some _ -> None
           in
           let equal_identity left right =
             String.equal left.owner_id right.owner_id
             && Int64.equal left.nonce right.nonce
           in
           let forward =
             Option.equal equal_identity source row_source
             && equal_identity target row_target
           in
           if forward
           then Ok { base_path; keeper_id; source; target }
           else Error Authority_identity_mismatch)
;;

let recover_exact permit ~base_path ~keeper_id ~source ~target () =
  with_mutation_admission permit ~base_path ~keeper_id (fun () ->
    recover_exact_admitted
      ~base_path
      ~keeper_id
      ~source
      ~target
      ())
;;

let recover_published_replace ~base_path ~keeper_id ~source () =
  if Filename.is_relative base_path
  then Error (Invalid_base_path base_path)
  else
    let* root = prepare_root ~base_path in
    let* secure_random = entropy_source () in
    match
      with_head_parent root (fun parent ->
        Head.read ~secure_random ~parent ~leaf:(authority_leaf ~keeper_id))
    with
    | Error failure -> Error (Head_read_failed failure)
    | Ok snapshot ->
      let warnings = Head.snapshot_settlement_warnings snapshot in
      if warnings <> []
      then
        Error
          (Head_read_settlement_failed
             { cursor = Head.snapshot_cursor snapshot
             ; row = Head.snapshot_row snapshot
             ; observed_nonce = observed_nonce ~keeper_id (Head.snapshot_row snapshot)
             ; warnings
             })
      else
        (match Head.snapshot_row snapshot with
         | None -> Error Authority_missing
         | Some raw ->
           let* row =
             decode_row ~keeper_id raw
             |> Result.map_error (fun corruption -> Corrupt_current corruption)
           in
           (match row.source_owner_id, row.source_nonce with
            | Some owner_id, Some nonce
              when String.equal owner_id source.owner_id
                   && Int64.equal nonce source.nonce ->
              let target = { owner_id = row.allocated_to; nonce = row.nonce } in
              Ok { base_path; keeper_id; source = Some source; target }
            | Some _, Some _ | None, None | Some _, None | None, Some _ ->
              Error Authority_identity_mismatch))
;;

let settle_published_replace
      ~base_path
      ~keeper_id
      ~source
      ~owner_id
      publication_error
  =
  let exact_target nonce =
    if Int64.compare source.nonce runtime_max_nonce >= 0
       || not (Int64.equal nonce (Int64.succ source.nonce))
    then Error Authority_identity_mismatch
    else
      Ok
        { base_path
        ; keeper_id
        ; source = Some source
        ; target = { owner_id; nonce }
        }
  in
  match publication_error with
  | Published_with_warnings { nonce; _ }
  | Published_with_failure { nonce; _ } ->
    exact_target nonce
  | Publication_indeterminate { nonce; _ } ->
    let* witness =
      recover_published_replace ~base_path ~keeper_id ~source ()
    in
    let target = witness.target in
    if String.equal target.owner_id owner_id
       && Int64.equal target.nonce nonce
    then Ok witness
    else Error Authority_identity_mismatch
  | error -> Error error
;;

let replace_settled_admitted ~base_path ~keeper_id ~source ~owner_id () =
  match replace ~base_path ~keeper_id ~source ~owner_id () with
  | Ok witness -> Ok (Settled_allocated witness)
  | Error
      (( Published_with_warnings _
       | Published_with_failure _
       | Publication_indeterminate _ ) as publication_error) ->
    settle_published_replace
      ~base_path
      ~keeper_id
      ~source
      ~owner_id
      publication_error
    |> Result.map (fun witness ->
      Settled_recovered (witness, Some publication_error))
  | Error Authority_identity_mismatch ->
    recover_published_replace ~base_path ~keeper_id ~source ()
    |> Result.map (fun witness -> Settled_recovered (witness, None))
  | Error error -> Error error
;;

let replace_settled permit ~base_path ~keeper_id ~source ~owner_id () =
  with_mutation_admission permit ~base_path ~keeper_id (fun () ->
    replace_settled_admitted
      ~base_path
      ~keeper_id
      ~source
      ~owner_id
      ())
;;

let runtime_int_of_nonce nonce =
  if
    Int64.compare nonce 0L <= 0
    || Int64.compare nonce runtime_max_nonce > 0
  then Error (Runtime_nonce_out_of_range nonce)
  else Ok (Int64.to_int nonce)
;;

let head_operation_to_string = function
  | Head.Pin_parent -> "pin_parent"
  | Open_lock -> "open_lock"
  | Acquire_cross_process_lock -> "acquire_cross_process_lock"
  | Read_lock_marker -> "read_lock_marker"
  | Initialize_lock_marker -> "initialize_lock_marker"
  | Read_head -> "read_head"
  | Create_stage -> "create_stage"
  | Write_stage -> "write_stage"
  | Sync_stage -> "sync_stage"
  | Close_stage -> "close_stage"
  | Revalidate -> "revalidate"
  | Rename_head -> "rename_head"
  | Sync_parent -> "sync_parent"
  | Verify_publication -> "verify_publication"
  | Cleanup_stage -> "cleanup_stage"
  | Settle_resources -> "settle_resources"
;;

let head_failure_to_string (failure : Head.failure) =
  match failure.error with
  | Head.Invalid_leaf detail -> "invalid leaf: " ^ detail
  | Invalid_row detail -> "invalid row: " ^ detail
  | Busy -> "authority is busy"
  | Conflict _ -> "authority changed concurrently"
  | Corrupt_lock detail -> "corrupt lock: " ^ detail
  | Corrupt_head detail -> "corrupt HEAD: " ^ detail
  | Unsupported detail -> "unsupported filesystem operation: " ^ detail
  | Io_error diagnostic ->
    Printf.sprintf
      "%s: %s"
      (head_operation_to_string diagnostic.operation)
      diagnostic.detail
;;

let corruption_to_string = function
  | Invalid_current _ ->
    "lifecycle nonce current evidence is invalid; operator reset is required"
;;

let error_to_string = function
  | Invalid_base_path path -> "lifecycle nonce base path is not absolute: " ^ path
  | Invalid_keeper_id ->
    "lifecycle nonce keeper_id must be non-empty and have no surrounding whitespace"
  | Invalid_owner_id -> "lifecycle nonce owner_id must be non-empty"
  | Invalid_floor floor ->
    Printf.sprintf
      "lifecycle nonce floor must be positive: %Ld"
      floor
  | Authority_missing -> "lifecycle nonce authority is missing"
  | Authority_identity_mismatch ->
    "lifecycle nonce authority identity does not match the exact request"
  | Lifecycle_admission_mismatch ->
    "lifecycle nonce mutation requires the active durable lifecycle admission"
  | Shutdown_floor_invalid detail ->
    "lifecycle nonce shutdown floor is invalid: " ^ detail
  | Filesystem_capability_unavailable ->
    "lifecycle nonce filesystem capability is unavailable"
  | Directory_prepare_failed detail ->
    "lifecycle nonce directory preparation failed: " ^ detail
  | Entropy_source_failed detail ->
    "lifecycle nonce entropy source failed: " ^ detail
  | Corrupt_current corruption -> corruption_to_string corruption
  | Head_read_failed failure ->
    "lifecycle nonce HEAD read failed: " ^ head_failure_to_string failure
  | Head_read_settlement_failed { observed_nonce; warnings; _ } ->
    Printf.sprintf
      "lifecycle nonce HEAD read retained cursor evidence but resource settlement \
       failed observed_nonce=%s warning_count=%d"
      (Option.fold ~none:"unknown" ~some:Int64.to_string observed_nonce)
      (List.length warnings)
  | Head_write_failed failure ->
    "lifecycle nonce HEAD write failed: " ^ head_failure_to_string failure
  | Contention_exhausted { attempts; last_failure } ->
    Printf.sprintf
      "lifecycle nonce HEAD contention exhausted after %d attempts: %s"
      attempts
      (head_failure_to_string last_failure)
  | Published_with_warnings { nonce; warnings; _ } ->
    Printf.sprintf
      "lifecycle nonce %Ld was published with %d settlement warning(s)"
      nonce
      (List.length warnings)
  | Published_with_failure { nonce; failure } ->
    Printf.sprintf
      "lifecycle nonce %Ld was published but the operation failed: %s"
      nonce
      (head_failure_to_string failure)
  | Publication_indeterminate { nonce; failure } ->
    Printf.sprintf
      "lifecycle nonce %Ld publication is indeterminate: %s"
      nonce
      (head_failure_to_string failure)
  | Nonce_exhausted -> "lifecycle nonce runtime metadata range is exhausted"
  | Runtime_nonce_out_of_range nonce ->
    Printf.sprintf
      "lifecycle nonce %Ld cannot be represented by runtime metadata"
      nonce
;;

module For_testing = struct
  type fault = replacement_fault =
    | Publication_settlement_warning
    | Verified_publication_failure
    | Publication_indeterminate
    | Cancellation_after_publication

  let root_path_for_base_path = root_path_for_base_path
  let authority_leaf = authority_leaf

  let with_fd_backed_parent_opening fn =
    Eio.Fiber.with_binding fd_backed_parent_opening_key () fn
  ;;

  let with_fault fault fn =
    Eio.Fiber.with_binding replacement_fault_key fault fn
  ;;
end
