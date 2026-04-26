(** test_cdal_loader -- Unit tests for Cdal_loader module.

    Tests bundle loading from proof store with valid/invalid
    manifests, contracts, schema versions, and contract_id
    roundtrip verification. *)

module CL = Masc_mcp.Cdal_loader

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_proof
      ?(run_id = "loader-test-001")
      ?(contract_id = "md5:abc123")
      ?(schema_version = Agent_sdk.Cdal_proof.schema_version_current)
      ?(requested = Agent_sdk.Execution_mode.Execute)
      ?(effective = Agent_sdk.Execution_mode.Execute)
      ()
  : Agent_sdk.Cdal_proof.t
  =
  { schema_version
  ; run_id
  ; contract_id
  ; requested_execution_mode = requested
  ; effective_execution_mode = effective
  ; mode_decision_source = "passthrough"
  ; risk_class = Agent_sdk.Risk_class.Low
  ; provider_snapshot =
      { provider_name = "test"; model_id = "test-model"; api_version = None }
  ; capability_snapshot =
      { tools = [ "read"; "write" ]
      ; mcp_servers = []
      ; max_turns = 10
      ; max_tokens = Some 4096
      ; thinking_enabled = None
      }
  ; tool_trace_refs = []
  ; raw_evidence_refs = []
  ; checkpoint_ref = None
  ; result_status = Completed
  ; started_at = 1000.0
  ; ended_at = 1001.0
  ; scope = None
  }
;;

