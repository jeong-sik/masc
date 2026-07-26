type payload =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; original : Keeper_meta_contract.keeper_meta
  ; candidate : Keeper_meta_contract.keeper_meta
  }

type immutable_ref =
  { authority_leaf : string
  ; transaction_leaf : string
  ; sha256 : string
  ; byte_count : int64
  }

type prepared =
  { payload : payload
  ; reference : immutable_ref
  ; bytes : string
  }

type authority_shard =
  { keeper_name : string option
  ; authority_leaf : string
  }

type inventory_transaction =
  { inventory_authority_leaf : string
  ; inventory_transaction_leaf : string
  }

type create_outcome =
  | Created of prepared
  | Reconciled_created of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }

type create_reconciliation_failure =
  | Reconciliation_read_failed of
      Fs_compat.Capability_exact_read.failure
  | Reconciliation_read_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list
  | Reconciliation_read_injected of string
  | Reconciliation_parent_sync_failed of
      Fs_compat.capability_directory_sync_error
  | Reconciliation_parent_sync_injected of string

type error =
  | Invalid_binding of string
  | Malformed_payload of string
  | Unsupported_payload_schema of string
  | Noncanonical_payload
  | Malformed_ref of string
  | Unsupported_ref_schema of string
  | Noncanonical_ref
  | Filesystem_capability_unavailable
  | Directory_prepare_failed of string
  | Parent_open_failed of string
  | Create_conflict of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }
  | Create_unsettled of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      }
  | Create_reconciliation_failed of
      { prepared : prepared
      ; initial_failure : Fs_compat.capability_write_error
      ; reconciliation_failure : create_reconciliation_failure
      }
  | Read_failed of Fs_compat.Capability_exact_read.failure
  | Read_settlement_failed of
      Fs_compat.Capability_exact_read.settlement_warning list
  | Payload_digest_mismatch
  | Payload_binding_mismatch
  | Delete_failed of Keeper_fs.durable_remove_error
  | Inventory_failed of string

let payload_schema = "masc.keeper-dead-revival-payload.v1"
let ref_schema = "masc.keeper-dead-revival-payload-ref.v1"
let transaction_domain = "keeper-dead-revival-transaction-v1"
let payload_digest_domain = "masc.keeper-dead-revival-payload-digest.v1"
let transaction_leaf_domain =
  "masc.keeper-dead-revival-payload-transaction-leaf.v1"
;;

let authority_leaf_domain = "keeper-dead-revival-journal-leaf-v1"
let payload_root_leaf = "payloads"
let authority_leaf_prefix = "revival-"
let transaction_leaf_prefix = "transaction-"
let json_leaf_suffix = ".json"

type testing_boundary_decision =
  [ `Fail of string
  | `Use_production
  ]

type testing_hooks =
  { create_target_effect :
      Fs_compat.capability_write_target_effect option
  ; reconciliation_read : unit -> testing_boundary_decision
  ; parent_sync : unit -> testing_boundary_decision
  }

let testing_hooks_key : testing_hooks Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let ( let* ) result fn =
  match result with
  | Ok value -> fn value
  | Error error -> Error error
;;

let sha256 value =
  Digestif.SHA256.(digest_string value |> to_hex)
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
;;

let domain_digest domain values =
  domain :: values
  |> List.map length_delimited
  |> String.concat "\000"
  |> sha256
;;

let is_lowercase_sha256 value =
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest -> String.equal value (Digestif.SHA256.to_hex digest)
  | None -> false
;;

let exact_fields ~kind expected = function
  | `Assoc fields ->
    let expected = List.sort String.compare expected in
    let observed =
      List.map fst fields
      |> List.sort String.compare
    in
    if List.equal String.equal expected observed
    then Ok fields
    else
      Error
        (Printf.sprintf
           "%s fields differ expected=[%s] observed=[%s]"
           kind
           (String.concat "," expected)
           (String.concat "," observed))
  | _ -> Error (kind ^ " must be a JSON object")
;;

let required_field ~kind key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s field %s is missing" kind key)
;;

let required_string ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `String value when not (String.equal (String.trim value) "") -> Ok value
  | _ ->
    Error
      (Printf.sprintf
         "%s field %s must be a non-empty string"
         kind
         key)
;;

