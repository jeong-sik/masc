(** RFC-0199 Phase B unit tests for [Deterministic_evidence_evaluator].

    Stub deps cover all 6 evidence variants × success / fail / transient
    paths. Aggregation rules pinned (transient > hard > partial >
    all_satisfied). *)

open Alcotest
module E = Evidence_claim
module DEE = Deterministic_evidence_evaluator

(* ── default stub: every check is satisfied ───────────────────────── *)
let stub_all_pass : DEE.evaluator_deps =
  { gh_pr_check =
      (fun ~repo:_ ~pr_number:_ -> `Merged "2026-05-27T00:00:00Z")
  ; gh_ci_check = (fun ~repo:_ ~pr_number:_ -> `All_pass)
  ; exec_command = (fun ~command:_ ~timeout_sec:_ -> `Exit 0)
  ; file_stat = (fun ~path:_ -> `Exists 4096)
  ; custom_check = (fun ~id:_ ~payload:_ -> `Satisfied)
  }

let assert_all_satisfied result =
  match result with
  | DEE.All_satisfied -> ()
  | DEE.Partial _ -> fail "expected All_satisfied, got Partial"
  | DEE.Inconclusive { reason; transient } ->
    fail
      (Printf.sprintf
         "expected All_satisfied, got Inconclusive(transient=%b, %s)"
         transient
         reason)

let assert_partial ~expected_missing result =
  match result with
  | DEE.All_satisfied -> fail "expected Partial, got All_satisfied"
  | DEE.Partial { missing; _ } ->
    check int "missing count" expected_missing (List.length missing)
  | DEE.Inconclusive _ -> fail "expected Partial, got Inconclusive"

let assert_transient ~contains result =
  match result with
  | DEE.Inconclusive { transient = true; reason } ->
    if not (Astring.String.is_infix ~affix:contains reason) then
      fail
        (Printf.sprintf
           "transient reason %S does not contain %S"
           reason
           contains)
  | DEE.Inconclusive { transient = false; reason } ->
    fail
      (Printf.sprintf "expected transient, got hard inconclusive: %s" reason)
  | _ -> fail "expected Inconclusive transient"

let assert_hard ~contains result =
  match result with
  | DEE.Inconclusive { transient = false; reason } ->
    if not (Astring.String.is_infix ~affix:contains reason) then
      fail
        (Printf.sprintf "hard reason %S does not contain %S" reason contains)
  | DEE.Inconclusive { transient = true; reason } ->
    fail
      (Printf.sprintf "expected hard, got transient inconclusive: %s" reason)
  | _ -> fail "expected Inconclusive hard"

(* ── empty + all-pass baseline ────────────────────────────────────── *)
let test_empty_claims_satisfied () =
  assert_all_satisfied (DEE.evaluate ~deps:stub_all_pass ~claims:[])

let test_all_satisfied_six_variants () =
  let claims =
    [ E.PR_merged { repo = "o/r"; pr_number = 1 }
    ; E.CI_pass { repo = "o/r"; pr_number = 1 }
    ; E.Tests_pass { command = "true"; expected_exit = 0 }
    ; E.Artifact_exists { path = "/a"; min_bytes = Some 1024 }
    ; E.File_changed { path = "/b"; min_bytes = None }
    ; E.Custom_check { id = "lint_clean"; payload = `Null }
    ]
  in
  assert_all_satisfied (DEE.evaluate ~deps:stub_all_pass ~claims)

(* ── PR_merged ────────────────────────────────────────────────────── *)
let test_pr_open_is_transient () =
  let deps =
    { stub_all_pass with gh_pr_check = (fun ~repo:_ ~pr_number:_ -> `Open) }
  in
  let claims = [ E.PR_merged { repo = "o/r"; pr_number = 99 } ] in
  assert_transient ~contains:"is open" (DEE.evaluate ~deps ~claims)

let test_pr_closed_unmerged_is_partial () =
  let deps =
    { stub_all_pass with
      gh_pr_check = (fun ~repo:_ ~pr_number:_ -> `Closed_unmerged)
    }
  in
  let claims = [ E.PR_merged { repo = "o/r"; pr_number = 99 } ] in
  assert_partial ~expected_missing:1 (DEE.evaluate ~deps ~claims)

let test_pr_not_found_is_hard () =
  let deps =
    { stub_all_pass with
      gh_pr_check = (fun ~repo:_ ~pr_number:_ -> `Not_found)
    }
  in
  let claims = [ E.PR_merged { repo = "o/r"; pr_number = 99 } ] in
  assert_hard ~contains:"not found" (DEE.evaluate ~deps ~claims)

(* ── CI_pass ──────────────────────────────────────────────────────── *)
let test_ci_in_progress_is_transient () =
  let deps =
    { stub_all_pass with
      gh_ci_check = (fun ~repo:_ ~pr_number:_ -> `In_progress)
    }
  in
  let claims = [ E.CI_pass { repo = "o/r"; pr_number = 1 } ] in
  assert_transient ~contains:"in progress" (DEE.evaluate ~deps ~claims)

