open Alcotest
open Test_keeper_dead_revival_payload_support

let test_decode_only_read () =
  with_workspace "masc_dead_revival_payload_decode_" @@ fun config ->
  let first =
    make_fixture ~candidate_instructions:"candidate-a" config
  in
  let replacement =
    make_fixture ~candidate_instructions:"candidate-b" config
  in
  ignore (create_first first);
  let replacement_bytes =
    Payload.payload_to_bytes replacement.payload
  in
  write_file
    (payload_path first first.reference)
    replacement_bytes;
  let observed =
    read_bound replacement replacement.reference
    |> require_payload_ok "decode bound canonical replacement"
  in
  check_payload "decode-only read" replacement observed;
  check
    string
    "decode-only read returns stored candidate"
    "candidate-b"
    (Payload.payload_candidate observed).instructions
;;

let test_read_failures () =
  with_workspace "masc_dead_revival_payload_read_failures_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let byte_count =
    Payload.immutable_ref_byte_count fixture.reference
  in
  let length_ref =
    reference_with
      fixture
      [ ( "byte_count"
        , `Intlit (Int64.succ byte_count |> Int64.to_string) )
      ]
  in
  read_bound fixture length_ref
  |> expect_error "read length mismatch" is_length_mismatch;
  let wrong_digest =
    let zero = String.make 64 '0' in
    if String.equal
         zero
         (Payload.immutable_ref_sha256 fixture.reference)
    then String.make 64 '1'
    else zero
  in
  let digest_ref =
    reference_with fixture [ "sha256", `String wrong_digest ]
  in
  read_bound fixture digest_ref
  |> expect_error
       "read digest mismatch"
       (function Payload.Payload_digest_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:"hostile-owner"
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read owner binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:(trace_id_of_string "trace-hostile-reader")
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read trace binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:(fixture.expected_generation + 1)
  |> expect_error
       "read generation binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  let other_transaction =
    make_fixture ~candidate_nonce:9 config
  in
  Payload.read
    config
    ~expected_ref:other_transaction.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read transaction ref binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  let other_keeper =
    make_fixture ~keeper_name:"hostile-swapped-keeper" config
  in
  Payload.read
    config
    ~expected_ref:other_keeper.reference
    ~expected_authority_leaf:fixture.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read authority ref binding"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  Payload.read
    config
    ~expected_ref:fixture.reference
    ~expected_authority_leaf:other_keeper.authority_leaf
    ~transaction_id:fixture.transaction_id
    ~owner_id:fixture.owner_id
    ~keeper_name:fixture.keeper_name
    ~expected_trace_id:fixture.expected_trace_id
    ~expected_generation:fixture.expected_generation
  |> expect_error
       "read caller authority binding"
       (function Payload.Invalid_binding _ -> true | _ -> false)
;;

let test_read_rejects_noncanonical_stored_bytes () =
  with_workspace "masc_dead_revival_payload_noncanonical_" @@ fun config ->
  let fixture = make_fixture config in
  ignore (create_first fixture);
  let noncanonical =
    Payload.payload_to_bytes fixture.payload ^ "\n"
  in
  write_file
    (payload_path fixture fixture.reference)
    noncanonical;
  let adjusted_ref =
    reference_with
      fixture
      [ ( "byte_count"
        , `Intlit
            (Int64.of_int (String.length noncanonical)
             |> Int64.to_string) )
      ; "sha256", `String (independent_payload_digest noncanonical)
      ]
  in
  read_bound fixture adjusted_ref
  |> expect_error
       "read rejects noncanonical stored bytes"
       (function Payload.Noncanonical_payload -> true | _ -> false)
;;

let test_transaction_bound_idempotent_delete () =
  with_workspace "masc_dead_revival_payload_delete_" @@ fun config ->
  let first = make_fixture config in
  let second = make_fixture ~candidate_nonce:9 config in
  ignore (create_first first);
  ignore (create_first second);
  let first_path = payload_path first first.reference in
  let second_path = payload_path second second.reference in
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    second.reference
  |> expect_error
       "hostile swapped ref delete"
       (function Payload.Payload_binding_mismatch -> true | _ -> false);
  check bool "hostile delete preserves first" true (Sys.file_exists first_path);
  check bool "hostile delete preserves second" true (Sys.file_exists second_path);
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    first.reference
  |> require_payload_ok "delete bound transaction";
  check bool "bound delete removes target" false (Sys.file_exists first_path);
  Payload.delete
    config
    ~keeper_name:first.keeper_name
    ~expected_authority_leaf:first.authority_leaf
    ~transaction_id:first.transaction_id
    first.reference
  |> require_payload_ok "repeat bound delete";
  read_bound first first.reference
  |> expect_error "read deleted transaction" is_missing;
  check bool "other transaction remains" true (Sys.file_exists second_path)
;;