let required_int ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `Int value -> Ok value
  | _ -> Error (Printf.sprintf "%s field %s must be an integer" kind key)
;;

let required_positive_int64 ~kind key fields =
  let* value = required_field ~kind key fields in
  match value with
  | `Int value when value > 0 -> Ok (Int64.of_int value)
  | `Intlit raw ->
    (match Int64.of_string_opt raw with
     | Some value
       when Int64.compare value 0L > 0
            && String.equal raw (Int64.to_string value) ->
       Ok value
     | Some _ | None ->
       Error
         (Printf.sprintf
            "%s field %s must be a canonical positive int64"
            kind
            key))
  | _ ->
    Error
      (Printf.sprintf
         "%s field %s must be a canonical positive int64"
         kind
         key)
;;

let transaction_digest
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~candidate_nonce
  =
  [ transaction_domain
  ; length_delimited owner_id
  ; length_delimited keeper_name
  ; length_delimited
      (Keeper_id.Trace_id.to_string expected_trace_id)
  ; string_of_int expected_generation
  ; string_of_int candidate_nonce
  ]
  |> String.concat "\000"
  |> sha256
;;

let validate_payload (payload : payload) =
  if String.equal (String.trim payload.transaction_id) ""
  then Error (Invalid_binding "transaction_id must be non-empty")
  else if not (is_lowercase_sha256 payload.transaction_id)
  then Error (Invalid_binding "transaction_id must be a lowercase SHA-256")
  else if String.equal (String.trim payload.owner_id) ""
  then Error (Invalid_binding "owner_id must be non-empty")
  else if String.equal (String.trim payload.keeper_name) ""
  then Error (Invalid_binding "keeper_name must be non-empty")
  else if payload.expected_generation < 0
  then Error (Invalid_binding "expected_generation must be non-negative")
  else if
    not (String.equal payload.original.name payload.keeper_name)
    || not (String.equal payload.candidate.name payload.keeper_name)
  then Error (Invalid_binding "metadata does not match keeper_name")
  else if
    not
      (Keeper_id.Trace_id.equal
         payload.original.runtime.trace_id
         payload.expected_trace_id)
  then Error (Invalid_binding "original metadata does not match expected_trace_id")
  else if
    not
      (Int.equal
         payload.original.runtime.nonce
         payload.expected_generation)
  then Error (Invalid_binding "original metadata does not match expected_generation")
  else if
    not
      (Keeper_id.Trace_id.equal
         payload.candidate.runtime.trace_id
         payload.expected_trace_id)
  then Error (Invalid_binding "candidate metadata does not preserve expected_trace_id")
  else if payload.candidate.runtime.nonce <= payload.expected_generation
  then
    Error
      (Invalid_binding
         "candidate lifecycle nonce must advance expected_generation")
  else
    let expected_transaction_id =
      transaction_digest
        ~owner_id:payload.owner_id
        ~keeper_name:payload.keeper_name
        ~expected_trace_id:payload.expected_trace_id
        ~expected_generation:payload.expected_generation
        ~candidate_nonce:payload.candidate.runtime.nonce
    in
    if not (String.equal payload.transaction_id expected_transaction_id)
    then
      Error
        (Invalid_binding
           "transaction_id does not bind owner and lifecycle metadata")
    else Ok ()
;;

let make_payload
      ~transaction_id
      ~owner_id
      ~keeper_name
      ~expected_trace_id
      ~expected_generation
      ~original
      ~candidate
  =
  let payload =
    { transaction_id
    ; owner_id
    ; keeper_name
    ; expected_trace_id
    ; expected_generation
    ; original
    ; candidate
    }
  in
  let* () = validate_payload payload in
  Ok payload
;;

let payload_to_json payload =
  `Assoc
    [ "schema", `String payload_schema
    ; "transaction_id", `String payload.transaction_id
    ; "owner_id", `String payload.owner_id
    ; "keeper_name", `String payload.keeper_name
    ; ( "expected_trace_id"
      , `String
          (Keeper_id.Trace_id.to_string payload.expected_trace_id) )
    ; "expected_generation", `Int payload.expected_generation
    ; "original", Keeper_meta_json.meta_to_json payload.original
    ; "candidate", Keeper_meta_json.meta_to_json payload.candidate
    ]
;;

let payload_to_bytes payload =
  Yojson.Safe.to_string (payload_to_json payload)
;;

let payload_of_json json =
  let malformed detail = Error (Malformed_payload detail) in
  let* fields =
    exact_fields
      ~kind:"revival payload"
      [ "schema"
      ; "transaction_id"
      ; "owner_id"
      ; "keeper_name"
      ; "expected_trace_id"
      ; "expected_generation"
      ; "original"
      ; "candidate"
      ]
      json
    |> Result.map_error (fun detail -> Malformed_payload detail)
  in
  let* schema =
    required_string ~kind:"revival payload" "schema" fields
    |> Result.map_error (fun detail -> Malformed_payload detail)
  in
  if not (String.equal schema payload_schema)
  then Error (Unsupported_payload_schema schema)
  else
    let* transaction_id =
      required_string ~kind:"revival payload" "transaction_id" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* owner_id =
      required_string ~kind:"revival payload" "owner_id" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* keeper_name =
      required_string ~kind:"revival payload" "keeper_name" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* trace_id_raw =
      required_string ~kind:"revival payload" "expected_trace_id" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* expected_trace_id =
      Keeper_id.Trace_id.of_string trace_id_raw
      |> Result.map_error (fun detail ->
        Malformed_payload ("invalid expected_trace_id: " ^ detail))
    in
    let* expected_generation =
      required_int ~kind:"revival payload" "expected_generation" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* original_json =
      required_field ~kind:"revival payload" "original" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* original =
      Keeper_meta_json.meta_of_json original_json
      |> Result.map_error (fun detail ->
        Malformed_payload ("invalid original metadata: " ^ detail))
    in
    let* candidate_json =
      required_field ~kind:"revival payload" "candidate" fields
      |> Result.map_error (fun detail -> Malformed_payload detail)
    in
    let* candidate =
      Keeper_meta_json.meta_of_json candidate_json
      |> Result.map_error (fun detail ->
        Malformed_payload ("invalid candidate metadata: " ^ detail))
    in
    match
      make_payload
        ~transaction_id
        ~owner_id
        ~keeper_name
        ~expected_trace_id
        ~expected_generation
        ~original
        ~candidate
    with
    | Ok payload -> Ok payload
    | Error (Invalid_binding detail) -> malformed detail
    | Error error -> Error error
;;

let payload_of_bytes raw =
  let parsed =
    try Ok (Yojson.Safe.from_string raw) with
    | Yojson.Json_error detail -> Error (Malformed_payload detail)
  in
  let* json = parsed in
  let* payload = payload_of_json json in
  if String.equal raw (payload_to_bytes payload)
  then Ok payload
  else Error Noncanonical_payload
;;

let payload_transaction_id payload = payload.transaction_id
let payload_owner_id payload = payload.owner_id
let payload_keeper_name payload = payload.keeper_name
let payload_expected_trace_id payload = payload.expected_trace_id
let payload_expected_generation payload = payload.expected_generation
let payload_original payload = payload.original
let payload_candidate payload = payload.candidate

let payload_digest bytes =
  domain_digest payload_digest_domain [ bytes ]
;;

let transaction_leaf_for_id ~transaction_id =
  let* () =
    if is_lowercase_sha256 transaction_id
    then Ok ()
    else Error (Invalid_binding "transaction digest must be a lowercase SHA-256")
  in
  Ok
    (transaction_leaf_prefix
     ^ domain_digest
         transaction_leaf_domain
         [ transaction_id ]
     ^ json_leaf_suffix)
;;

let valid_digest_leaf ~prefix leaf =
  let prefix_length = String.length prefix in
  let suffix_length = String.length json_leaf_suffix in
  let expected_length = prefix_length + 64 + suffix_length in
  String.length leaf = expected_length
  && String.starts_with ~prefix leaf
  && String.ends_with ~suffix:json_leaf_suffix leaf
  && is_lowercase_sha256 (String.sub leaf prefix_length 64)
;;

let canonical_authority_leaf keeper_name =
  authority_leaf_prefix
  ^ sha256
      (authority_leaf_domain
       ^ "\000"
       ^ length_delimited keeper_name)
  ^ json_leaf_suffix
;;

let valid_authority_leaf =
  valid_digest_leaf ~prefix:authority_leaf_prefix
;;

let valid_transaction_leaf =
  valid_digest_leaf ~prefix:transaction_leaf_prefix
;;

let immutable_ref_to_json (reference : immutable_ref) =
  `Assoc
    [ "schema", `String ref_schema
    ; "authority_leaf", `String reference.authority_leaf
    ; "transaction_leaf", `String reference.transaction_leaf
    ; "sha256", `String reference.sha256
    ; "byte_count", `Intlit (Int64.to_string reference.byte_count)
    ]