let test_ci_failing_is_partial () =
  let deps =
    { stub_all_pass with
      gh_ci_check =
        (fun ~repo:_ ~pr_number:_ -> `Any_fail [ "build"; "lint" ])
    }
  in
  let claims = [ E.CI_pass { repo = "o/r"; pr_number = 1 } ] in
  assert_partial ~expected_missing:1 (DEE.evaluate ~deps ~claims)

(* ── Tests_pass ────────────────────────────────────────────────────── *)
let test_tests_exit_mismatch_is_partial () =
  let deps =
    { stub_all_pass with
      exec_command = (fun ~command:_ ~timeout_sec:_ -> `Exit 1)
    }
  in
  let claims = [ E.Tests_pass { command = "dune test"; expected_exit = 0 } ] in
  assert_partial ~expected_missing:1 (DEE.evaluate ~deps ~claims)

let test_tests_timeout_is_transient () =
  let deps =
    { stub_all_pass with
      exec_command = (fun ~command:_ ~timeout_sec:_ -> `Timeout)
    }
  in
  let claims = [ E.Tests_pass { command = "dune test"; expected_exit = 0 } ] in
  assert_transient ~contains:"timed out" (DEE.evaluate ~deps ~claims)

(* ── Artifact_exists ──────────────────────────────────────────────── *)
let test_artifact_missing_is_partial () =
  let deps =
    { stub_all_pass with file_stat = (fun ~path:_ -> `Missing) }
  in
  let claims = [ E.Artifact_exists { path = "/x"; min_bytes = None } ] in
  assert_partial ~expected_missing:1 (DEE.evaluate ~deps ~claims)

let test_artifact_too_small_is_partial () =
  let deps =
    { stub_all_pass with file_stat = (fun ~path:_ -> `Exists 100) }
  in
  let claims =
    [ E.Artifact_exists { path = "/x"; min_bytes = Some 1024 } ]
  in
  assert_partial ~expected_missing:1 (DEE.evaluate ~deps ~claims)

(* ── Custom_check ─────────────────────────────────────────────────── *)
let test_custom_unknown_id_is_hard () =
  let deps =
    { stub_all_pass with
      custom_check = (fun ~id:_ ~payload:_ -> `Unknown_id)
    }
  in
  let claims =
    [ E.Custom_check { id = "no_such_check"; payload = `Null } ]
  in
  assert_hard ~contains:"allowlist" (DEE.evaluate ~deps ~claims)

(* ── Aggregation: transient > hard > partial ──────────────────────── *)
let test_transient_wins_over_partial () =
  let deps =
    { stub_all_pass with
      gh_pr_check = (fun ~repo:_ ~pr_number:_ -> `Open)
    ; file_stat = (fun ~path:_ -> `Missing)
    }
  in
  let claims =
    [ E.PR_merged { repo = "o/r"; pr_number = 1 }
    ; E.Artifact_exists { path = "/x"; min_bytes = None }
    ]
  in
  (* Open PR is transient; missing artifact would be Partial. Transient
     wins so caller retries before treating as a hard failure. *)
  assert_transient ~contains:"is open" (DEE.evaluate ~deps ~claims)

let test_hard_wins_over_partial () =
  let deps =
    { stub_all_pass with
      gh_pr_check = (fun ~repo:_ ~pr_number:_ -> `Not_found)
    ; file_stat = (fun ~path:_ -> `Missing)
    }
  in
  let claims =
    [ E.PR_merged { repo = "o/r"; pr_number = 1 }
    ; E.Artifact_exists { path = "/x"; min_bytes = None }
    ]
  in
  assert_hard ~contains:"not found" (DEE.evaluate ~deps ~claims)

let () =
  Alcotest.run
    "deterministic_evidence_evaluator"
    [ ( "baseline"
      , [ test_case "empty claims → All_satisfied" `Quick
            test_empty_claims_satisfied
        ; test_case "6 variants all satisfied" `Quick
            test_all_satisfied_six_variants
        ] )
    ; ( "pr_merged"
      , [ test_case "Open → transient" `Quick test_pr_open_is_transient
        ; test_case "Closed_unmerged → partial" `Quick
            test_pr_closed_unmerged_is_partial
        ; test_case "Not_found → hard" `Quick test_pr_not_found_is_hard
        ] )
    ; ( "ci_pass"
      , [ test_case "In_progress → transient" `Quick
            test_ci_in_progress_is_transient
        ; test_case "Any_fail → partial" `Quick test_ci_failing_is_partial
        ] )
    ; ( "tests_pass"
      , [ test_case "exit mismatch → partial" `Quick
            test_tests_exit_mismatch_is_partial
        ; test_case "Timeout → transient" `Quick test_tests_timeout_is_transient
        ] )
    ; ( "artifact_exists"
      , [ test_case "Missing → partial" `Quick test_artifact_missing_is_partial
        ; test_case "too small → partial" `Quick
            test_artifact_too_small_is_partial
        ] )
    ; ( "custom_check"
      , [ test_case "Unknown_id → hard" `Quick test_custom_unknown_id_is_hard
        ] )
    ; ( "aggregation"
      , [ test_case "transient wins over partial" `Quick
            test_transient_wins_over_partial
        ; test_case "hard wins over partial" `Quick test_hard_wins_over_partial
        ] )
    ]
;;
