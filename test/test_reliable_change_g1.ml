open Alcotest
open Reliable_change_g1

let contains_sub needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  if n > h then false
  else
    let rec loop i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else loop (i + 1)
    in
    loop 0
;;

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
    check string "contract sha parity" manifest.contract_sha256 decoded.contract_sha256;
    check string "source commit parity" manifest.source_commit decoded.source_commit;
    check string "workload revision parity" manifest.workload_revision decoded.workload_revision;
    check (list string) "case ids parity" manifest.case_ids decoded.case_ids
  | Error err -> fail ("manifest roundtrip failed: " ^ err)
;;

let test_usage_aggregation_exact_fixture () =
  let obs =
    [ { case_id = "retry-success"
      ; scenario = Matrix_scenario Retry_success
      ; repeat_index = 1
      ; run_id = "run-fixture-1"
      ; execution_mode = "matrix"
      ; request_or_task_identity = Some "failed-attempt"
      ; run_turn_attempt_identity = Some "attempt-1"
      ; target_revision = Some "rev-1"
      ; requested_revision = Some "rev-1"
      ; artifact_references = [ "solution.patch" ]
      ; command_exit_code = Some 1
      ; external_verified = false
      ; verdict_run_identity = Some "verdict-1"
      ; verdict_passed = false
      ; usage =
          Usage_reported
            { input_tokens = 10
            ; output_tokens = 2
            ; cache_read_input_tokens = 3
            ; cost_usd = Some 0.01
            ; cost_usd_exact = Some "0.01"
            }
      ; usage_scope = Some Per_request
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 1
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; scenario = Matrix_scenario Retry_success
      ; repeat_index = 1
      ; run_id = "run-fixture-2"
      ; execution_mode = "matrix"
      ; request_or_task_identity = Some "successful-attempt"
      ; run_turn_attempt_identity = Some "attempt-2-snap-1"
      ; target_revision = Some "rev-1"
      ; requested_revision = Some "rev-1"
      ; artifact_references = [ "solution.patch" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "verdict-2"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 10
            ; output_tokens = 2
            ; cache_read_input_tokens = 2
            ; cost_usd = Some 0.02
            ; cost_usd_exact = Some "0.02"
            }
      ; usage_scope = Some Cumulative_request_snapshot
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 2
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; scenario = Matrix_scenario Retry_success
      ; repeat_index = 1
      ; run_id = "run-fixture-3"
      ; execution_mode = "matrix"
      ; request_or_task_identity = Some "successful-attempt"
      ; run_turn_attempt_identity = Some "attempt-2-snap-2"
      ; target_revision = Some "rev-1"
      ; requested_revision = Some "rev-1"
      ; artifact_references = [ "solution.patch" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "verdict-2"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 25
            ; output_tokens = 5
            ; cache_read_input_tokens = 4
            ; cost_usd = Some 0.05
            ; cost_usd_exact = Some "0.05"
            }
      ; usage_scope = Some Cumulative_request_snapshot
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 2
      ; total_attempts_in_run = 2
      }
    ; { case_id = "retry-success"
      ; scenario = Matrix_scenario Retry_success
      ; repeat_index = 1
      ; run_id = "run-fixture-4"
      ; execution_mode = "matrix"
      ; request_or_task_identity = Some "verifier"
      ; run_turn_attempt_identity = Some "verifier-attempt-1"
      ; target_revision = Some "rev-1"
      ; requested_revision = Some "rev-1"
      ; artifact_references = [ "solution.patch" ]
      ; command_exit_code = Some 0
      ; external_verified = true
      ; verdict_run_identity = Some "verdict-verif"
      ; verdict_passed = true
      ; usage =
          Usage_reported
            { input_tokens = 5
            ; output_tokens = 1
            ; cache_read_input_tokens = 1
            ; cost_usd = Some 0.01
            ; cost_usd_exact = Some "0.01"
            }
      ; usage_scope = Some Per_request
      ; phase_timestamps = dummy_phase_timestamps
      ; attempt_sequence = 3
      ; total_attempts_in_run = 3
      }
    ]
  in
  let totals = aggregate_run_usages obs in
  check int "fixture input tokens" 40 totals.total_input_tokens;
  check int "fixture output tokens" 8 totals.total_output_tokens;
  check int "fixture cache read tokens" 8 totals.total_cache_read_input_tokens;
  (match totals.total_cost_usd with
   | Some c -> check (float 1e-6) "fixture total cost usd" 0.07 c
   | None -> fail "cost was null");
  check (option string) "fixture exact cost string" (Some "0.07") totals.total_cost_usd_exact
