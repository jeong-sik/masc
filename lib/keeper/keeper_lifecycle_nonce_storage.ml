module Head = Fs_compat.Capability_head

open Keeper_lifecycle_nonce_types

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

let runtime_max_nonce = Int64.of_int max_int

let next_value ~floor current =
  if Int64.compare floor runtime_max_nonce > 0
  then Error (Runtime_nonce_out_of_range floor)
  else if Int64.compare current runtime_max_nonce >= 0
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
    let current_nonce =
      Option.fold ~none:0L ~some:(fun (row : row) -> row.nonce) current
    in
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
  else if Int64.compare floor runtime_max_nonce > 0
  then Error (Runtime_nonce_out_of_range floor)
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
