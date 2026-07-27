open Alcotest
open Test_keeper_dead_revival_payload_support

let test_canonical_codec_and_domain_bindings () =
  with_workspace "masc_dead_revival_payload_codec_" @@ fun config ->
  let fixture = make_fixture config in
  let bytes = Payload.payload_to_bytes fixture.payload in
  let payload_fields =
    parse_json "canonical payload" bytes
    |> assoc_fields "canonical payload"
  in
  check
    (list string)
    "payload exact field order"
    [ "schema"
    ; "transaction_id"
    ; "owner_id"
    ; "keeper_name"
    ; "expected_trace_id"
    ; "expected_generation"
    ; "original"
    ; "candidate"
    ]
    (List.map fst payload_fields);
  let decoded =
    Payload.payload_of_bytes bytes
    |> require_payload_ok "decode canonical payload"
  in
  check_payload "payload roundtrip" fixture decoded;
  check
    string
    "payload canonical re-encoding"
    bytes
    (Payload.payload_to_bytes decoded);
  let extra_payload =
    `Assoc (payload_fields @ [ "unexpected", `Null ])
    |> Yojson.Safe.to_string
  in
  Payload.payload_of_bytes extra_payload
  |> expect_error
       "reject extra payload field"
       (function Payload.Malformed_payload _ -> true | _ -> false);
  let missing_payload =
    `Assoc
      (List.filter
         (fun (name, _) -> not (String.equal name "candidate"))
         payload_fields)
    |> Yojson.Safe.to_string
  in
  Payload.payload_of_bytes missing_payload
  |> expect_error
       "reject missing payload field"
       (function Payload.Malformed_payload _ -> true | _ -> false);
  Payload.payload_of_bytes (bytes ^ "\n")
  |> expect_error
       "reject noncanonical payload bytes"
       (function Payload.Noncanonical_payload -> true | _ -> false);
  let reference = fixture.reference in
  let reference_json = Payload.immutable_ref_to_json reference in
  let reference_fields = assoc_fields "canonical ref" reference_json in
  check
    (list string)
    "ref exact field order"
    [ "schema"
    ; "authority_leaf"
    ; "transaction_leaf"
    ; "sha256"
    ; "byte_count"
    ]
    (List.map fst reference_fields);
  let reference_bytes = Payload.immutable_ref_to_bytes reference in
  let decoded_ref =
    Payload.immutable_ref_of_bytes reference_bytes
    |> require_payload_ok "decode canonical ref"
  in
  check_reference "ref roundtrip" reference decoded_ref;
  check
    string
    "ref canonical re-encoding"
    reference_bytes
    (Payload.immutable_ref_to_bytes decoded_ref);
  Payload.immutable_ref_of_json
    (`Assoc (reference_fields @ [ "unexpected", `Null ]))
  |> expect_error
       "reject extra ref field"
       (function Payload.Malformed_ref _ -> true | _ -> false);
  Payload.immutable_ref_of_bytes (reference_bytes ^ "\n")
  |> expect_error
       "reject noncanonical ref bytes"
       (function Payload.Noncanonical_ref -> true | _ -> false);
  Payload.immutable_ref_of_json
    (replace_json_fields
       [ "sha256", `String ("A" ^ String.make 63 '0') ]
       reference_json)
  |> expect_error
       "reject uppercase ref digest"
       (function Payload.Malformed_ref _ -> true | _ -> false);
  check
    string
    "keeper-derived authority leaf"
    (independent_authority_leaf fixture.keeper_name)
    fixture.authority_leaf;
  check
    string
    "prepared ref authority"
    fixture.authority_leaf
    (Payload.immutable_ref_authority_leaf reference);
  check
    string
    "domain-separated transaction leaf"
    (independent_transaction_leaf fixture.transaction_id)
    (Payload.immutable_ref_transaction_leaf reference);
  check
    string
    "domain-separated payload digest"
    (independent_payload_digest bytes)
    (Payload.immutable_ref_sha256 reference);
  check
    bool
    "digest is not raw payload SHA"
    false
    (String.equal
       (sha256 bytes)
       (Payload.immutable_ref_sha256 reference));
  check
    int64
    "prepared byte count"
    (Int64.of_int (String.length bytes))
    (Payload.immutable_ref_byte_count reference);
  check
    bool
    "authority shard matches keeper"
    true
    (Payload.authority_shard_matches_keeper
       fixture.authority_shard
       ~keeper_name:fixture.keeper_name);
  check
    bool
    "authority shard rejects another keeper"
    false
    (Payload.authority_shard_matches_keeper
       fixture.authority_shard
       ~keeper_name:"another-keeper");
  check
    string
    "prepared payload is exact"
    bytes
    (Payload.prepared_payload fixture.prepared
     |> Payload.payload_to_bytes)
