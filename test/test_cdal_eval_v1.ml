(** test_cdal_eval_v1 -- Unit tests for Cdal_eval_v1 integration facade.

    Tests the full pipeline (load + judge), load failure path,
    and verdict_of_outcome extraction. *)

module CE = Masc_mcp.Cdal_eval_v1
module CT = Masc_mcp.Cdal_types
module CL = Masc_mcp.Cdal_loader

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_proof
      ?(run_id = "eval-v1-test-001")
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
  ; eval_criteria = `Assoc [ "success_criteria", `List [ `String "tests pass" ] ]
  }
;;

let make_contract_with_review_requirement () : Agent_sdk.Risk_contract.t =
  { runtime_constraints =
      { requested_execution_mode = Execute
      ; risk_class = Low
      ; allowed_mutations = [ "keeper_fs_edit" ]
      ; review_requirement = Some "human_review"
      }
  ; eval_criteria = `Assoc [ "success_criteria", `List [ `String "tests pass" ] ]
  }
;;

let setup_store () =
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "cdal_eval_v1_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  let store : Agent_sdk.Proof_store.config = { root = tmp_dir } in
  store, tmp_dir
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    (fun () ->
       Unix.putenv name value;
       f ())
;;

(* ================================================================ *)
(* test_full_pipeline                                                *)
(* ================================================================ *)

let test_full_pipeline () =
  let store, _tmp = setup_store () in
  let run_id = "full-pipeline-001" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof = make_proof ~run_id ~contract_id () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CE.evaluate ~store proof with
  | Verdict (v, _) ->
    Alcotest.(check string) "status" "satisfied" (CT.contract_status_to_string v.status);
    Alcotest.(check string) "run_id" run_id v.run_id;
    Alcotest.(check string) "claim_scope" "phase1_scoped_runtime_audit" v.claim_scope;
    Alcotest.(check string)
      "loader_semantics_version"
      CT.loader_semantics_version_phase1
      v.loader_semantics_version;
    Alcotest.(check string)
      "schema_compat_mode"
      CT.schema_compat_mode_v1
      v.schema_compat_mode;
    Alcotest.(check int) "5 check results" 5 (List.length v.check_results)
  | Load_failure (err, _) ->
    Alcotest.fail
      (Printf.sprintf
         "expected Verdict, got Load_failure: %s"
         (CL.load_error_to_string err))
;;

(* ================================================================ *)
(* test_load_failure_inconclusive                                    *)
(* ================================================================ *)

let test_load_failure_inconclusive () =
  let store, _tmp = setup_store () in
  let proof = make_proof ~run_id:"no-manifest-v1" () in
  match CE.evaluate ~store proof with
  | Load_failure (Manifest_not_found _, v) ->
    Alcotest.(check string)
      "status"
      "inconclusive"
      (CT.contract_status_to_string v.status);
    Alcotest.(check string) "claim_scope" "phase1_scoped_runtime_audit" v.claim_scope;
    Alcotest.(check string)
      "loader_semantics_version"
      CT.loader_semantics_version_phase1
      v.loader_semantics_version;
    Alcotest.(check string)
      "schema_compat_mode"
      CT.schema_compat_mode_v1
      v.schema_compat_mode;
    Alcotest.(check bool)
      "has completeness_gaps"
      true
      (List.length v.completeness_gaps > 0);
    let gap = List.hd v.completeness_gaps in
    Alcotest.(check string) "gap artifact" "manifest.json" gap.artifact;
    Alcotest.(check string)
      "gap impact"
      "blocks_verdict"
      (CT.completeness_impact_to_string gap.impact)
  | Load_failure (err, _) ->
    Alcotest.fail
      (Printf.sprintf
         "expected Manifest_not_found, got: %s"
         (CL.load_error_to_string err))
  | Verdict (_, _) -> Alcotest.fail "expected Load_failure, got Verdict"
;;

(* ================================================================ *)
(* test_verdict_of_outcome                                           *)
(* ================================================================ *)

