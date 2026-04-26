(** test_cdal_friction_projection -- Unit tests for Cdal_friction_projection.

    Tests single-run friction projection from v1 mode_violations.json
    evidence: grouping, counts, determinism, missing-file handling,
    and v1-only field constraint. *)

module CFP = Masc_mcp.Cdal_friction_projection

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_proof ?(run_id = "friction-test-001") ?(raw_evidence_refs = []) ()
  : Agent_sdk.Cdal_proof.t
  =
  { schema_version = Agent_sdk.Cdal_proof.schema_version_current
  ; run_id
  ; contract_id = "md5:test"
  ; requested_execution_mode = Execute
  ; effective_execution_mode = Execute
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
  ; raw_evidence_refs
  ; checkpoint_ref = None
  ; result_status = Completed
  ; started_at = 1000.0
  ; ended_at = 1001.0
  ; scope = None
  }
;;

let setup_store () =
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "cdal_friction_%d_%d"
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

let write_violations_file
      (store : Agent_sdk.Proof_store.config)
      ~run_id
      (violations : Yojson.Safe.t)
  =
  let dir =
    Filename.concat
      (Filename.concat (Filename.concat store.root "proofs") run_id)
      "evidence"
  in
  mkdirp dir;
  let path = Filename.concat dir "mode_violations.json" in
  Yojson.Safe.to_file path violations
;;

let make_violation ~tool_name ~violation_kind ~effective_mode : Yojson.Safe.t =
  `Assoc
    [ "ts", `Float 1000.0
    ; "tool_name", `String tool_name
    ; "input_summary", `String "truncated"
    ; "effective_mode", `String effective_mode
    ; "violation_kind", `String violation_kind
    ]
;;

let make_ref ~run_id =
  Printf.sprintf "proof-store://%s/evidence/mode_violations.json" run_id
;;

(* ================================================================ *)
(* Tests                                                             *)
(* ================================================================ *)

(** 3 violations, 2 groups expected:
    - (fs_edit, mutating_in_diagnose, diagnose) x 2
    - (shell_exec, external_in_draft, draft) x 1 *)
let test_single_run_with_violations () =
  let store, _dir = setup_store () in
  let run_id = "friction-test-001" in
  let ref_ = make_ref ~run_id in
  let violations =
    `List
      [ make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ; make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ; make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"external_in_draft"
          ~effective_mode:"draft"
      ]
  in
  write_violations_file store ~run_id violations;
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_single_run ~store proof with
  | None -> Alcotest.fail "expected Some, got None"
  | Some fp ->
    Alcotest.(check string) "window" "single_run" fp.window;
    Alcotest.(check (list string)) "based_on_run_ids" [ run_id ] fp.based_on_run_ids;
    Alcotest.(check int) "blocked_attempt_count" 3 fp.blocked_attempt_count;
    Alcotest.(check int) "group count" 2 (List.length fp.blocked_attempt_groups);
    (* Groups are sorted: fs_edit < shell_exec *)
    let g0 = List.nth fp.blocked_attempt_groups 0 in
    let g1 = List.nth fp.blocked_attempt_groups 1 in
    Alcotest.(check string) "g0 tool" "fs_edit" g0.key.tool_name;
    Alcotest.(check string) "g0 vk" "mutating_in_diagnose" g0.key.violation_kind;
    Alcotest.(check string) "g0 mode" "diagnose" g0.key.effective_mode;
    Alcotest.(check int) "g0 count" 2 g0.count;
    Alcotest.(check string) "g1 tool" "shell_exec" g1.key.tool_name;
    Alcotest.(check string) "g1 vk" "external_in_draft" g1.key.violation_kind;
    Alcotest.(check string) "g1 mode" "draft" g1.key.effective_mode;
    Alcotest.(check int) "g1 count" 1 g1.count
;;

(** Empty violations array returns None. *)
let test_no_violations_returns_none () =
  let store, _dir = setup_store () in
  let run_id = "friction-empty-001" in
  let ref_ = make_ref ~run_id in
  write_violations_file store ~run_id (`List []);
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_single_run ~store proof with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for empty violations"
;;

