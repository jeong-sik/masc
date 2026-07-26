module Head = Fs_compat.Capability_head

let schema = "masc.keeper-lifecycle-nonce.v1"
let root_leaf = "keeper-lifecycle-nonces-v1"
let head_entropy_bytes = 32 * 33
let fd_backed_parent_opening_key : unit Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let with_head_parent parent fn =
  match Eio.Fiber.get fd_backed_parent_opening_key with
  | Some () -> Eio.Path.with_open_dir parent fn
  | None -> fn parent
;;

type corruption =
  | Invalid_current of string

type error =
  | Invalid_base_path of string
  | Invalid_keeper_id
  | Invalid_owner_id
  | Invalid_floor of int64
  | Authority_missing
  | Authority_identity_mismatch
  | Shutdown_floor_invalid of string
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Entropy_source_failed of string
  | Corrupt_current of corruption
  | Head_read_failed of Head.failure
  | Head_read_settlement_failed of
      { cursor : Head.cursor
      ; row : string option
      ; observed_nonce : int64 option
      ; warnings : Head.settlement_warning list
      }
  | Head_write_failed of Head.failure
  | Contention_exhausted of
      { attempts : int
      ; last_failure : Head.failure
      }
  | Published_with_warnings of
      { nonce : int64
      ; evidence : Head.publication_evidence
      ; warnings : Head.settlement_warning list
      }
  | Published_with_failure of
      { nonce : int64
      ; failure : Head.failure
      }
  | Publication_indeterminate of
      { nonce : int64
      ; failure : Head.failure
      }
  | Nonce_exhausted
  | Runtime_nonce_out_of_range of int64

type row =
  { keeper_id : string
  ; allocated_to : string
  ; nonce : int64
  ; source_owner_id : string option
  ; source_nonce : int64 option
  }

type identity =
  { owner_id : string
  ; nonce : int64
  }

type create
type replace
type recover_exact

type 'kind witness =
  { base_path : string
  ; keeper_id : string
  ; source : identity option
  ; target : identity
  }

let ( let* ) result fn =
  match result with
  | Ok value -> fn value
  | Error error -> Error error
;;

let sha256 value =
  Digestif.SHA256.(to_hex (digest_string value))
;;

let root_path_for_base_path ~base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    root_leaf
;;

let authority_leaf ~keeper_id =
  let identity =
    Printf.sprintf
      "keeper-lifecycle-nonce\000%d:%s"
      (String.length keeper_id)
      keeper_id
  in
  "nonce-" ^ sha256 identity ^ ".json"
;;

let payload_json (row : row) =
  `Assoc
    [ "schema", `String schema
    ; "keeper_id", `String row.keeper_id
    ; "allocated_to", `String row.allocated_to
    ; "nonce", `Intlit (Int64.to_string row.nonce)
    ; ( "source_owner_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) row.source_owner_id )
    ; ( "source_nonce"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `Intlit (Int64.to_string value))
          row.source_nonce )
    ]
;;

let payload_bytes (row : row) =
  Yojson.Safe.to_string (payload_json row)
;;

let checksum (row : row) =
  sha256 ("keeper-lifecycle-nonce-checksum-v1\000" ^ payload_bytes row)
;;

let row_bytes (row : row) =
  `Assoc
    [ "schema", `String schema
    ; "keeper_id", `String row.keeper_id
    ; "allocated_to", `String row.allocated_to
    ; "nonce", `Intlit (Int64.to_string row.nonce)
    ; ( "source_owner_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) row.source_owner_id )
    ; ( "source_nonce"
      , Option.fold
          ~none:`Null
          ~some:(fun value -> `Intlit (Int64.to_string value))
          row.source_nonce )
    ; "checksum_sha256", `String (checksum row)
    ]
  |> Yojson.Safe.to_string
;;

