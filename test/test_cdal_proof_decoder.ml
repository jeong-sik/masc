(* Tests for Cdal_proof_decoder -- walking skeleton.
   Verifies invariants I1 (totality), I2 (idempotency), I3 (schema guard)
   and antifragile evidence_gap generation. *)

open Masc_mcp

let fixture_dir =
  let this_file = __FILE__ in
  let test_dir = Filename.dirname this_file in
  Filename.concat test_dir "fixtures/cdal"

let read_fixture name =
  let path = Filename.concat fixture_dir name in
  Yojson.Safe.from_file path

(* ================================================================
   I1: Totality -- of_json never raises, always returns Ok or Error
   ================================================================ *)

let test_decode_valid_v1 () =
  let json = read_fixture "proof_manifest_v1.json" in
  match Cdal_proof_decoder.of_json json with
  | Error e ->
    Alcotest.fail
      (Printf.sprintf "expected Ok, got Error: %s"
         (Cdal_proof_decoder.decode_error_to_string e))
  | Ok m ->
    Alcotest.(check string) "run_id" "run-20260328-abc123" m.run_id;
    Alcotest.(check string) "contract_id"
      "md5:7f3a1b2c4d5e6f7890abcdef12345678" m.contract_id;
    Alcotest.(check int) "schema_version" 1 m.schema_version;
    Alcotest.(check string) "provider" "anthropic"
      m.provider_snapshot.provider_name;
    Alcotest.(check string) "model_id" "claude-sonnet-4-6"
      m.provider_snapshot.model_id;
    Alcotest.(check int) "tool_trace count" 2
      (List.length m.tool_trace_refs);
    Alcotest.(check int) "evidence_refs count" 2
      (List.length m.raw_evidence_refs);
    Alcotest.(check bool) "checkpoint present" true
      (Option.is_some m.checkpoint_ref);
    Alcotest.(check bool) "not downgraded" false
      (Cdal_proof_decoder.was_downgraded m);
    (* duration = 1743149100 - 1743148800 = 300s *)
    Alcotest.(check (float 0.01)) "duration" 300.0
      (Cdal_proof_decoder.duration_s m)

let test_decode_downgraded () =
  let json = read_fixture "proof_manifest_v1_downgraded.json" in
  match Cdal_proof_decoder.of_json json with
  | Error e ->
    Alcotest.fail (Cdal_proof_decoder.decode_error_to_string e)
  | Ok m ->
    (* requested=execute, effective=draft *)
    Alcotest.(check bool) "was downgraded" true
      (Cdal_proof_decoder.was_downgraded m);
    Alcotest.(check string) "mode_decision_source"
      "risk_class_downgrade" m.mode_decision_source;
    Alcotest.(check bool) "no checkpoint" true
      (Option.is_none m.checkpoint_ref);
    Alcotest.(check int) "empty traces" 0
      (List.length m.tool_trace_refs)

let test_decode_null_json () =
  match Cdal_proof_decoder.of_json `Null with
  | Ok _ -> Alcotest.fail "expected Error for null input"
  | Error _ -> () (* I1: no exception, just Error *)

let test_decode_empty_object () =
  match Cdal_proof_decoder.of_json (`Assoc []) with
  | Ok _ -> Alcotest.fail "expected Error for empty object"
  | Error (Cdal_proof_decoder.Missing_field "schema_version") -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf "unexpected error: %s"
         (Cdal_proof_decoder.decode_error_to_string e))

