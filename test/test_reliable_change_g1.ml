open Alcotest
open Reliable_change_g1

let dummy_phase_timestamps =
  { queue_started_at = Some 100.0
  ; model_started_at = Some 101.0
  ; model_ended_at = Some 105.0
  ; tool_started_at = Some 106.0
  ; tool_ended_at = Some 110.0
  ; verification_started_at = Some 111.0
  ; verification_ended_at = Some 112.0
  ; cleanup_ended_at = Some 113.0
  }
;;

let test_manifest_contract_parity () =
  let manifests = default_case_manifests () in
  check int "6 scenarios declared" 6 (List.length manifests);
  let ids = List.map (fun c -> c.case_id) manifests in
  check (list string) "case IDs match contract"
    [ "success"
    ; "exit-nonzero"
    ; "stale-revision"
    ; "missing-artifact"
    ; "retry-success"
    ; "usage-unreported"
    ]
    ids;
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha-123"
      ~source_commit:"git-commit-abc"
      ~binary_sha256:"bin-sha-456"
      ~runtime_config_sha256:"cfg-sha-789"
      ~model_identity:"model-family-1"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let json = manifest_to_json manifest in
  match manifest_of_json json with
  | Ok decoded ->
    check string "contract sha" manifest.contract_sha256 decoded.contract_sha256;
    check string "source commit" manifest.source_commit decoded.source_commit;
    check (list string) "case IDs roundtrip" manifest.case_ids decoded.case_ids
  | Error err -> fail ("manifest decode failed: " ^ err)
;;

let test_usage_aggregation_exact_fixture () =
  (* Contract fixture:
     failed-attempt (per-request): in=10 out=2 cache=3 cost=0.01
     successful-attempt snap 1 (cumulative): in=10 out=2 cache=2 cost=0.02
     successful-attempt snap 2 (cumulative): in=25 out=5 cache=4 cost=0.05
     verifier (per-request): in=5 out=1 cache=1 cost=0.01
     Expected totals: input=40, output=8, cache=8, cost=0.07 *)
  let obs =
    [ { case_id = "retry-success"
      ; repeat_index = 1
      ; run_id = "run-1"
      ; execution_mode = "controlled"
      ; request_or_task_identity = "req-failed-attempt"
      ; run_turn_attempt_identity = "att-1"
      ; target_revision = "rev-1"
      ; requested_revision = "rev-1"
      ; artifact_references = [ "art-1" ]
      ; command_exit_code = Some 1
      ; external_verified = false
      ; verdict_run_identity = None
      ; verdict_passed = false
      ; usage =
          Usage_reported
            { input_tokens = 10
            ; output_tokens = 2
            ; cache_read_input_tokens = 3
            ; cost_usd = Some 0.01
            ; cost_usd_exact = Some "0.01"
            }
      ; usage_scope = Per_request
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 1
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; repeat_index = 1
      ; run_id = "run-1"
      ; execution_mode = "controlled"
      ; request_or_task_identity = "req-successful-attempt"
      ; run_turn_attempt_identity = "att-2"
      ; target_revision = "rev-1"
      ; requested_revision = "rev-1"
      ; artifact_references = [ "art-1" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "v-1"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 10
            ; output_tokens = 2
            ; cache_read_input_tokens = 2
            ; cost_usd = Some 0.02
            ; cost_usd_exact = Some "0.02"
            }
      ; usage_scope = Cumulative_request_snapshot
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 1
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; repeat_index = 1
      ; run_id = "run-1"
      ; execution_mode = "controlled"
      ; request_or_task_identity = "req-successful-attempt"
      ; run_turn_attempt_identity = "att-2"
      ; target_revision = "rev-1"
      ; requested_revision = "rev-1"
      ; artifact_references = [ "art-1" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "v-1"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 25
            ; output_tokens = 5
            ; cache_read_input_tokens = 4
            ; cost_usd = Some 0.05
            ; cost_usd_exact = Some "0.05"
            }
      ; usage_scope = Cumulative_request_snapshot
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 2
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; repeat_index = 1
      ; run_id = "run-1"
      ; execution_mode = "controlled"
      ; request_or_task_identity = "req-verifier"
      ; run_turn_attempt_identity = "att-verifier"
      ; target_revision = "rev-1"
      ; requested_revision = "rev-1"
      ; artifact_references = [ "art-1" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "v-1"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 5
            ; output_tokens = 1
            ; cache_read_input_tokens = 1
            ; cost_usd = Some 0.01
            ; cost_usd_exact = Some "0.01"
            }
      ; usage_scope = Per_request
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 1
      ; total_attempts_in_run = 1
      }
    ]
  in
  let totals = aggregate_run_usages obs in
  check int "fixture input tokens" 40 totals.total_input_tokens;
  check int "fixture output tokens" 8 totals.total_output_tokens;
  check int "fixture cache read tokens" 8 totals.total_cache_read_input_tokens;
  check (option (float 0.001)) "fixture cost usd" (Some 0.07) totals.total_cost_usd;
  check (option string) "fixture exact cost string" (Some "0.07") totals.total_cost_usd_exact