let exact_fields expected = function
  | `Assoc fields ->
    let actual =
      List.map fst fields
      |> List.sort String.compare
    in
    let expected = List.sort String.compare expected in
    if List.equal String.equal actual expected
    then Ok fields
    else
      Error
        (Invalid_current
           (Printf.sprintf
              "expected fields [%s], observed [%s]"
              (String.concat "," expected)
              (String.concat "," actual)))
  | _ -> Error (Invalid_current "current authority must be a JSON object")
;;

let required_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Invalid_current ("missing field " ^ name))
;;

let required_string name fields =
  let* value = required_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (Invalid_current (name ^ " must be a string"))
;;

let positive_int64 = function
  | `Int value when value > 0 -> Ok (Int64.of_int value)
  | `Intlit raw ->
    (match Int64.of_string_opt raw with
     | Some value
       when Int64.compare value 0L > 0
            && String.equal raw (Int64.to_string value) ->
       Ok value
     | Some _ | None ->
       Error
         (Invalid_current
            "nonce must be a canonical positive int64"))
  | _ ->
    Error
      (Invalid_current "nonce must be a canonical positive int64")
;;

let decode_row ~keeper_id raw =
  let parsed =
    try Ok (Yojson.Safe.from_string raw) with
    | Yojson.Json_error _ ->
      Error (Invalid_current "authority is not current canonical JSON")
  in
  let* json = parsed in
  let* fields =
    exact_fields
      [ "schema"
      ; "keeper_id"
      ; "allocated_to"
      ; "nonce"
      ; "source_owner_id"
      ; "source_nonce"
      ; "checksum_sha256"
      ]
      json
  in
  let* observed_schema = required_string "schema" fields in
  if not (String.equal observed_schema schema)
  then Error (Invalid_current "authority does not match the exact current schema")
  else
    let* observed_keeper = required_string "keeper_id" fields in
    let* allocated_to = required_string "allocated_to" fields in
    let* nonce_json = required_field "nonce" fields in
    let* nonce = positive_int64 nonce_json in
    let* source_owner_id_json = required_field "source_owner_id" fields in
    let* source_nonce_json = required_field "source_nonce" fields in
    let* source_owner_id, source_nonce =
      match source_owner_id_json, source_nonce_json with
      | `Null, `Null -> Ok (None, None)
      | `String owner_id, nonce_json ->
        let* nonce = positive_int64 nonce_json in
        if String.equal (String.trim owner_id) ""
        then Error (Invalid_current "source owner id is empty")
        else Ok (Some owner_id, Some nonce)
      | _ -> Error (Invalid_current "source identity is not an exact pair")
    in
    let* observed_checksum = required_string "checksum_sha256" fields in
    let observed : row =
      { keeper_id = observed_keeper
      ; allocated_to
      ; nonce
      ; source_owner_id
      ; source_nonce
      }
    in
    if not (String.equal observed_checksum (checksum observed))
    then Error (Invalid_current "authority checksum does not match")
    else if not (String.equal raw (row_bytes observed))
    then Error (Invalid_current "authority is not canonical")
    else if not (String.equal keeper_id observed_keeper)
    then
      Error (Invalid_current "authority keeper binding does not match")
    else Ok observed
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

let rec prepare_root ~base_path =
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_capability_unavailable
  | Some fs ->
    let ownership_root = Common.masc_dir_from_base_path ~base_path in
    let root_path = root_path_for_base_path ~base_path in
    (match
       Keeper_fs_durable_directory.ensure
         ~before_prepare:Fun.id
         ~before_directory_fsync:(fun _ -> ())
         ~ownership_root
         root_path
     with
     | Error failure ->
       Error (Directory_prepare_failed (directory_failure_to_string failure))
     | Ok lease ->
       if Keeper_fs_durable_directory.lease_is_current lease
       then Ok Eio.Path.(fs / root_path)
       else prepare_root ~base_path)
;;

let entropy_source () =
  try
    Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes))
  with
  | Eio.Cancel.Cancelled _ as exception_ -> raise exception_
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error (Entropy_source_failed (Printexc.to_string exception_))
;;

let yield_before_retry () =
  Eio.Fiber.check ();
  Eio.Fiber.yield ()
;;

let next_value ~floor current =
  if Int64.equal current Int64.max_int
  then Error Nonce_exhausted
  else
    let successor = Int64.succ current in
    Ok (if Int64.compare floor successor > 0 then floor else successor)
;;

let head_contention_retry_limit = 2

let observed_nonce ~keeper_id = function
  | None -> None
  | Some raw ->
    (match decode_row ~keeper_id raw with
     | Ok row -> Some row.nonce
     | Error _ -> None)