let test_verdict_of_outcome () =
  (* Verdict branch *)
  let store1, _ = setup_store () in
  let run_id = "voo-test-001" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof1 = make_proof ~run_id ~contract_id () in
  Agent_sdk.Proof_store.init_run store1 ~run_id;
  Agent_sdk.Proof_store.write_manifest store1 ~run_id proof1;
  Agent_sdk.Proof_store.write_contract store1 ~run_id contract;
  let outcome1 = CE.evaluate ~store:store1 proof1 in
  let v1 = CE.verdict_of_outcome outcome1 in
  Alcotest.(check string)
    "verdict branch status"
    "satisfied"
    (CT.contract_status_to_string v1.status);
  (* Load_failure branch *)
  let store2, _ = setup_store () in
  let proof2 = make_proof ~run_id:"voo-missing" () in
  let outcome2 = CE.evaluate ~store:store2 proof2 in
  let v2 = CE.verdict_of_outcome outcome2 in
  Alcotest.(check string)
    "failure branch status"
    "inconclusive"
    (CT.contract_status_to_string v2.status)
;;

let test_review_requirement_yields_inconclusive () =
  let store, _tmp = setup_store () in
  let run_id = "review-gate-001" in
  let contract = make_contract_with_review_requirement () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof = make_proof ~run_id ~contract_id () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CE.evaluate ~store proof with
  | Verdict (v, Some fp) ->
    Alcotest.(check string)
      "status"
      "inconclusive"
      (CT.contract_status_to_string v.status);
    Alcotest.(check bool)
      "has review gap"
      true
      (List.exists
         (fun (g : CT.completeness_gap) ->
            String.equal g.artifact "evidence/review_warning.json")
         v.completeness_gaps);
    Alcotest.(check (list string))
      "review tripwire"
      [ "review_requirement:submit_for_verification" ]
      fp.review_tripwires
  | Verdict (_, None) -> Alcotest.fail "expected friction projection for review gap"
  | Load_failure (err, _) ->
    Alcotest.fail
      (Printf.sprintf
         "expected Verdict, got Load_failure: %s"
         (CL.load_error_to_string err))
;;

let test_persist_explicit_base_dir_avoids_default_resolution () =
  with_env "MASC_BASE_PATH" ""
  @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" ""
  @@ fun () ->
  let store, tmp = setup_store () in
  let run_id = "persist-explicit-base-dir" in
  let contract = make_contract () in
  let contract_id = Agent_sdk.Risk_contract.contract_id contract in
  let proof = make_proof ~run_id ~contract_id () in
  Agent_sdk.Proof_store.init_run store ~run_id;
  Agent_sdk.Proof_store.write_manifest store ~run_id proof;
  Agent_sdk.Proof_store.write_contract store ~run_id contract;
  match CE.evaluate ~store proof with
  | Verdict (v, _) ->
    let base_dir = Filename.concat tmp "cdal_verdicts" in
    Eio_main.run
    @@ fun _env ->
    CE.persist ~base_dir v;
    Alcotest.(check bool) "explicit base_dir created" true (Sys.file_exists base_dir)
  | Load_failure (err, _) ->
    Alcotest.fail
      (Printf.sprintf
         "expected Verdict, got Load_failure: %s"
         (CL.load_error_to_string err))
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run
    "Cdal_eval_v1"
    [ ( "pipeline"
      , [ Alcotest.test_case "full pipeline" `Quick test_full_pipeline
        ; Alcotest.test_case
            "load failure inconclusive"
            `Quick
            test_load_failure_inconclusive
        ; Alcotest.test_case "verdict_of_outcome" `Quick test_verdict_of_outcome
        ; Alcotest.test_case
            "review requirement yields inconclusive"
            `Quick
            test_review_requirement_yields_inconclusive
        ; Alcotest.test_case
            "persist explicit base_dir avoids default resolution"
            `Quick
            test_persist_explicit_base_dir_avoids_default_resolution
        ] )
    ]
;;