let test_decode_string_input () =
  match Cdal_proof_decoder.of_json (`String "not an object") with
  | Ok _ -> Alcotest.fail "expected Error for string input"
  | Error _ -> ()

(* ================================================================
   I2: Idempotency -- decode(encode(decode(json))) = decode(json)
   ================================================================ *)

let test_roundtrip_idempotency () =
  let json = read_fixture "proof_manifest_v1.json" in
  match Cdal_proof_decoder.of_json json with
  | Error e ->
    Alcotest.fail (Cdal_proof_decoder.decode_error_to_string e)
  | Ok m1 ->
    let re_encoded = Cdal_proof_decoder.to_json m1 in
    (match Cdal_proof_decoder.of_json re_encoded with
     | Error e ->
       Alcotest.fail
         (Printf.sprintf "roundtrip decode failed: %s"
            (Cdal_proof_decoder.decode_error_to_string e))
     | Ok m2 ->
       (* Compare key fields for structural equality *)
       Alcotest.(check string) "run_id roundtrip" m1.run_id m2.run_id;
       Alcotest.(check string) "contract_id roundtrip"
         m1.contract_id m2.contract_id;
       Alcotest.(check int) "schema_version roundtrip"
         m1.schema_version m2.schema_version;
       Alcotest.(check string) "provider roundtrip"
         m1.provider_snapshot.provider_name
         m2.provider_snapshot.provider_name;
       Alcotest.(check int) "tools count roundtrip"
         (List.length m1.capability_snapshot.tools)
         (List.length m2.capability_snapshot.tools);
       Alcotest.(check (float 0.01)) "started_at roundtrip"
         m1.started_at m2.started_at;
       Alcotest.(check (float 0.01)) "ended_at roundtrip"
         m1.ended_at m2.ended_at)

let test_roundtrip_downgraded () =
  let json = read_fixture "proof_manifest_v1_downgraded.json" in
  match Cdal_proof_decoder.of_json json with
  | Error e ->
    Alcotest.fail (Cdal_proof_decoder.decode_error_to_string e)
  | Ok m1 ->
    let re_encoded = Cdal_proof_decoder.to_json m1 in
    (match Cdal_proof_decoder.of_json re_encoded with
     | Error e ->
       Alcotest.fail (Cdal_proof_decoder.decode_error_to_string e)
     | Ok m2 ->
       Alcotest.(check bool) "downgraded roundtrip"
         (Cdal_proof_decoder.was_downgraded m1)
         (Cdal_proof_decoder.was_downgraded m2))

(* ================================================================
   I3: Schema version guard -- unknown versions rejected
   ================================================================ *)

let test_schema_version_guard () =
  let json = read_fixture "proof_manifest_v99_future.json" in
  match Cdal_proof_decoder.of_json json with
  | Ok _ -> Alcotest.fail "expected Schema_version_unsupported for v99"
  | Error (Cdal_proof_decoder.Schema_version_unsupported 99) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf "wrong error type: %s"
         (Cdal_proof_decoder.decode_error_to_string e))

let test_schema_version_zero () =
  let json = `Assoc ["schema_version", `Int 0] in
  match Cdal_proof_decoder.of_json json with
  | Ok _ -> Alcotest.fail "expected error for schema_version 0"
  | Error (Cdal_proof_decoder.Schema_version_unsupported 0) -> ()
  | Error _ -> ()

(* ================================================================
   Antifragile: evidence_gap generation from errors
   ================================================================ *)

let test_evidence_gap_missing_field () =
  let json = `Assoc ["schema_version", `Int 1; "run_id", `String "test-run"] in
  match Cdal_proof_decoder.of_json json with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
    let gap = Cdal_proof_decoder.evidence_gap_of_error ~json e in
    Alcotest.(check (option string)) "run_id extracted"
      (Some "test-run") gap.run_id;
    Alcotest.(check bool) "has missing fields" true
      (gap.missing_fields <> []);
    Alcotest.(check bool) "has excerpt" true
      (String.length gap.raw_json_excerpt > 0)

let test_evidence_gap_schema_version () =
  let json = read_fixture "proof_manifest_v99_future.json" in
  match Cdal_proof_decoder.of_json json with
  | Ok _ -> Alcotest.fail "expected error"
  | Error e ->
    let gap = Cdal_proof_decoder.evidence_gap_of_error ~json e in
    Alcotest.(check (option string)) "run_id from v99"
      (Some "run-future-unknown") gap.run_id;
    Alcotest.(check bool) "has invalid fields" true
      (gap.invalid_fields <> [])

(* ================================================================
   Forward compatibility: unknown fields ignored
   ================================================================ *)

let test_unknown_fields_ignored () =
  let json = read_fixture "proof_manifest_v1.json" in
  match json with
  | `Assoc pairs ->
    let json' = `Assoc (pairs @ [
      "_future_field", `String "unknown";
      "_extra_nested", `Assoc ["x", `Int 42];
    ]) in
    (match Cdal_proof_decoder.of_json json' with
     | Error e ->
       Alcotest.fail (Cdal_proof_decoder.decode_error_to_string e)
     | Ok m ->
       Alcotest.(check string) "decoded despite unknown fields"
         "run-20260328-abc123" m.run_id)
  | _ -> Alcotest.fail "fixture not Assoc"

(* ================================================================
   Test suite
   ================================================================ *)

let () =
  Alcotest.run "cdal_proof_decoder" [
    "I1: totality", [
      Alcotest.test_case "decode valid v1" `Quick test_decode_valid_v1;
      Alcotest.test_case "decode downgraded" `Quick test_decode_downgraded;
      Alcotest.test_case "null input" `Quick test_decode_null_json;
      Alcotest.test_case "empty object" `Quick test_decode_empty_object;
      Alcotest.test_case "string input" `Quick test_decode_string_input;
    ];
    "I2: idempotency", [
      Alcotest.test_case "roundtrip v1" `Quick test_roundtrip_idempotency;
      Alcotest.test_case "roundtrip downgraded" `Quick test_roundtrip_downgraded;
    ];
    "I3: schema version guard", [
      Alcotest.test_case "v99 rejected" `Quick test_schema_version_guard;
      Alcotest.test_case "v0 rejected" `Quick test_schema_version_zero;
    ];
    "forward compat", [
      Alcotest.test_case "unknown fields ignored" `Quick test_unknown_fields_ignored;
    ];
    "antifragile: evidence_gap", [
      Alcotest.test_case "missing field gap" `Quick test_evidence_gap_missing_field;
      Alcotest.test_case "schema version gap" `Quick test_evidence_gap_schema_version;
    ];
  ]