;;

let immutable_ref_to_bytes reference =
  Yojson.Safe.to_string (immutable_ref_to_json reference)
;;

let immutable_ref_of_json json =
  let* fields =
    exact_fields
      ~kind:"revival payload ref"
      [ "schema"
      ; "authority_leaf"
      ; "transaction_leaf"
      ; "sha256"
      ; "byte_count"
      ]
      json
    |> Result.map_error (fun detail -> Malformed_ref detail)
  in
  let* schema =
    required_string ~kind:"revival payload ref" "schema" fields
    |> Result.map_error (fun detail -> Malformed_ref detail)
  in
  if not (String.equal schema ref_schema)
  then Error (Unsupported_ref_schema schema)
  else
    let* authority_leaf =
      required_string
        ~kind:"revival payload ref"
        "authority_leaf"
        fields
      |> Result.map_error (fun detail -> Malformed_ref detail)
    in
    let* transaction_leaf =
      required_string
        ~kind:"revival payload ref"
        "transaction_leaf"
        fields
      |> Result.map_error (fun detail -> Malformed_ref detail)
    in
    let* sha256 =
      required_string ~kind:"revival payload ref" "sha256" fields
      |> Result.map_error (fun detail -> Malformed_ref detail)
    in
    let* byte_count =
      required_positive_int64
        ~kind:"revival payload ref"
        "byte_count"
        fields
      |> Result.map_error (fun detail -> Malformed_ref detail)
    in
    if not (valid_authority_leaf authority_leaf)
    then Error (Malformed_ref "authority_leaf is not a canonical revival authority leaf")
    else if not (valid_transaction_leaf transaction_leaf)
    then
      Error
        (Malformed_ref
           "transaction_leaf is not a canonical revival transaction leaf")
    else if not (is_lowercase_sha256 sha256)
    then Error (Malformed_ref "sha256 must be a lowercase SHA-256")
    else Ok { authority_leaf; transaction_leaf; sha256; byte_count }