(** No mode_violations.json ref in raw_evidence_refs returns None. *)
let test_missing_file_returns_none () =
  let store, _dir = setup_store () in
  let run_id = "friction-missing-001" in
  (* No violations ref at all *)
  let proof = make_proof ~run_id ~raw_evidence_refs:[] () in
  (match CFP.project_single_run ~store proof with
   | None -> ()
   | Some _ -> Alcotest.fail "expected None for missing ref");
  (* Ref exists but file does not *)
  let ref_ = make_ref ~run_id in
  let proof2 = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_single_run ~store proof2 with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for missing file on disk"
;;

(** Verify output JSON contains only v1 fields: tool_name, violation_kind,
    effective_mode in the key. No v2 fields like effect_class,
    required_min_mode, violated_rule_id, trace_id, turn. *)
let test_v1_fields_only () =
  let store, _dir = setup_store () in
  let run_id = "friction-v1-001" in
  let ref_ = make_ref ~run_id in
  let violations =
    `List
      [ make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ]
  in
  write_violations_file store ~run_id violations;
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_single_run ~store proof with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    let json_str = Yojson.Safe.to_string (CFP.to_json fp) in
    let v2_fields =
      [ "effect_class"; "required_min_mode"; "violated_rule_id"; "trace_id"; "turn" ]
    in
    List.iter
      (fun field ->
         if String.length json_str > 0
         then (
           let pattern = Printf.sprintf "\"%s\"" field in
           let found =
             try
               let _ = Str.search_forward (Str.regexp_string pattern) json_str 0 in
               true
             with
             | Not_found -> false
           in
           if found
           then Alcotest.fail (Printf.sprintf "v2 field '%s' found in output" field)))
      v2_fields
;;

(** Same input produces identical basis_hash and group ordering. *)
let test_deterministic_output () =
  let store, _dir = setup_store () in
  let run_id = "friction-det-001" in
  let ref_ = make_ref ~run_id in
  let violations =
    `List
      [ make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"scope_violation"
          ~effective_mode:"execute"
      ; make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ]
  in
  write_violations_file store ~run_id violations;
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  let r1 = CFP.project_single_run ~store proof in
  let r2 = CFP.project_single_run ~store proof in
  match r1, r2 with
  | Some fp1, Some fp2 ->
    let j1 = Yojson.Safe.to_string (CFP.to_json fp1) in
    let j2 = Yojson.Safe.to_string (CFP.to_json fp2) in
    Alcotest.(check string) "deterministic JSON" j1 j2;
    Alcotest.(check string) "same basis_hash" fp1.basis_hash fp2.basis_hash
  | _ -> Alcotest.fail "expected two Some results"
;;

(** Multiple distinct (tool_name, violation_kind, effective_mode) combos
    produce separate groups with correct counts. *)