;;

let make_dummy_observation ~case_id ~repeat_index ~run_id ~mode ~verified ~exit_code ~usage ~attempt_seq =
  let scenario =
    match run_scenario_of_string ~execution_mode:mode case_id with
    | Ok sc -> sc
    | Error err -> failwith err
  in
  { case_id
  ; scenario
  ; repeat_index
  ; run_id
  ; execution_mode = mode
  ; request_or_task_identity = Some (Printf.sprintf "req-%s-%d" case_id repeat_index)
  ; run_turn_attempt_identity = Some (Printf.sprintf "att-%s-%d-%d" case_id repeat_index attempt_seq)
  ; target_revision = Some (if case_id = "stale-revision" then "stale-rev-999" else "rev-1")
  ; requested_revision = Some "rev-1"
  ; artifact_references = (if case_id = "missing-artifact" then [] else [ "result.patch" ])
  ; command_exit_code = exit_code
  ; external_verified = verified
  ; verdict_run_identity = Some (Printf.sprintf "verdict-%s-%d" case_id repeat_index)
  ; verdict_passed = verified
  ; usage
  ; usage_scope = Some Per_request
  ; phase_timestamps = dummy_phase_timestamps
  ; attempt_sequence = attempt_seq
  ; total_attempts_in_run = (if case_id = "retry-success" then 2 else 1)
  }
;;