;;

let immutable_ref_of_bytes raw =
  let parsed =
    try Ok (Yojson.Safe.from_string raw) with
    | Yojson.Json_error detail -> Error (Malformed_ref detail)
  in
  let* json = parsed in
  let* reference = immutable_ref_of_json json in
  if String.equal raw (immutable_ref_to_bytes reference)
  then Ok reference
  else Error Noncanonical_ref
;;

let immutable_ref_authority_leaf reference = reference.authority_leaf
let immutable_ref_transaction_leaf reference = reference.transaction_leaf
let immutable_ref_sha256 reference = reference.sha256
let immutable_ref_byte_count reference = reference.byte_count

let authority_shard_for_keeper ~keeper_name =
  if String.equal (String.trim keeper_name) ""
  then Error (Invalid_binding "keeper_name must be non-empty")
  else
    Ok
      { keeper_name = Some keeper_name
      ; authority_leaf = canonical_authority_leaf keeper_name
      }
;;

let authority_shard_leaf shard = shard.authority_leaf

let authority_shard_matches_keeper shard ~keeper_name =
  String.equal
    shard.authority_leaf
    (canonical_authority_leaf keeper_name)
;;

let prepare payload =
  let* () = validate_payload payload in
  let* transaction_leaf =
    transaction_leaf_for_id ~transaction_id:payload.transaction_id
  in
  let bytes = payload_to_bytes payload in
  let reference =
    { authority_leaf = canonical_authority_leaf payload.keeper_name
    ; transaction_leaf
    ; sha256 = payload_digest bytes
    ; byte_count = Int64.of_int (String.length bytes)
    }
  in
  Ok { payload; reference; bytes }
;;

let prepared_payload prepared = prepared.payload
let prepared_ref prepared = prepared.reference

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
  | Observation_injected_read_failed of string

let observe_reference
      ?(for_reconciliation = false)
      ~parent
      reference
  =
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
  match Eio.Fiber.get testing_hooks_key with
  | Some hooks when for_reconciliation ->
    (match hooks.reconciliation_read () with
     | `Fail detail -> Error (Observation_injected_read_failed detail)
     | `Use_production -> observe ())
  | None | Some _ -> observe ()
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
            observe_reference
              ~for_reconciliation:true
              ~parent
              reference
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
          | Error (Observation_read_failed failure) ->
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
          | Error (Observation_settlement_failed warnings) ->
            Error
              (Create_reconciliation_failed
                 { prepared
                 ; initial_failure
                 ; reconciliation_failure =
                     Reconciliation_read_settlement_failed warnings
                 }))
          | Error (Observation_injected_read_failed detail) ->
            Error
              (Create_reconciliation_failed
                 { prepared
                 ; initial_failure
                 ; reconciliation_failure =
                     Reconciliation_read_injected detail
                 })))