let test_multiple_groups () =
  let store, _dir = setup_store () in
  let run_id = "friction-multi-001" in
  let ref_ = make_ref ~run_id in
  let violations =
    `List
      [ make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ; make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"external_in_draft"
          ~effective_mode:"draft"
      ; make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"scope_violation"
          ~effective_mode:"execute"
      ; make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ; make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"external_in_draft"
          ~effective_mode:"draft"
      ; make_violation
          ~tool_name:"shell_exec"
          ~violation_kind:"external_in_draft"
          ~effective_mode:"draft"
      ]
  in
  write_violations_file store ~run_id violations;
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_single_run ~store proof with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    Alcotest.(check int) "total blocked" 6 fp.blocked_attempt_count;
    Alcotest.(check int) "group count" 3 (List.length fp.blocked_attempt_groups);
    (* Groups sorted: fs_edit/mutating < shell_exec/external < shell_exec/scope *)
    let g0 = List.nth fp.blocked_attempt_groups 0 in
    let g1 = List.nth fp.blocked_attempt_groups 1 in
    let g2 = List.nth fp.blocked_attempt_groups 2 in
    Alcotest.(check string) "g0 tool" "fs_edit" g0.key.tool_name;
    Alcotest.(check int) "g0 count" 2 g0.count;
    Alcotest.(check string) "g1 tool" "shell_exec" g1.key.tool_name;
    Alcotest.(check string) "g1 vk" "external_in_draft" g1.key.violation_kind;
    Alcotest.(check int) "g1 count" 3 g1.count;
    Alcotest.(check string) "g2 tool" "shell_exec" g2.key.tool_name;
    Alcotest.(check string) "g2 vk" "scope_violation" g2.key.violation_kind;
    Alcotest.(check int) "g2 count" 1 g2.count
;;

(* ================================================================ *)
(* Phase-1B tests: new fields                                        *)
(* ================================================================ *)

let test_blocked_tool_counts () =
  let store, _tmp = setup_store () in
  let run_id = "btc-test-001" in
  let ref_ = Printf.sprintf "proof-store://%s/evidence/mode_violations.json" run_id in
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  let dir =
    Filename.concat
      (Filename.concat store.root "proofs")
      (Filename.concat run_id "evidence")
  in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" dir));
  let violations =
    `List
      [ `Assoc
          [ "ts", `Float 1.0
          ; "tool_name", `String "write"
          ; "input_summary", `String ""
          ; "effective_mode", `String "diagnose"
          ; "violation_kind", `String "mutating_in_diagnose"
          ]
      ; `Assoc
          [ "ts", `Float 2.0
          ; "tool_name", `String "write"
          ; "input_summary", `String ""
          ; "effective_mode", `String "diagnose"
          ; "violation_kind", `String "mutating_in_diagnose"
          ]
      ; `Assoc
          [ "ts", `Float 3.0
          ; "tool_name", `String "bash"
          ; "input_summary", `String ""
          ; "effective_mode", `String "diagnose"
          ; "violation_kind", `String "mutating_in_diagnose"
          ]
      ]
  in
  let path = Filename.concat dir "mode_violations.json" in
  Yojson.Safe.to_file path violations;
  match CFP.project_single_run ~store proof with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    Alcotest.(check int) "blocked_attempt_count" 3 fp.blocked_attempt_count;
    let tool_counts = fp.blocked_tool_counts in
    Alcotest.(check int) "2 tools" 2 (List.length tool_counts);
    let bash_count = List.assoc "bash" tool_counts in
    let write_count = List.assoc "write" tool_counts in
    Alcotest.(check int) "bash count" 1 bash_count;
    Alcotest.(check int) "write count" 2 write_count
;;

let test_evidence_gap_groups () =
  let store, _tmp = setup_store () in
  let proof = make_proof ~run_id:"gap-test-001" () in
  let gaps : Masc_mcp.Cdal_types.completeness_gap list =
    [ { artifact = "manifest.json"; reason = "not found"; impact = Blocks_verdict }
    ; { artifact = "contract.json"; reason = "parse error"; impact = Annotation_only }
    ]
  in
  match CFP.project_single_run ~store ~completeness_gaps:gaps proof with
  | None -> Alcotest.fail "expected Some (has gaps)"
  | Some fp ->
    Alcotest.(check int) "2 gap groups" 2 (List.length fp.evidence_gap_groups);
    let g0 = List.hd fp.evidence_gap_groups in
    Alcotest.(check string) "gap artifact" "manifest.json" g0.artifact;
    Alcotest.(check string) "gap impact" "blocks_verdict" g0.impact
;;