let generate_compliant_observations () =
  let obs = ref [] in
  (* Matrix runs: 6 scenarios x 3 repetitions *)
  for rep = 1 to 3 do
    (* success: 1 record, verified = true *)
    obs := make_dummy_observation ~case_id:"success" ~repeat_index:rep ~run_id:(Printf.sprintf "succ-%d" rep)
             ~mode:"matrix" ~verified:true ~exit_code:(Some 0)
             ~usage:(Usage_reported { input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 0; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
             ~attempt_seq:1 :: !obs;

    (* exit-nonzero: 1 record, verified = false, exit = 1 *)
    obs := make_dummy_observation ~case_id:"exit-nonzero" ~repeat_index:rep ~run_id:(Printf.sprintf "exit-%d" rep)
             ~mode:"matrix" ~verified:false ~exit_code:(Some 1)
             ~usage:(Usage_reported { input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 0; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
             ~attempt_seq:1 :: !obs;

    (* stale-revision: 1 record, verified = false *)
    obs := make_dummy_observation ~case_id:"stale-revision" ~repeat_index:rep ~run_id:(Printf.sprintf "stale-%d" rep)
             ~mode:"matrix" ~verified:false ~exit_code:(Some 0)
             ~usage:(Usage_reported { input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 0; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
             ~attempt_seq:1 :: !obs;

    (* missing-artifact: 1 record, verified = false *)
    obs := make_dummy_observation ~case_id:"missing-artifact" ~repeat_index:rep ~run_id:(Printf.sprintf "missing-%d" rep)
             ~mode:"matrix" ~verified:false ~exit_code:(Some 0)
             ~usage:(Usage_reported { input_tokens = 10; output_tokens = 5; cache_read_input_tokens = 0; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
             ~attempt_seq:1 :: !obs;

    (* retry-success: 4 records per repetition reconstructing the exact fixture (10, 25, verifier) *)
    let retry_run_id_prefix = Printf.sprintf "retry-%d" rep in
    let r1 =
      { (make_dummy_observation ~case_id:"retry-success" ~repeat_index:rep ~run_id:(retry_run_id_prefix ^ "-1")
           ~mode:"matrix" ~verified:false ~exit_code:(Some 1)
           ~usage:(Usage_reported { input_tokens = 10; output_tokens = 2; cache_read_input_tokens = 3; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
           ~attempt_seq:1)
        with request_or_task_identity = Some "failed-attempt"; usage_scope = Some Per_request }
    in
    let r2 =
      { (make_dummy_observation ~case_id:"retry-success" ~repeat_index:rep ~run_id:(retry_run_id_prefix ^ "-2")
           ~mode:"matrix" ~verified:true ~exit_code:(Some 0)
           ~usage:(Usage_reported { input_tokens = 10; output_tokens = 2; cache_read_input_tokens = 2; cost_usd = Some 0.02; cost_usd_exact = Some "0.02" })
           ~attempt_seq:2)
        with request_or_task_identity = Some "successful-attempt"; usage_scope = Some Cumulative_request_snapshot }
    in
    let r3 =
      let snap2_identity = Printf.sprintf "att-retry-success-%d-2-snap2" rep in
      (* Second progressive snapshot of the same attempt: distinct snapshot
         identity (mirroring the canonical fixture's attempt-2-snap-1/-snap-2),
         same request identity and attempt_sequence. *)
      { (make_dummy_observation ~case_id:"retry-success" ~repeat_index:rep ~run_id:(retry_run_id_prefix ^ "-3")
           ~mode:"matrix" ~verified:true ~exit_code:(Some 0)
           ~usage:(Usage_reported { input_tokens = 25; output_tokens = 5; cache_read_input_tokens = 4; cost_usd = Some 0.05; cost_usd_exact = Some "0.05" })
           ~attempt_seq:2)
        with request_or_task_identity = Some "successful-attempt"; usage_scope = Some Cumulative_request_snapshot; run_turn_attempt_identity = Some snap2_identity }
    in
    let r4 =
      { (make_dummy_observation ~case_id:"retry-success" ~repeat_index:rep ~run_id:(retry_run_id_prefix ^ "-4")
           ~mode:"matrix" ~verified:true ~exit_code:(Some 0)
           ~usage:(Usage_reported { input_tokens = 5; output_tokens = 1; cache_read_input_tokens = 1; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
           ~attempt_seq:3)
        with request_or_task_identity = Some "verifier"; usage_scope = Some Per_request }
    in
    obs := r1 :: r2 :: r3 :: r4 :: !obs;

    (* usage-unreported: 1 record, verified = false, usage missing *)
    obs := make_dummy_observation ~case_id:"usage-unreported" ~repeat_index:rep ~run_id:(Printf.sprintf "unrep-%d" rep)
             ~mode:"matrix" ~verified:false ~exit_code:(Some 0)
             ~usage:(Usage_missing "provider_no_metrics")
             ~attempt_seq:1 :: !obs;
  done;

  (* Live runs: 3 runs. Rule 68: retry-success requires an observed failed attempt and subsequent success *)
  obs := make_dummy_observation ~case_id:"success" ~repeat_index:1 ~run_id:"live-succ-1"
           ~mode:"live" ~verified:true ~exit_code:(Some 0)
           ~usage:(Usage_reported { input_tokens = 15; output_tokens = 3; cache_read_input_tokens = 0; cost_usd = Some 0.02; cost_usd_exact = Some "0.02" })
           ~attempt_seq:1 :: !obs;
  obs := make_dummy_observation ~case_id:"negative" ~repeat_index:1 ~run_id:"live-neg-1"
           ~mode:"live" ~verified:false ~exit_code:(Some 1)
           ~usage:(Usage_reported { input_tokens = 15; output_tokens = 3; cache_read_input_tokens = 0; cost_usd = Some 0.02; cost_usd_exact = Some "0.02" })
           ~attempt_seq:1 :: !obs;
  (* Live retry attempt 1: failed *)
  obs := make_dummy_observation ~case_id:"retry-success" ~repeat_index:1 ~run_id:"live-retry-1-att1"
           ~mode:"live" ~verified:false ~exit_code:(Some 1)
           ~usage:(Usage_reported { input_tokens = 10; output_tokens = 2; cache_read_input_tokens = 0; cost_usd = Some 0.01; cost_usd_exact = Some "0.01" })
           ~attempt_seq:1 :: !obs;
  (* Live retry attempt 2: verified success *)
  obs := make_dummy_observation ~case_id:"retry-success" ~repeat_index:1 ~run_id:"live-retry-1-att2"
           ~mode:"live" ~verified:true ~exit_code:(Some 0)
           ~usage:(Usage_reported { input_tokens = 25; output_tokens = 5; cache_read_input_tokens = 0; cost_usd = Some 0.04; cost_usd_exact = Some "0.04" })
           ~attempt_seq:2 :: !obs;

  List.rev !obs
;;

let test_checker_accepts_compliant_records () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"claude"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let raw_obs = generate_compliant_observations () in
  (* 27 matrix raw records + 4 live records = 31 total records *)
  check int "total raw observations across attempts" 31 (List.length raw_obs);
  let summary = check_observations ~manifest ~observations:raw_obs in
  check int "matrix runs expected" 18 summary.matrix_expected;
  check int "matrix runs observed (grouped)" 18 summary.matrix_observed;
  check int "matrix runs passed" 18 summary.matrix_passed;
  check int "live runs expected" 3 summary.live_expected;
  check int "live runs observed" 3 summary.live_observed;
  check int "live runs passed" 3 summary.live_passed;
  check int "false verified count" 0 summary.false_verified_count;
  check int "missing required join count" 0 summary.required_join_missing_count;
  check int "coerced zero usage count" 0 summary.unknown_usage_coerced_to_zero_count;
  check int "duplicated usage count" 0 summary.duplicated_usage_count;
  check int "totals mismatch count" 0 summary.reported_usage_totals_mismatch_count;
  check bool "overall passed" true summary.overall_passed
;;

let test_checker_rejects_verification_failure_in_success () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"claude"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let raw_obs = generate_compliant_observations () in
  (* Mutate one success run to have failed verification *)
  let corrupted =
    List.map
      (fun (o : run_observation) ->
         if o.case_id = "success" && o.repeat_index = 2 then
           { o with external_verified = false; verdict_passed = false }
         else o)
      raw_obs
  in
  let summary = check_observations ~manifest ~observations:corrupted in
  check int "matrix passed decremented to 17" 17 summary.matrix_passed;
  check bool "overall failed on unverified success" false summary.overall_passed;
  check bool "finding recorded for failure" true
    (List.exists (fun f -> contains_sub "success_verification_failed" f.rule_id) summary.findings)
;;

let test_checker_rejects_duplicated_usage () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"claude"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let raw_obs = generate_compliant_observations () in
  (* Duplicate an attempt record in success repetition 1 *)
  let dupe_record =
    List.find (fun (o : run_observation) -> o.case_id = "success" && o.repeat_index = 1) raw_obs
  in
  let corrupted = dupe_record :: raw_obs in
  let summary = check_observations ~manifest ~observations:corrupted in
  check bool "duplicated usage count > 0" true (summary.duplicated_usage_count > 0);
  check bool "overall failed on duplicated usage" false summary.overall_passed
;;

let test_checker_rejects_missing_matrix_mode () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"claude"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let raw_obs = generate_compliant_observations () in
  (* Change all matrix observations to execution_mode = "live" *)
  let all_live =
    List.map
      (fun (o : run_observation) -> { o with execution_mode = "live" })
      raw_obs
  in
  let summary = check_observations ~manifest ~observations:all_live in
  check int "matrix observed is 0" 0 summary.matrix_observed;
  check int "matrix expected is 18" 18 summary.matrix_expected;
  check bool "overall failed when matrix not observed" false summary.overall_passed;
  check bool "missing manifest case finding reported" true
    (List.exists (fun f -> contains_sub "manifest_case_missing" f.rule_id) summary.findings)
;;

let test_checker_deep_manifest_validation () =
  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha"
      ~source_commit:"commit-sha"
      ~binary_sha256:"bin-sha"
      ~runtime_config_sha256:"cfg-sha"
      ~model_identity:"claude"
      ~workload_revision:"rev-1"
      ~execution_mode:"matrix"
  in
  let raw_obs = generate_compliant_observations () in

  (* 1. Missing required phase boundary (e.g. cleanup_ended_at is None) *)
  let missing_boundary =
    List.map
      (fun (o : run_observation) ->
         if o.case_id = "success" && o.repeat_index = 1 then
           { o with phase_timestamps = { o.phase_timestamps with cleanup_ended_at = None } }
         else o)
      raw_obs
  in
  let summary_boundary = check_observations ~manifest ~observations:missing_boundary in
  check bool "rejected on missing phase boundary" false summary_boundary.overall_passed;
  check bool "finding for missing phase boundary recorded" true
    (List.exists (fun f -> contains_sub "missing_phase_boundary" f.rule_id) summary_boundary.findings);

  (* 2. Manifest expected outcome mismatch (e.g. exit-nonzero actually verified) *)
  let outcome_mismatch =
    List.map
      (fun (o : run_observation) ->
         if o.case_id = "exit-nonzero" && o.repeat_index = 1 then
           { o with external_verified = true; verdict_passed = true; command_exit_code = Some 0 }
         else o)
      raw_obs
  in
  let summary_outcome = check_observations ~manifest ~observations:outcome_mismatch in
  check bool "rejected on expected outcome mismatch" false summary_outcome.overall_passed;
  check bool "finding for outcome mismatch recorded" true
    (List.exists (fun f -> contains_sub "manifest_expected_outcome_mismatch" f.rule_id) summary_outcome.findings);

  (* 3. Manifest missing required_entities_by_case entry *)
  let manifest_without_req =
    { manifest with
      required_entities_by_case =
        List.filter (fun (k, _) -> k <> "success") manifest.required_entities_by_case
    }
  in
  let summary_req = check_observations ~manifest:manifest_without_req ~observations:raw_obs in
  check bool "rejected when required_entities missing from manifest" false summary_req.overall_passed;
  check bool "finding for missing required entities declaration recorded" true
    (List.exists (fun f -> contains_sub "missing_required_entities_declaration" f.rule_id) summary_req.findings);

  (* 4. Manifest missing phase_boundaries_by_case entry *)
  let manifest_without_pb =
    { manifest with
      phase_boundaries_by_case =
        List.filter (fun (k, _) -> k <> "success") manifest.phase_boundaries_by_case
    }
  in
  let summary_pb = check_observations ~manifest:manifest_without_pb ~observations:raw_obs in
  check bool "rejected when phase_boundaries missing from manifest" false summary_pb.overall_passed;
  check bool "finding for missing phase boundaries declaration recorded" true
    (List.exists (fun f -> contains_sub "missing_phase_boundaries_declaration" f.rule_id) summary_pb.findings);

  (* 5. Manifest missing expected_outcomes entry *)
  let manifest_without_eo =
    { manifest with
      expected_outcomes =
        List.filter (fun (k, _) -> k <> "success") manifest.expected_outcomes
    }
  in
  let summary_eo = check_observations ~manifest:manifest_without_eo ~observations:raw_obs in
  check bool "rejected when expected_outcomes missing from manifest" false summary_eo.overall_passed;
  check bool "finding for missing expected outcome declaration recorded" true
    (List.exists (fun f -> contains_sub "missing_expected_outcome_declaration" f.rule_id) summary_eo.findings)
;;

let test_manifest_and_observations_file_io () =
  let manifest_file = Filename.temp_file "g1-manifest" ".json" in
  let runs_file = Filename.temp_file "g1-runs" ".jsonl" in
  let checker_file = Filename.temp_file "g1-checker" ".json" in
  let summary_file = Filename.temp_file "g1-summary" ".json" in

  let manifest =
    make_manifest
      ~contract_sha256:"contract-sha-io"
      ~source_commit:"commit-sha-io"
      ~binary_sha256:"bin-sha-io"
      ~runtime_config_sha256:"cfg-sha-io"
      ~model_identity:"claude-io"
      ~workload_revision:"rev-io"
      ~execution_mode:"matrix"
  in
  let manifest_json_str = Yojson.Safe.pretty_to_string (manifest_to_json manifest) in
  let oc_m = open_out manifest_file in
  output_string oc_m manifest_json_str;
  close_out oc_m;

  let raw_obs = generate_compliant_observations () in
  let oc_r = open_out runs_file in
  List.iter
    (fun o ->
       output_string oc_r (Yojson.Safe.to_string (run_observation_to_json o) ^ "\n"))
    raw_obs;
  close_out oc_r;

  (match load_manifest_file manifest_file with
   | Error err -> fail ("load_manifest_file failed: " ^ err)
   | Ok loaded_manifest ->
     check string "manifest contract sha parity" manifest.contract_sha256 loaded_manifest.contract_sha256;
     check int "manifest case ids count" 6 (List.length loaded_manifest.case_ids);
     match load_observations_file runs_file with
     | Error err -> fail ("load_observations_file failed: " ^ err)
     | Ok loaded_obs ->
       check int "observations count matches" 31 (List.length loaded_obs);
       let summary = check_observations ~manifest:loaded_manifest ~observations:loaded_obs in
       check bool "overall passed from loaded files" true summary.overall_passed;
       (match write_checker_file checker_file summary with
        | Error err -> fail ("write_checker_file failed: " ^ err)
        | Ok () ->
          check bool "checker.json exists" true (Sys.file_exists checker_file);
          match write_summary_file summary_file summary with
          | Error err -> fail ("write_summary_file failed: " ^ err)
          | Ok () ->
            check bool "summary.json exists" true (Sys.file_exists summary_file);
            let checker_json = Yojson.Safe.from_file checker_file in
            (match checker_summary_of_json checker_json with
             | Error err -> fail ("decode checker.json failed: " ^ err)
             | Ok decoded_summary ->
               check bool "decoded checker overall passed" true decoded_summary.overall_passed;
               check int "decoded matrix observed" 18 decoded_summary.matrix_observed;
               check int "decoded live observed" 3 decoded_summary.live_observed)));

  (* Clean up temporary files *)
  (try Sys.remove checker_file with Sys_error _ -> ());
  (try Sys.remove summary_file with Sys_error _ -> ());
  (try Sys.remove runs_file with Sys_error _ -> ());
  (try Sys.remove manifest_file with Sys_error _ -> ())
;;

let test_strict_parsing_rejects_unknown_scope () =
  let json =
    `Assoc
      [ "case_id", `String "success"
      ; "repeat_index", `Int 1
      ; "run_id", `String "run-test"
      ; "execution_mode", `String "matrix"
      ; "usage_scope", `String "bogus-unknown-scope"
      ]
  in
  match run_observation_of_json json with
  | Ok _ -> fail "should fail on unknown usage_scope"
  | Error err ->
    check bool "error mentions invalid or unknown usage_scope" true
      (contains_sub "invalid or unknown usage_scope" err)
;;

let test_strict_parsing_rejects_unknown_scenario () =
  let json =
    `Assoc
      [ "case_id", `String "nonexistent-scenario"
      ; "repeat_index", `Int 1
      ; "run_id", `String "run-test"
      ; "execution_mode", `String "matrix"
      ]
  in
  match run_observation_of_json json with
  | Ok _ -> fail "should fail on unknown scenario"
  | Error err ->
    check bool "error mentions unknown scenario" true
      (contains_sub "unknown scenario" err)
;;

let test_type_error_caught_gracefully () =
  (* Pass integer where string is required: case_id = 123 *)
  let json =
    `Assoc
      [ "case_id", `Int 123
      ; "repeat_index", `Int 1
      ; "run_id", `String "run-test"
      ]
  in
  match run_observation_of_json json with
  | Ok _ -> fail "should fail on type error"
  | Error err ->
    check bool "error mentions JSON type error" true
      (contains_sub "JSON type error" err)
;;

let test_harness_output_decoding () =
  (* Real evidence row JSON as generated by scripts/harness_coding_eval.sh *)
  let json_str =
    {|{
      "case_id": "success",
      "run_index": 1,
      "run_id": "harness-run-42",
      "provider": "openrouter",
      "model": "deepseek-chat",
      "status": "ok",
      "verify_exit": 0,
      "regression_exit": 0,
      "edited_source_files": ["src/fix.ml"],
      "edited_target_files": ["src/target.ml"],
      "build_exit": 0,
      "passed": true,
      "duration_ms": 12500,
      "recorded_at": 1726000000,
      "tool_calls": ["bash", "edit"],
      "input_tokens": 1500,
      "output_tokens": 300,
      "cost_usd": 0.005,
      "error": null,
      "usage_scope": "cumulative-request-snapshot",
      "request_or_task_identity": "task-harness-run-42",
      "run_turn_attempt_identity": "harness-run-42-1",
      "target_revision": "deepseek-chat",
      "requested_revision": "deepseek-chat",
      "verdict_run_identity": "verdict-harness-run-42",
      "artifact_references": ["src/target.ml"],
      "execution_mode": "live"
    }|}
  in
  let json = Yojson.Safe.from_string json_str in
  match run_observation_of_json json with
  | Ok obs ->
    check string "case_id" "success" obs.case_id;
    check int "repeat_index" 1 obs.repeat_index;
    check string "run_id" "harness-run-42" obs.run_id;
    check (option string) "request_identity" (Some "task-harness-run-42") obs.request_or_task_identity;
    check bool "external_verified" true obs.external_verified;
    (match obs.usage with
     | Usage_reported r ->
       check int "input tokens" 1500 r.input_tokens;
       check int "output tokens" 300 r.output_tokens;
       (match r.cost_usd with
        | Some c -> check (float 1e-6) "cost" 0.005 c
        | None -> fail "cost missing")
     | Usage_missing _ -> fail "expected reported usage");
    check bool "scope matches" true (obs.usage_scope = Some Cumulative_request_snapshot)
  | Error err -> fail ("harness row decode failed: " ^ err)
;;

let test_roadmap_fixture_string_cost_decoding () =
  (* Roadmap JSON fixture with string decimal cost per Rule 75 *)
  let json_str =
    {|{
      "case_id": "retry-success",
      "run_index": 1,
      "request": "failed-attempt",
      "scope": "per-request",
      "input_tokens": 10,
      "output_tokens": 2,
      "cache_read_input_tokens": 3,
      "cost_usd": "0.01",
      "execution_mode": "matrix"
    }|}
  in
  let json = Yojson.Safe.from_string json_str in
  match run_observation_of_json json with
  | Ok obs ->
    (match obs.usage with
     | Usage_reported r ->
       check int "input" 10 r.input_tokens;
       check (option string) "cost exact" (Some "0.01") r.cost_usd_exact;
       (match r.cost_usd with
        | Some c -> check (float 1e-6) "cost float" 0.01 c
        | None -> fail "cost float missing")
     | Usage_missing _ -> fail "expected reported usage");
    check bool "scope parsed from 'scope' key" true (obs.usage_scope = Some Per_request)
  | Error err -> fail ("roadmap fixture decode failed: " ^ err)
;;

let test_roundtrip_observation () =
  let obs =
    make_dummy_observation
      ~case_id:"success"
      ~repeat_index:1
      ~run_id:"roundtrip-1"
      ~mode:"matrix"
      ~verified:true
      ~exit_code:(Some 0)
      ~usage:(Usage_reported { input_tokens = 100; output_tokens = 20; cache_read_input_tokens = 5; cost_usd = Some 0.02; cost_usd_exact = Some "0.02" })
      ~attempt_seq:1
  in
  let json = run_observation_to_json obs in
  match run_observation_of_json json with
  | Ok decoded ->
    check string "case_id" obs.case_id decoded.case_id;
    check int "repeat_index" obs.repeat_index decoded.repeat_index;
    check string "run_id" obs.run_id decoded.run_id;
    check bool "verified" obs.external_verified decoded.external_verified;
    check (option string) "request_id" obs.request_or_task_identity decoded.request_or_task_identity
  | Error err -> fail ("observation roundtrip failed: " ^ err)
;;

let () =
  run "Reliable_change_g1"
    [ ( "contract_parity"
      , [ test_case "manifest contract parity" `Quick test_manifest_contract_parity ]
      )
    ; ( "usage_aggregation"
      , [ test_case "exact fixture reconstruction" `Quick test_usage_aggregation_exact_fixture ]
      )
    ; ( "compliance_checker"
      , [ test_case "accepts compliant records" `Quick test_checker_accepts_compliant_records
        ; test_case "rejects verification failure in success" `Quick test_checker_rejects_verification_failure_in_success
        ; test_case "rejects duplicated usage" `Quick test_checker_rejects_duplicated_usage
        ; test_case "rejects missing matrix mode" `Quick test_checker_rejects_missing_matrix_mode
        ; test_case "deep manifest validation" `Quick test_checker_deep_manifest_validation
        ; test_case "manifest and observations file IO" `Quick test_manifest_and_observations_file_io
        ]
      )
    ; ( "strict_parsing"
      , [ test_case "rejects unknown usage scope" `Quick test_strict_parsing_rejects_unknown_scope
        ; test_case "rejects unknown scenario" `Quick test_strict_parsing_rejects_unknown_scenario
        ; test_case "type error caught gracefully" `Quick test_type_error_caught_gracefully
        ; test_case "harness output decoding" `Quick test_harness_output_decoding
        ; test_case "roadmap fixture string cost decoding" `Quick test_roadmap_fixture_string_cost_decoding
        ; test_case "observation roundtrip" `Quick test_roundtrip_observation
        ]
      )
    ]
;;
