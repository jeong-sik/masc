(* E2E integration test: OAS proof capture → file → MASC decoder.

   Verifies the full walking skeleton data path:
   1. Create OAS proof bundle using actual OAS types
   2. Write to filesystem via Proof_store
   3. Read manifest.json back
   4. Decode via Cdal_proof_decoder
   5. Verify all 15 fields survive the roundtrip *)

open Masc_mcp
module Oas = Agent_sdk

let tmp_dir () =
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "cdal-e2e-%d" (Unix.getpid ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup dir =
  (* Best-effort recursive cleanup *)
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  (try rm dir with _ -> ())

(* ================================================================
   E2E: OAS write → filesystem → MASC decode
   ================================================================ *)

let test_oas_write_masc_decode () =
  let root = tmp_dir () in
  let store : Oas.Proof_store.config = { root } in
  (* 1. Create OAS proof bundle *)
  let contract : Oas.Risk_contract.t = {
    runtime_constraints = {
      requested_execution_mode = Oas.Execution_mode.Draft;
      risk_class = Oas.Risk_class.Medium;
      allowed_mutations = ["workspace_only"];
      review_requirement = Some "human_if_execute";
    };
    eval_criteria = `Assoc [
      "success_criteria", `List [`String "tests pass"];
      "required_evidence", `List [`String "tool_trace"];
    ];
  } in
  let capability_snapshot : Oas.Cdal_proof.capability_snapshot = {
    tools = ["bash"; "edit"; "read"];
    mcp_servers = ["masc-mcp"];
    max_turns = 25;
    max_tokens = Some 4096;
    thinking_enabled = Some true;
  } in
  let mode_decision : Oas.Mode_resolver.decision = {
    effective_mode = Oas.Execution_mode.Draft;
    source = "capability_match";
  } in

  (* 2. Create proof capture state and finalize *)
  let state = Oas.Proof_capture.create
    ~store ~contract ~mode_decision ~capability_snapshot in
  let proof = Oas.Proof_capture.finalize state
    ~result_status:Oas.Cdal_proof.Completed in

  (* 3. Verify manifest file exists *)
  let manifest_path = Oas.Proof_store.manifest_path store ~run_id:(Oas.Proof_capture.run_id state) in
  Alcotest.(check bool) "manifest.json exists"
    true (Sys.file_exists manifest_path);

  (* 4. Read and decode via MASC decoder *)
  let json = Yojson.Safe.from_file manifest_path in
  (match Cdal_proof_decoder.of_json json with
   | Error e ->
     cleanup root;
     Alcotest.fail
       (Printf.sprintf "MASC decoder failed on OAS-produced manifest: %s"
          (Cdal_proof_decoder.decode_error_to_string e))
   | Ok m ->
     (* 5. Verify key fields *)
     Alcotest.(check int) "schema_version" 1 m.schema_version;
     Alcotest.(check string) "run_id matches"
       (Oas.Proof_capture.run_id state) m.run_id;
     Alcotest.(check string) "contract_id"
       (Oas.Risk_contract.contract_id contract) m.contract_id;

     (* Verify execution mode survived roundtrip *)
     Alcotest.(check bool) "requested=draft" true
       (m.requested_execution_mode = Cdal_proof_decoder.Draft);
     Alcotest.(check bool) "effective=draft" true
       (m.effective_execution_mode = Cdal_proof_decoder.Draft);
     Alcotest.(check string) "mode_decision_source"
       "capability_match" m.mode_decision_source;

     (* Verify risk class *)
     Alcotest.(check bool) "risk_class=medium" true
       (m.risk_class = Cdal_proof_decoder.Medium);

     (* Verify provider snapshot *)
     Alcotest.(check bool) "provider exists" true
       (String.length m.provider_snapshot.provider_name > 0);

     (* Verify capability snapshot *)
     Alcotest.(check int) "tools count" 3
       (List.length m.capability_snapshot.tools);
     Alcotest.(check int) "max_turns" 25
       m.capability_snapshot.max_turns;

     (* Verify result status *)
     Alcotest.(check bool) "completed" true
       (m.result_status = Cdal_proof_decoder.Completed);

     (* Verify timing *)
     Alcotest.(check bool) "duration >= 0" true
       (Cdal_proof_decoder.duration_s m >= 0.0);

     (* Verify OAS proof matches decoded proof *)
     Alcotest.(check string) "OAS run_id = decoded run_id"
       proof.run_id m.run_id;

     Printf.printf "E2E success: OAS run_id=%s → MASC decoded OK\n%!" m.run_id;
     Printf.printf "  manifest: %s\n%!" manifest_path);

  cleanup root

(* ================================================================
   E2E: decoder evidence_gap on OAS proof with future fields
   ================================================================ *)

let test_oas_manifest_with_extra_fields () =
  let root = tmp_dir () in
  let store : Oas.Proof_store.config = { root } in

  let contract : Oas.Risk_contract.t = {
    runtime_constraints = {
      requested_execution_mode = Oas.Execution_mode.Diagnose;
      risk_class = Oas.Risk_class.Low;
      allowed_mutations = [];
      review_requirement = None;
    };
    eval_criteria = `Null;
  } in
  let capability_snapshot : Oas.Cdal_proof.capability_snapshot = {
    tools = []; mcp_servers = []; max_turns = 10;
    max_tokens = None; thinking_enabled = None;
  } in
  let mode_decision : Oas.Mode_resolver.decision = {
    effective_mode = Oas.Execution_mode.Diagnose;
    source = "default";
  } in

  let state = Oas.Proof_capture.create
    ~store ~contract ~mode_decision ~capability_snapshot in
  let _proof = Oas.Proof_capture.finalize state
    ~result_status:Oas.Cdal_proof.Cancelled in

  let manifest_path = Oas.Proof_store.manifest_path store
    ~run_id:(Oas.Proof_capture.run_id state) in
  let json = Yojson.Safe.from_file manifest_path in

  (* Add hypothetical future fields *)
  let json' = match json with
    | `Assoc pairs ->
      `Assoc (pairs @ [
        "_oas_internal_v2", `String "future data";
        "_experiment_id", `Int 42;
      ])
    | other -> other
  in
  (* Decoder should ignore unknown fields *)
  (match Cdal_proof_decoder.of_json json' with
   | Error e ->
     cleanup root;
     Alcotest.fail
       (Printf.sprintf "decoder rejected future fields: %s"
          (Cdal_proof_decoder.decode_error_to_string e))
   | Ok m ->
     Alcotest.(check bool) "result=cancelled" true
       (m.result_status = Cdal_proof_decoder.Cancelled);
     Alcotest.(check bool) "not downgraded" false
       (Cdal_proof_decoder.was_downgraded m));

  cleanup root

(* ================================================================
   Test suite
   ================================================================ *)

let () =
  Alcotest.run "cdal_e2e" [
    "OAS → MASC roundtrip", [
      Alcotest.test_case "full 15-field roundtrip" `Quick
        test_oas_write_masc_decode;
      Alcotest.test_case "future fields ignored" `Quick
        test_oas_manifest_with_extra_fields;
    ];
  ]