let test_review_gap_emits_tripwire () =
  let store, _tmp = setup_store () in
  let proof = make_proof ~run_id:"review-gap-001" () in
  let gaps : Masc_mcp.Cdal_types.completeness_gap list =
    [ { artifact = "evidence/review_warning.json"
      ; reason = "review_requirement present but no review evidence artifact was captured"
      ; impact = Blocks_verdict
      }
    ]
  in
  match CFP.project_single_run ~store ~completeness_gaps:gaps proof with
  | None -> Alcotest.fail "expected Some (has review gap)"
  | Some fp ->
    Alcotest.(check (list string))
      "review tripwire"
      [ "review_requirement:submit_for_verification" ]
      fp.review_tripwires
;;

let test_tripwire_fires () =
  let store, _tmp = setup_store () in
  let run_id = "tw-test-001" in
  let ref_ = Printf.sprintf "proof-store://%s/evidence/mode_violations.json" run_id in
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  let dir =
    Filename.concat
      (Filename.concat store.root "proofs")
      (Filename.concat run_id "evidence")
  in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" dir));
  (* 3 identical violations for "write" — threshold=2 should fire *)
  let v =
    `Assoc
      [ "ts", `Float 1.0
      ; "tool_name", `String "write"
      ; "input_summary", `String ""
      ; "effective_mode", `String "diagnose"
      ; "violation_kind", `String "mutating_in_diagnose"
      ]
  in
  Yojson.Safe.to_file (Filename.concat dir "mode_violations.json") (`List [ v; v; v ]);
  match CFP.project_single_run ~store ~tripwire_threshold:2 proof with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    Alcotest.(check bool) "has tripwire" true (List.length fp.review_tripwires > 0);
    let tw = List.hd fp.review_tripwires in
    Alcotest.(check bool)
      "contains write"
      true
      (String.length tw > 0 && String.sub tw 0 18 = "blocked_attempts:w")
;;

let test_tripwire_below_threshold () =
  let store, _tmp = setup_store () in
  let run_id = "tw-below-001" in
  let ref_ = Printf.sprintf "proof-store://%s/evidence/mode_violations.json" run_id in
  let proof = make_proof ~run_id ~raw_evidence_refs:[ ref_ ] () in
  let dir =
    Filename.concat
      (Filename.concat store.root "proofs")
      (Filename.concat run_id "evidence")
  in
  ignore (Sys.command (Printf.sprintf "mkdir -p %s" dir));
  let v =
    `Assoc
      [ "ts", `Float 1.0
      ; "tool_name", `String "write"
      ; "input_summary", `String ""
      ; "effective_mode", `String "diagnose"
      ; "violation_kind", `String "mutating_in_diagnose"
      ]
  in
  Yojson.Safe.to_file (Filename.concat dir "mode_violations.json") (`List [ v; v ]);
  match CFP.project_single_run ~store ~tripwire_threshold:5 proof with
  | None -> Alcotest.fail "expected Some"
  | Some fp -> Alcotest.(check int) "no tripwires" 0 (List.length fp.review_tripwires)
;;

let test_path_traversal_rejected () =
  let store : Agent_sdk.Proof_store.config = { root = "/tmp/test-store" } in
  let result =
    Masc_mcp.Proof_artifact_reader.resolve_path store "proof-store://../../../etc/passwd"
  in
  match result with
  | Error msg -> Alcotest.(check bool) "contains rejected" true (String.length msg > 0)
  | Ok path -> Alcotest.fail (Printf.sprintf "should reject, got Ok: %s" path)
;;

(* ================================================================ *)
(* Cross-run window tests                                            *)
(* ================================================================ *)

let make_proof_for_cross_run
      ?(run_id = "cr-001")
      ?(raw_evidence_refs = [])
      ?(ended_at = 1001.0)
      ()
  : Agent_sdk.Cdal_proof.t
  =
  { schema_version = Agent_sdk.Cdal_proof.schema_version_current
  ; run_id
  ; contract_id = "md5:test"
  ; requested_execution_mode = Execute
  ; effective_execution_mode = Execute
  ; mode_decision_source = "passthrough"
  ; risk_class = Agent_sdk.Risk_class.Low
  ; provider_snapshot =
      { provider_name = "test"; model_id = "test-model"; api_version = None }
  ; capability_snapshot =
      { tools = [ "read" ]
      ; mcp_servers = []
      ; max_turns = 10
      ; max_tokens = Some 4096
      ; thinking_enabled = None
      }
  ; tool_trace_refs = []
  ; raw_evidence_refs
  ; checkpoint_ref = None
  ; result_status = Completed
  ; started_at = ended_at -. 1.0
  ; ended_at
  ; scope = None
  }
;;

let test_project_window_single_run () =
  let store, _dir = setup_store () in
  let run_id = "cr-single-001" in
  let ref_ = make_ref ~run_id in
  let violations =
    `List
      [ make_violation
          ~tool_name:"fs_edit"
          ~violation_kind:"mutating_in_diagnose"
          ~effective_mode:"diagnose"
      ]
  in
  write_violations_file store ~run_id violations;
  let proof = make_proof_for_cross_run ~run_id ~raw_evidence_refs:[ ref_ ] () in
  match CFP.project_window ~store ~window:CFP.Single_run [ proof ] with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    Alcotest.(check string) "window" "single_run" fp.window;
    Alcotest.(check int) "blocked" 1 fp.blocked_attempt_count
;;

let test_project_window_last_n_runs () =
  let store, _dir = setup_store () in
  (* 3 runs, each with 2 violations of the same type *)
  let proofs =
    List.init 3 (fun i ->
      let run_id = Printf.sprintf "cr-last-%d" i in
      let ref_ = make_ref ~run_id in
      let violations =
        `List
          [ make_violation
              ~tool_name:"fs_edit"
              ~violation_kind:"mutating_in_diagnose"
              ~effective_mode:"diagnose"
          ; make_violation
              ~tool_name:"fs_edit"
              ~violation_kind:"mutating_in_diagnose"
              ~effective_mode:"diagnose"
          ]
      in
      write_violations_file store ~run_id violations;
      make_proof_for_cross_run
        ~run_id
        ~raw_evidence_refs:[ ref_ ]
        ~ended_at:(1000.0 +. Float.of_int i)
        ())
  in
  match CFP.project_window ~store ~window:(CFP.Last_n_runs 3) proofs with
  | None -> Alcotest.fail "expected Some for cross-run"
  | Some fp ->
    Alcotest.(check string) "window" "last_3_runs" fp.window;
    Alcotest.(check int) "3 run ids" 3 (List.length fp.based_on_run_ids);
    (* 3 runs x 2 violations = 6 total, all same group *)
    Alcotest.(check int) "blocked_attempt_count" 6 fp.blocked_attempt_count;
    Alcotest.(check int) "1 merged group" 1 (List.length fp.blocked_attempt_groups)