;;

let rec allocate
          ~snapshot_warnings
          ~compare_and_swap
          ~remaining_retries
          ~attempts
          ~root
          ~keeper_id
          ~owner_id
          ~expected_source
          ~floor
  =
  let retry failure =
    if remaining_retries = 0
    then Error (Contention_exhausted { attempts; last_failure = failure })
    else (
      yield_before_retry ();
      allocate
        ~snapshot_warnings
        ~compare_and_swap
        ~remaining_retries:(remaining_retries - 1)
        ~attempts:(attempts + 1)
        ~root
          ~keeper_id
          ~owner_id
          ~expected_source
          ~floor)
  in
  let leaf = authority_leaf ~keeper_id in
  let* read_entropy = entropy_source () in
  match
    with_head_parent root (fun parent ->
      Head.read ~secure_random:read_entropy ~parent ~leaf)
  with
  | Error failure when failure.error = Head.Busy ->
    retry failure
  | Error failure -> Error (Head_read_failed failure)
  | Ok snapshot ->
    let warnings = snapshot_warnings snapshot in
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
    let current =
      match Head.snapshot_row snapshot with
      | None -> Ok None
      | Some raw ->
        decode_row ~keeper_id raw
        |> Result.map Option.some
        |> Result.map_error (fun corruption -> Corrupt_current corruption)
    in
    let* current = current in
    let* () =
      match expected_source, current with
      | None, _ -> Ok ()
      | Some _, None -> Error Authority_missing
      | Some source, Some row
        when String.equal source.owner_id row.allocated_to
             && Int64.equal source.nonce row.nonce ->
        Ok ()
      | Some _, Some _ -> Error Authority_identity_mismatch
    in
    let current_nonce = Option.fold ~none:0L ~some:(fun row -> row.nonce) current in
    let* desired = next_value ~floor current_nonce in
    let desired_row : row =
      { keeper_id
      ; allocated_to = owner_id
      ; nonce = desired
      ; source_owner_id = Option.map (fun source -> source.owner_id) expected_source
      ; source_nonce = Option.map (fun source -> source.nonce) expected_source
      }
    in
    let* write_entropy = entropy_source () in
    (match
       with_head_parent root (fun parent ->
         compare_and_swap
           ~secure_random:write_entropy
           ~parent
           ~leaf
           ~expected:(Head.snapshot_cursor snapshot)
           ~row:(row_bytes desired_row))
     with
     | Ok publication ->
       let warnings = Head.publication_settlement_warnings publication in
       if warnings = []
       then Ok desired
       else
         Error
           (Published_with_warnings
              { nonce = desired
              ; evidence = Head.publication_evidence publication
              ; warnings
              })
     | Error (failure : Head.failure) ->
       (match failure.target_effect, failure.error with
        | Head.Unchanged, (Head.Busy | Head.Conflict _) ->
          retry failure
        | Head.Published _, _ ->
          Error (Published_with_failure { nonce = desired; failure })
        | Head.Publication_indeterminate _, _ ->
          Error (Publication_indeterminate { nonce = desired; failure })
        | Head.Unchanged, _ -> Error (Head_write_failed failure)))
;;

let next_for_base_path_with_hooks
      ~snapshot_warnings
      ~compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ?expected_source
      ?(floor = 1L)
      ()
  =
  if Filename.is_relative base_path
  then Error (Invalid_base_path base_path)
  else if
    String.equal (String.trim keeper_id) ""
    || not (String.equal keeper_id (String.trim keeper_id))
  then Error Invalid_keeper_id
  else if String.equal (String.trim owner_id) ""
  then Error Invalid_owner_id
  else if Int64.compare floor 0L <= 0
  then Error (Invalid_floor floor)
  else
    let* root = prepare_root ~base_path in
    allocate
      ~snapshot_warnings
      ~compare_and_swap
      ~remaining_retries:head_contention_retry_limit
      ~attempts:1
      ~root
      ~keeper_id
      ~owner_id
      ~expected_source
      ~floor
;;