let make_contract () : Agent_sdk.Risk_contract.t =
  { runtime_constraints =
      { requested_execution_mode = Execute
      ; risk_class = Low
      ; allowed_mutations = [ "keeper_fs_edit" ]
      ; review_requirement = None
      }
  ; eval_criteria =
      `Assoc
        [ "success_criteria", `List [ `String "tests pass" ]
        ; "required_evidence", `List [ `String "src/main.ml" ]
        ]
  }
;;

let setup_store () =
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "cdal_loader_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  let store : Agent_sdk.Proof_store.config = { root = tmp_dir } in
  store, tmp_dir
;;

let mkdirp path =
  let rec go p =
    if not (Sys.file_exists p)
    then (
      go (Filename.dirname p);
      Unix.mkdir p 0o755)
  in
  go path
;;

(* ================================================================ *)
(* test_load_valid_bundle                                            *)
(* ================================================================ *)

let test_load_valid_bundle () =
  let store, _tmp = setup_store () in
  let run_id = "valid-bundle-001" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof = make_proof ~run_id ~contract_id () in
  (* Write manifest and contract to disk *)
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CL.load ~store proof with
  | Ok bundle ->
    Alcotest.(check string) "run_id" run_id bundle.proof.run_id;
    Alcotest.(check string)
      "recomputed contract_id"
      contract_id
      bundle.recomputed_contract_id;
    Alcotest.(check string)
      "contract mode"
      "execute"
      (Agent_sdk.Execution_mode.to_string
         bundle.contract.runtime_constraints.requested_execution_mode)
  | Error e -> Alcotest.fail (CL.load_error_to_string e)
;;

(* ================================================================ *)
(* test_missing_manifest                                             *)
(* ================================================================ *)

let test_missing_manifest () =
  let store, _tmp = setup_store () in
  let proof = make_proof ~run_id:"no-manifest" () in
  match CL.load ~store proof with
  | Error (Manifest_not_found _) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf "expected Manifest_not_found, got: %s" (CL.load_error_to_string e))
  | Ok _ -> Alcotest.fail "expected error for missing manifest"
;;

(* ================================================================ *)
(* test_malformed_manifest                                           *)
(* ================================================================ *)

let test_malformed_manifest () =
  let store, _tmp = setup_store () in
  let run_id = "bad-manifest" in
  let run_dir =
    match
      Masc_mcp.Proof_artifact_reader.run_artifact_path
        store
        ~run_id
        ~relative_path:"manifest.json"
    with
    | Ok path -> Filename.dirname path
    | Error msg -> Alcotest.fail msg
  in
  mkdirp run_dir;
  let manifest_path = Filename.concat run_dir "manifest.json" in
  let oc = open_out manifest_path in
  output_string oc "{invalid json!!!";
  close_out oc;
  let proof = make_proof ~run_id () in
  match CL.load ~store proof with
  | Error (Manifest_parse_error _) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf
         "expected Manifest_parse_error, got: %s"
         (CL.load_error_to_string e))
  | Ok _ -> Alcotest.fail "expected error for malformed manifest"
;;

(* ================================================================ *)
(* test_missing_contract                                             *)
(* ================================================================ *)

let test_missing_contract () =
  let store, _tmp = setup_store () in
  let run_id = "no-contract" in
  let proof = make_proof ~run_id () in
  (* Write manifest but not contract *)
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  match CL.load ~store proof with
  | Error (Contract_not_found _) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf "expected Contract_not_found, got: %s" (CL.load_error_to_string e))
  | Ok _ -> Alcotest.fail "expected error for missing contract"
;;

(* ================================================================ *)
(* test_malformed_contract                                           *)
(* ================================================================ *)

let test_malformed_contract () =
  let store, _tmp = setup_store () in
  let run_id = "bad-contract" in
  let proof = make_proof ~run_id () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  (* Write invalid contract JSON *)
  let contract_path =
    match
      Masc_mcp.Proof_artifact_reader.run_artifact_path
        store
        ~run_id
        ~relative_path:"contract.json"
    with
    | Ok path -> path
    | Error msg -> Alcotest.fail msg
  in
  let oc = open_out contract_path in
  output_string oc "{not valid contract json}}}";
  close_out oc;
  match CL.load ~store proof with
  | Error (Contract_parse_error _) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf
         "expected Contract_parse_error, got: %s"
         (CL.load_error_to_string e))
  | Ok _ -> Alcotest.fail "expected error for malformed contract"
;;

(* ================================================================ *)
(* test_schema_unsupported                                           *)
(* ================================================================ *)

let test_schema_unsupported () =
  let store, _tmp = setup_store () in
  let run_id = "bad-schema" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  (* Create manifest proof with wrong schema version *)
  let proof = make_proof ~run_id ~contract_id ~schema_version:99 () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CL.load ~store proof with
  | Error (Schema_unsupported 99) -> ()
  | Error e ->
    Alcotest.fail
      (Printf.sprintf
         "expected Schema_unsupported 99, got: %s"
         (CL.load_error_to_string e))
  | Ok _ -> Alcotest.fail "expected error for unsupported schema"
;;

(* ================================================================ *)
(* test_contract_id_roundtrip                                        *)
(* ================================================================ *)

let test_contract_id_roundtrip () =
  let store, _tmp = setup_store () in
  let run_id = "roundtrip-001" in
  let contract = make_contract () in
  let original_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof = make_proof ~run_id ~contract_id:original_id () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CL.load ~store proof with
  | Ok bundle ->
    Alcotest.(check string)
      "recomputed matches original"
      original_id
      bundle.recomputed_contract_id;
    (* Also verify the recomputed ID matches what contract_id produces *)
    let recomputed_again = Agent_sdk.Risk_contract.contract_id bundle.contract in
    Alcotest.(check string) "recomputed from loaded contract" original_id recomputed_again
  | Error e -> Alcotest.fail (CL.load_error_to_string e)
;;

(* ================================================================ *)
(* test_manifest_is_truth_source                                     *)
(* ================================================================ *)

let test_manifest_is_truth_source () =
  let store, _tmp = setup_store () in
  let run_id = "manifest-truth-001" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let manifest_proof =
    make_proof
      ~run_id
      ~contract_id
      ~requested:Agent_sdk.Execution_mode.Execute
      ~effective:Agent_sdk.Execution_mode.Draft
      ()
  in
  let input_proof =
    make_proof
      ~run_id
      ~contract_id
      ~requested:Agent_sdk.Execution_mode.Diagnose
      ~effective:Agent_sdk.Execution_mode.Diagnose
      ()
  in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id manifest_proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CL.load ~store input_proof with
  | Ok bundle ->
    Alcotest.(check string)
      "requested from manifest"
      "execute"
      (Agent_sdk.Execution_mode.to_string bundle.proof.requested_execution_mode);
    Alcotest.(check string)
      "effective from manifest"
      "draft"
      (Agent_sdk.Execution_mode.to_string bundle.proof.effective_execution_mode)
  | Error e -> Alcotest.fail (CL.load_error_to_string e)
;;

(* ================================================================ *)
(* test_load_error_to_string coverage                                *)
(* ================================================================ *)

let test_load_error_to_string () =
  let cases =
    [ CL.Manifest_not_found "/a/b", "manifest not found: /a/b"
    ; CL.Manifest_parse_error "bad", "manifest parse error: bad"
    ; CL.Contract_not_found "/c/d", "contract not found: /c/d"
    ; CL.Contract_parse_error "bad", "contract parse error: bad"
    ; ( CL.Schema_unsupported 99
      , Printf.sprintf
          "unsupported schema version: 99 (expected %d)"
          Agent_sdk.Cdal_proof.schema_version_current )
    ; CL.Ref_resolution_error "ref", "ref resolution error: ref"
    ]
  in
  List.iter
    (fun (err, expected) ->
       Alcotest.(check string) "error string" expected (CL.load_error_to_string err))
    cases
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run
    "Cdal_loader"
    [ ( "load"
      , [ Alcotest.test_case "valid bundle" `Quick test_load_valid_bundle
        ; Alcotest.test_case "missing manifest" `Quick test_missing_manifest
        ; Alcotest.test_case "malformed manifest" `Quick test_malformed_manifest
        ; Alcotest.test_case "missing contract" `Quick test_missing_contract
        ; Alcotest.test_case "malformed contract" `Quick test_malformed_contract
        ; Alcotest.test_case "schema unsupported" `Quick test_schema_unsupported
        ; Alcotest.test_case "contract_id roundtrip" `Quick test_contract_id_roundtrip
        ; Alcotest.test_case
            "manifest is truth source"
            `Quick
            test_manifest_is_truth_source
        ] )
    ; ( "error_string"
      , [ Alcotest.test_case "all variants" `Quick test_load_error_to_string ] )
    ]
;;