;;

let test_candidate_lifecycle_binding_rejections () =
  with_workspace "masc_dead_revival_payload_candidate_" @@ fun config ->
  let fixture = make_fixture config in
  let changed_trace =
    trace_id_of_string "trace-dead-revival-payload-replacement"
  in
  let candidate_with_changed_trace =
    { fixture.candidate with
      runtime =
        { fixture.candidate.runtime with trace_id = changed_trace }
    }
  in
  Payload.make_payload
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
    ~runtime_transition:Payload.Runtime_unchanged
    ~original:fixture.original
    ~candidate:candidate_with_changed_trace
  |> expect_error
       "candidate trace must be preserved"
       (function Payload.Invalid_binding _ -> true | _ -> false);
  let reject_nonce nonce label =
    let candidate =
      { fixture.candidate with
        runtime = { fixture.candidate.runtime with nonce }
      }
    in
    let transaction_id =
      independent_transaction_id
        ~owner_id:fixture.owner_id
        ~keeper_name:fixture.keeper_name
        ~expected_trace_id:fixture.expected_trace_id
        ~expected_generation:fixture.expected_generation
        ~candidate_nonce:nonce
    in
    Payload.make_payload
      ~transaction_id
      ~owner_id:fixture.owner_id
      ~keeper_name:fixture.keeper_name
      ~expected_trace_id:fixture.expected_trace_id
      ~expected_generation:fixture.expected_generation
      ~runtime_transition:Payload.Runtime_unchanged
      ~original:fixture.original
      ~candidate
    |> expect_error
         label
         (function Payload.Invalid_binding _ -> true | _ -> false)
  in
  reject_nonce fixture.expected_generation "candidate nonce must advance";
  reject_nonce
    (fixture.expected_generation - 1)
    "candidate nonce must not move backward";
  let zero_generation = 0 in
  let original =
    { fixture.original with
      runtime = { fixture.original.runtime with nonce = zero_generation }
    }
  in
  let candidate =
    { fixture.candidate with
      runtime = { fixture.candidate.runtime with nonce = zero_generation + 1 }
    }
  in
  let transaction_id =
    independent_transaction_id
      ~owner_id:fixture.owner_id
      ~keeper_name:fixture.keeper_name
      ~expected_trace_id:fixture.expected_trace_id
      ~expected_generation:zero_generation
      ~candidate_nonce:candidate.runtime.nonce
  in
  Payload.make_payload
    ~transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:zero_generation
    ~runtime_transition:Payload.Runtime_unchanged
    ~original
    ~candidate
  |> expect_error
       "expected generation must be strictly positive"
       (function
         | Payload.Invalid_binding
             "expected_generation must be strictly positive" -> true
         | _ -> false);
  let uppercase_transaction_id =
    "A" ^ String.sub fixture.transaction_id 1 63
  in
  Payload.make_payload
    ~transaction_id:uppercase_transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
    ~runtime_transition:Payload.Runtime_unchanged
    ~original:fixture.original
    ~candidate:fixture.candidate
  |> expect_error
       "transaction id must be lowercase"
       (function Payload.Invalid_binding _ -> true | _ -> false)
;;