;;

let validate_reference reference =
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

let real_directory path =
  try
    match
      (Eio_guard.run_in_systhread (fun () -> Unix.lstat path)).Unix.st_kind
    with
    | Unix.S_DIR -> Ok true
    | _ -> Error (Inventory_failed ("inventory entry is not a real directory: " ^ path))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error
      (Inventory_failed
         ("inventory directory inspection failed: "
          ^ Printexc.to_string exception_))
;;

let inventory_authority_shards config =
  let root = payload_directory config in
  let* root_exists = real_directory root in
  if not root_exists
  then Ok []
  else
    match Safe_ops.list_dir_safe root with
    | Error detail -> Error (Inventory_failed detail)
    | Ok names ->
      let rec collect accumulated = function
        | [] ->
          Ok
            (List.sort
               (fun left right ->
                  String.compare
                    left.authority_leaf
                    right.authority_leaf)
               accumulated)
        | name :: rest ->
          if not (valid_authority_leaf name)
          then
            Error
              (Inventory_failed
                 ("unexpected non-authority entry in payload root: "
                  ^ name))
          else
            let path = Filename.concat root name in
            let* is_directory = real_directory path in
            if not is_directory
            then
              Error
                (Inventory_failed
                   ("authority shard disappeared during inventory: "
                    ^ name))
            else
              collect
                ({ keeper_name = None; authority_leaf = name }
                 :: accumulated)
                rest
      in
      collect [] names
;;

let inventory_transactions config shard =
  if not (authority_shard_is_valid shard)
  then Error (Invalid_binding "authority shard is not canonical")
  else
    let directory =
      payload_shard_directory config shard.authority_leaf
    in
    let* directory_exists = real_directory directory in
    if not directory_exists
    then Ok []
    else
      match Safe_ops.list_dir_safe directory with
      | Error detail -> Error (Inventory_failed detail)
      | Ok names ->
      let rec collect accumulated = function
        | [] ->
          Ok
            (List.sort
               (fun left right ->
                  String.compare
                    left.inventory_transaction_leaf
                    right.inventory_transaction_leaf)
               accumulated)
        | name :: rest ->
          if valid_transaction_leaf name
          then
            collect
              ({ inventory_authority_leaf = shard.authority_leaf
               ; inventory_transaction_leaf = name
               }
               :: accumulated)
              rest
          else
            Error
              (Inventory_failed
                 ("unexpected non-transaction entry in authority shard: "
                  ^ name))
      in
      collect [] names
;;

let inventory_transaction_matches inventory ~transaction_id =
  match transaction_leaf_for_id ~transaction_id with
  | Error _ -> false
  | Ok expected ->
    String.equal inventory.inventory_transaction_leaf expected
;;

let delete_inventory_transaction
      config
      ~authority_shard
      inventory
  =
  if
    not (authority_shard_is_valid authority_shard)
    || not
         (String.equal
            inventory.inventory_authority_leaf
            authority_shard.authority_leaf)
    || not
         (valid_transaction_leaf
            inventory.inventory_transaction_leaf)
  then Error (Invalid_binding "inventory transaction is not bound to authority shard")
  else
    let directory =
      payload_shard_directory config authority_shard.authority_leaf
    in
    let path =
      Filename.concat
        directory
        inventory.inventory_transaction_leaf
    in
    Keeper_fs.remove_file_durable
      ~ownership_root:(Workspace.masc_root_dir config)
      path
    |> Result.map_error (fun failure -> Delete_failed failure)
;;

let exact_read_operation_to_string = function
  | Fs_compat.Capability_exact_read.Pin_parent -> "pin_parent"
  | Open_parent_descriptor -> "open_parent_descriptor"
  | Open_leaf -> "open_leaf"
  | Inspect_opened -> "inspect_opened"
  | Allocate -> "allocate"
  | Read_exact -> "read_exact"
  | Inspect_after_read -> "inspect_after_read"
  | Close_leaf -> "close_leaf"
  | Settle_parent_resources -> "settle_parent_resources"
  | Observe_parent_cancellation -> "observe_parent_cancellation"
;;