;;

let test_usage_unreported_preserves_none () =
  let obs =
    [ { case_id = "usage-unreported"
      ; repeat_index = 1
      ; run_id = "run-u1"
      ; execution_mode = "controlled"
      ; request_or_task_identity = "req-u1"
      ; run_turn_attempt_identity = "att-u1"
      ; target_revision = "rev-1"
      ; requested_revision = "rev-1"
      ; artifact_references = [ "art-1" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "v-1"
      ; verdict_passed = true
      ; usage = Usage_missing "provider_usage_omitted"
      ; usage_scope = Per_request
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 1
      ; total_attempts_in_run = 1
      }
    ]
  in
  let totals = aggregate_run_usages obs in
  check (option (float 0.001)) "unreported cost is None (not 0.0)" None totals.total_cost_usd;
  check (option string) "unreported exact cost is None" None totals.total_cost_usd_exact
;;

let make_compliant_observation ~case_id ~repeat_index ~execution_mode =
  let scenario = Option.get (scenario_of_string_opt case_id) in
  let target_revision = "rev-1" in
  let requested_revision =
    if scenario = Stale_revision then "rev-2" else "rev-1"
  in
  let command_exit_code =
    if scenario = Exit_nonzero then Some 1 else Some 0
  in
  let artifact_references =
    if scenario = Missing_artifact then [] else [ "artifact.txt" ]
  in
  let external_verified =
    match scenario with
    | Success | Retry_success -> true
    | Exit_nonzero | Stale_revision | Missing_artifact | Usage_unreported -> false
  in
  let verdict_passed = external_verified in
  let verdict_run_identity =
    if verdict_passed then Some (Printf.sprintf "v-%s-%d" case_id repeat_index) else None
  in
  let usage =
    if scenario = Usage_unreported then
      Usage_missing "provider_no_usage"
    else if scenario = Retry_success then
      Usage_reported
        { input_tokens = 40
        ; output_tokens = 8
        ; cache_read_input_tokens = 8
        ; cost_usd = Some 0.07
        ; cost_usd_exact = Some "0.07"
        }
    else
      Usage_reported
        { input_tokens = 100
        ; output_tokens = 20
        ; cache_read_input_tokens = 10
        ; cost_usd = Some 0.05
        ; cost_usd_exact = Some "0.05"
        }
  in
  { case_id
  ; repeat_index
  ; run_id = Printf.sprintf "run-%s-%d" case_id repeat_index
  ; execution_mode
  ; request_or_task_identity = Printf.sprintf "req-%s-%d" case_id repeat_index
  ; run_turn_attempt_identity = Printf.sprintf "att-%s-%d" case_id repeat_index
  ; target_revision
  ; requested_revision
  ; artifact_references
  ; command_exit_code
  ; external_verified
  ; verdict_run_identity
  ; verdict_passed
  ; usage
  ; usage_scope = Per_request
  ; phase_timestamps = dummy_phase_timestamps
  ; attempt_sequence = 1
  ; total_attempts_in_run = 1
  }
;;

let test_checker_validates_compliant_runs () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"model-1"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  (* 18 matrix runs (6 scenarios x 3 repeats) *)
  let matrix_runs =
    List.concat_map
      (fun case_id ->
         [ make_compliant_observation ~case_id ~repeat_index:1 ~execution_mode:"controlled"
         ; make_compliant_observation ~case_id ~repeat_index:2 ~execution_mode:"controlled"
         ; make_compliant_observation ~case_id ~repeat_index:3 ~execution_mode:"controlled"
         ])
      manifest.case_ids
  in
  (* 3 live runs (success, negative, retry-success) *)
  let live_runs =
    [ make_compliant_observation ~case_id:"success" ~repeat_index:1 ~execution_mode:"live"
    ; make_compliant_observation ~case_id:"exit-nonzero" ~repeat_index:1 ~execution_mode:"live"
    ; make_compliant_observation ~case_id:"retry-success" ~repeat_index:1 ~execution_mode:"live"
    ]
  in
  let observations = matrix_runs @ live_runs in
  let summary = check_observations ~manifest ~observations in
  check bool "overall passed" true summary.overall_passed;
  check int "matrix expected" 18 summary.matrix_expected;
  check int "matrix observed" 18 summary.matrix_observed;
  check int "matrix passed" 18 summary.matrix_passed;
  check int "live expected" 3 summary.live_expected;
  check int "live observed" 3 summary.live_observed;
  check int "live passed" 3 summary.live_passed;
  check int "false verified count 0" 0 summary.false_verified_count;
  check int "required join missing count 0" 0 summary.required_join_missing_count;
  check int "unknown coerced to zero count 0" 0 summary.unknown_usage_coerced_to_zero_count;
  check int "duplicated usage count 0" 0 summary.duplicated_usage_count;
  check int "reported usage totals mismatch count 0" 0 summary.reported_usage_totals_mismatch_count;
  (* Verify JSON roundtrip of summary *)
  let summary_json = checker_summary_to_json summary in
  match checker_summary_of_json summary_json with
  | Ok decoded -> check bool "decoded overall passed" summary.overall_passed decoded.overall_passed
  | Error err -> fail ("summary decode failed: " ^ err)
;;

let test_checker_detects_false_verified () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"model-1"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  (* Corrupt exit-nonzero by asserting verdict_passed = true *)
  let bad_obs =
    { (make_compliant_observation ~case_id:"exit-nonzero" ~repeat_index:1 ~execution_mode:"controlled")
      with verdict_passed = true; external_verified = true }
  in
  let summary = check_observations ~manifest ~observations:[ bad_obs ] in
  check bool "overall failed on false verified" false summary.overall_passed;
  check bool "false verified count > 0" true (summary.false_verified_count > 0)
;;

let test_checker_detects_coerced_zero_usage () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"model-1"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  (* Corrupt usage-unreported by coercing to 0 tokens and $0.0 *)
  let bad_obs =
    { (make_compliant_observation ~case_id:"usage-unreported" ~repeat_index:1 ~execution_mode:"controlled")
      with usage = Usage_reported
                     { input_tokens = 0
                     ; output_tokens = 0
                     ; cache_read_input_tokens = 0
                     ; cost_usd = Some 0.0
                     ; cost_usd_exact = Some "0.00"
                     }
    }
  in
  let summary = check_observations ~manifest ~observations:[ bad_obs ] in
  check bool "overall failed on coerced zero usage" false summary.overall_passed;
  check bool "coerced zero count > 0" true (summary.unknown_usage_coerced_to_zero_count > 0)
;;

let () =
  run "reliable_change_g1"
    [ ( "contract_and_manifest"
      , [ test_case "manifest contract parity" `Quick test_manifest_contract_parity ] )
    ; ( "usage_aggregation"
      , [ test_case "exact fixture reconstruction" `Quick test_usage_aggregation_exact_fixture
        ; test_case "unreported preserves None" `Quick test_usage_unreported_preserves_none
        ] )
    ; ( "checker_validation"
      , [ test_case "validates compliant runs" `Quick test_checker_validates_compliant_runs
        ; test_case "detects false verified" `Quick test_checker_detects_false_verified
        ; test_case "detects coerced zero usage" `Quick test_checker_detects_coerced_zero_usage
        ] )
    ]
;;