let next_for_base_path ~base_path ~keeper_id ~owner_id ?floor () =
  next_for_base_path_with_hooks
    ~snapshot_warnings:Head.snapshot_settlement_warnings
    ~compare_and_swap:Head.compare_and_swap
    ~base_path
    ~keeper_id
    ~owner_id
    ?floor
    ()
;;

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
    if Int64.equal generation Int64.max_int
    then Error Nonce_exhausted
    else Ok (Int64.succ generation)
;;

let create ~base_path ~keeper_id ~owner_id () =
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

let replace ~base_path ~keeper_id ~source ~owner_id () =
  let floor =
    if Int64.equal source.nonce Int64.max_int
    then Error Nonce_exhausted
    else Ok (Int64.succ source.nonce)
  in
  let* floor = floor in
  let* nonce =
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap:Head.compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ~expected_source:source
      ~floor
      ()
  in
  Ok (witness_of_nonce ~base_path ~keeper_id ~source:(Some source) ~owner_id nonce)
;;

let recover_exact ~base_path ~keeper_id ~source ~target () =
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
           let reverse =
             match source, row_source with
             | Some current, Some original ->
               equal_identity current row_target && equal_identity target original
             | None, None | None, Some _ | Some _, None -> false
           in
           if forward || reverse
           then Ok { base_path; keeper_id; source; target }
           else Error Authority_identity_mismatch)
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

let runtime_int_of_nonce nonce =
  if
    Int64.compare nonce 0L <= 0
    || Int64.compare nonce (Int64.of_int max_int) > 0
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
  | Nonce_exhausted -> "lifecycle nonce int64 authority is exhausted"
  | Runtime_nonce_out_of_range nonce ->
    Printf.sprintf
      "lifecycle nonce %Ld cannot be represented by runtime metadata"
      nonce
;;

module For_testing = struct
  let root_path_for_base_path = root_path_for_base_path
  let authority_leaf = authority_leaf

  let with_fd_backed_parent_opening fn =
    Eio.Fiber.with_binding fd_backed_parent_opening_key () fn
  ;;

  let with_read_settlement_warning
        ~base_path
        ~keeper_id
        ~owner_id
        ?floor
        ()
    =
    let snapshot_warnings snapshot =
      Head.snapshot_settlement_warnings snapshot
      @ [ Head.Resource_settlement_failed
            { operation = Head.Settle_resources
            ; detail = "injected lifecycle nonce read settlement warning"
            }
        ]
    in
    next_for_base_path_with_hooks
      ~snapshot_warnings
      ~compare_and_swap:Head.compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ?floor
      ()
  ;;

  let with_publication_settlement_warning
        ~base_path
        ~keeper_id
        ~owner_id
        ?floor
        ()
    =
    let hooks =
      Head.For_testing.hooks
        ~on_resource_settlement:(fun () ->
          failwith "injected lifecycle nonce publication settlement warning")
        ()
    in
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap:(Head.For_testing.compare_and_swap hooks)
      ~base_path
      ~keeper_id
      ~owner_id
      ?floor
      ()
  ;;

  let with_published_failure
        ~base_path
        ~keeper_id
        ~owner_id
        ?floor
        ()
    =
    let hooks =
      Head.For_testing.hooks
        ~after_verified:(fun () ->
          failwith "injected lifecycle nonce post-publication failure")
        ()
    in
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap:(Head.For_testing.compare_and_swap hooks)
      ~base_path
      ~keeper_id
      ~owner_id
      ?floor
      ()
  ;;

  let with_forced_conflicts
        ~base_path
        ~keeper_id
        ~owner_id
        ?floor
        ()
    =
    let compare_and_swap ~secure_random ~parent ~leaf ~expected ~row =
      let competing_random =
        Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes)
      in
      match
        Head.compare_and_swap
          ~secure_random:competing_random
          ~parent
          ~leaf
          ~expected
          ~row
      with
      | Error failure -> Error failure
      | Ok _ ->
        Head.compare_and_swap
          ~secure_random
          ~parent
          ~leaf
          ~expected
          ~row
    in
    next_for_base_path_with_hooks
      ~snapshot_warnings:Head.snapshot_settlement_warnings
      ~compare_and_swap
      ~base_path
      ~keeper_id
      ~owner_id
      ?floor
      ()
  ;;
end