let exact_read_error_to_string = function
  | Fs_compat.Capability_exact_read.Invalid_leaf detail ->
    "invalid leaf: " ^ detail
  | Invalid_length_bounds { expected_length; max_length } ->
    Printf.sprintf
      "invalid length bounds expected=%Ld max=%Ld"
      expected_length
      max_length
  | Length_not_representable length ->
    Printf.sprintf "length is not representable: %Ld" length
  | Cancelled diagnostic ->
    Printf.sprintf
      "%s cancelled: %s"
      (exact_read_operation_to_string diagnostic.operation)
      diagnostic.detail
  | Parent_descriptor_unavailable ->
    "parent descriptor is unavailable"
  | Missing -> "payload is missing"
  | Symbolic_link -> "payload is a symbolic link"
  | Not_regular _ -> "payload is not a regular file"
  | Unsafe_link_count count ->
    Printf.sprintf "payload has unsafe link count: %d" count
  | Unsafe_mode mode ->
    Printf.sprintf "payload has unsafe mode: 0o%o" mode
  | Length_exceeds_max { max_length; observed_length } ->
    Printf.sprintf
      "payload length exceeds representation limit max=%Ld observed=%Ld"
      max_length
      observed_length
  | Length_mismatch { expected_length; observed_length } ->
    Printf.sprintf
      "payload length mismatch expected=%Ld observed=%Ld"
      expected_length
      observed_length
  | Changed_during_read -> "payload changed during read"
  | Io_error diagnostic ->
    Printf.sprintf
      "%s failed: %s"
      (exact_read_operation_to_string diagnostic.operation)
      diagnostic.detail
;;

let create_reconciliation_failure_to_string = function
  | Reconciliation_read_failed failure ->
    "exact reread failed: "
    ^ exact_read_error_to_string failure.error
  | Reconciliation_read_settlement_failed warnings ->
    Printf.sprintf
      "exact reread settlement failed warning_count=%d"
      (List.length warnings)
  | Reconciliation_read_injected detail ->
    "exact reread injected failure: " ^ detail
  | Reconciliation_parent_sync_failed failure ->
    "parent durability sync failed: "
    ^ Fs_compat.capability_directory_sync_error_to_string failure
  | Reconciliation_parent_sync_injected detail ->
    "parent durability sync injected failure: " ^ detail
;;

let error_to_string = function
  | Invalid_binding detail -> "invalid revival payload binding: " ^ detail
  | Malformed_payload detail -> "malformed revival payload: " ^ detail
  | Unsupported_payload_schema schema ->
    "unsupported revival payload schema: " ^ schema
  | Noncanonical_payload -> "revival payload is not exact canonical JSON"
  | Malformed_ref detail -> "malformed revival payload ref: " ^ detail
  | Unsupported_ref_schema schema ->
    "unsupported revival payload ref schema: " ^ schema
  | Noncanonical_ref -> "revival payload ref is not exact canonical JSON"
  | Filesystem_capability_unavailable ->
    "revival payload filesystem capability is unavailable"
  | Directory_prepare_failed detail ->
    "revival payload directory preparation failed: " ^ detail
  | Parent_open_failed detail ->
    "revival payload parent open failed: " ^ detail
  | Create_conflict { initial_failure; _ } ->
    "revival payload create found conflicting immutable bytes after: "
    ^ Fs_compat.capability_write_error_to_string initial_failure
  | Create_unsettled { initial_failure; _ } ->
    "revival payload create left an unsettled target requiring cleanup: "
    ^ Fs_compat.capability_write_error_to_string initial_failure
  | Create_reconciliation_failed
      { initial_failure; reconciliation_failure; _ } ->
    "revival payload create reconciliation failed after "
    ^ Fs_compat.capability_write_error_to_string initial_failure
    ^ ": "
    ^ create_reconciliation_failure_to_string
        reconciliation_failure
  | Read_failed failure ->
    "revival payload read failed: "
    ^ exact_read_error_to_string failure.error
  | Read_settlement_failed warnings ->
    Printf.sprintf
      "revival payload read settlement failed warning_count=%d"
      (List.length warnings)
  | Payload_digest_mismatch -> "revival payload digest mismatch"
  | Payload_binding_mismatch -> "revival payload binding mismatch"
  | Delete_failed failure ->
    "revival payload delete failed: "
    ^ Keeper_fs.durable_remove_error_to_string failure
  | Inventory_failed detail ->
    "revival payload inventory failed: " ^ detail
;;

module For_testing = struct
  type nonrec hooks = testing_hooks

  let hooks
      ?create_target_effect
      ?(reconciliation_read = fun () -> `Use_production)
      ?(parent_sync = fun () -> `Use_production)
      ()
    =
    { create_target_effect
    ; reconciliation_read
    ; parent_sync
    }
  ;;

  let with_hooks hooks fn =
    Eio.Fiber.with_binding testing_hooks_key hooks fn
  ;;
end
