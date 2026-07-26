open Keeper_dead_revival_payload_types
open Keeper_dead_revival_payload_domain

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
let payload_keeper_name (payload : payload) = payload.keeper_name
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

let immutable_ref_authority_leaf (reference : immutable_ref) =
  reference.authority_leaf
;;

let immutable_ref_transaction_leaf (reference : immutable_ref) =
  reference.transaction_leaf
;;

let immutable_ref_sha256 (reference : immutable_ref) = reference.sha256
let immutable_ref_byte_count (reference : immutable_ref) = reference.byte_count

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