;;

let test_project_window_tripwire_cross_run () =
  let store, _dir = setup_store () in
  (* 5 runs, each with 2 violations — total 10, threshold 5 should trip *)
  let proofs =
    List.init 5 (fun i ->
      let run_id = Printf.sprintf "cr-tw-%d" i in
      let ref_ = make_ref ~run_id in
      let violations =
        `List
          [ make_violation
              ~tool_name:"fs_edit"
              ~violation_kind:"mutating_in_diagnose"
              ~effective_mode:"diagnose"
          ; make_violation
              ~tool_name:"fs_edit"
              ~violation_kind:"mutating_in_diagnose"
              ~effective_mode:"diagnose"
          ]
      in
      write_violations_file store ~run_id violations;
      make_proof_for_cross_run
        ~run_id
        ~raw_evidence_refs:[ ref_ ]
        ~ended_at:(1000.0 +. Float.of_int i)
        ())
  in
  match
    CFP.project_window ~store ~window:(CFP.Last_n_runs 5) ~tripwire_threshold:5 proofs
  with
  | None -> Alcotest.fail "expected Some"
  | Some fp ->
    Alcotest.(check bool) "tripwire fires" true (List.length fp.review_tripwires > 0);
    Alcotest.(check int) "10 total" 10 fp.blocked_attempt_count
;;

let test_project_window_empty () =
  let store, _dir = setup_store () in
  match CFP.project_window ~store ~window:(CFP.Last_n_runs 3) [] with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for empty proofs"
;;

let test_basis_hash_deterministic () =
  let h1 =
    CFP.compute_window_basis_hash ~window:(CFP.Last_n_runs 3) ~run_ids:[ "a"; "b"; "c" ]
  in
  let h2 =
    CFP.compute_window_basis_hash ~window:(CFP.Last_n_runs 3) ~run_ids:[ "c"; "a"; "b" ]
  in
  Alcotest.(check string) "same hash regardless of order" h1 h2
;;

let test_basis_hash_changes_with_window () =
  let h1 = CFP.compute_window_basis_hash ~window:(CFP.Last_n_runs 3) ~run_ids:[ "a" ] in
  let h2 = CFP.compute_window_basis_hash ~window:(CFP.Last_n_runs 5) ~run_ids:[ "a" ] in
  Alcotest.(check bool) "different window = different hash" true (h1 <> h2)
;;

let test_window_to_string () =
  Alcotest.(check string) "single" "single_run" (CFP.window_to_string CFP.Single_run);
  Alcotest.(check string)
    "last 5"
    "last_5_runs"
    (CFP.window_to_string (CFP.Last_n_runs 5));
  Alcotest.(check string)
    "session"
    "session:abc"
    (CFP.window_to_string (CFP.Session "abc"));
  Alcotest.(check string)
    "rolling"
    "rolling_3600s"
    (CFP.window_to_string (CFP.Rolling_seconds 3600.0))
;;

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

let () =
  Alcotest.run
    "Cdal_friction_projection"
    [ ( "project_single_run"
      , [ Alcotest.test_case "with violations" `Quick test_single_run_with_violations
        ; Alcotest.test_case
            "no violations returns None"
            `Quick
            test_no_violations_returns_none
        ; Alcotest.test_case
            "missing file returns None"
            `Quick
            test_missing_file_returns_none
        ; Alcotest.test_case "v1 fields only" `Quick test_v1_fields_only
        ; Alcotest.test_case "deterministic output" `Quick test_deterministic_output
        ; Alcotest.test_case "multiple groups" `Quick test_multiple_groups
        ] )
    ; ( "phase1b"
      , [ Alcotest.test_case "blocked tool counts" `Quick test_blocked_tool_counts
        ; Alcotest.test_case "evidence gap groups" `Quick test_evidence_gap_groups
        ; Alcotest.test_case
            "review gap emits tripwire"
            `Quick
            test_review_gap_emits_tripwire
        ; Alcotest.test_case "tripwire fires" `Quick test_tripwire_fires
        ; Alcotest.test_case
            "tripwire below threshold"
            `Quick
            test_tripwire_below_threshold
        ; Alcotest.test_case "path traversal rejected" `Quick test_path_traversal_rejected
        ] )
    ; ( "cross_run"
      , [ Alcotest.test_case
            "single run via project_window"
            `Quick
            test_project_window_single_run
        ; Alcotest.test_case
            "last_n_runs aggregation"
            `Quick
            test_project_window_last_n_runs
        ; Alcotest.test_case
            "cross-run tripwire"
            `Quick
            test_project_window_tripwire_cross_run
        ; Alcotest.test_case "empty proofs" `Quick test_project_window_empty
        ; Alcotest.test_case
            "basis hash deterministic"
            `Quick
            test_basis_hash_deterministic
        ; Alcotest.test_case
            "basis hash changes with window"
            `Quick
            test_basis_hash_changes_with_window
        ; Alcotest.test_case "window_to_string" `Quick test_window_to_string
        ] )
    ]
;;
