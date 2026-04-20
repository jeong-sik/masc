(* P6 Tick 15: Cdal_judge.of_exec_outcome verifiable marker tests.

   Covers the four domain classifiers (test / build / lint / git)
   plus the pass-through semantics for terminal states the plan
   declares non-emitting (timeout, signaled, policy_denied, etc.). *)

open Alcotest
open Masc_mcp

let marker_list : Cdal_judge.verifiable_marker list testable =
  let pp fmt ms =
    Format.fprintf fmt "[%s]"
      (String.concat "; " (List.map Cdal_judge.marker_to_string ms))
  in
  let eq a b =
    List.length a = List.length b
    && List.for_all2
         (fun x y -> Cdal_judge.marker_to_string x = Cdal_judge.marker_to_string y)
         a b
  in
  testable pp eq

let call ?(stdout = "") ?(stderr = "") semantic =
  Cdal_judge.of_exec_outcome ~semantic ~stdout ~stderr

let test_git_not_a_repo_exact () =
  check marker_list "single Git_not_a_repo marker"
    [ Cdal_judge.Git_not_a_repo ]
    (call `Git_not_a_repo)

let test_ok_with_nothing_known_emits_empty () =
  check marker_list "unknown producer yields []"
    []
    (call ~stdout:"hello world" `Ok)

let test_dune_build_ok_heuristic () =
  let stdout = "[dune build] compiling lib/foo.ml\nocamlopt -c lib/foo.ml\n" in
  match call ~stdout `Ok with
  | [ Cdal_judge.Build_ok { confidence = `Heuristic } ] -> ()
  | other ->
      fail ("expected Build_ok heuristic, got "
            ^ String.concat ","
                (List.map Cdal_judge.marker_to_string other))

let test_dune_build_fail_heuristic () =
  let stdout = "dune build\nError: this expression has type int\n" in
  match call ~stdout (`Fail 1) with
  | [ Cdal_judge.Build_fail { confidence = `Heuristic } ] -> ()
  | _ -> fail "expected Build_fail"

let test_alcotest_pass_counts () =
  let stdout =
    "Testing `exec_buffer'.\nThis run has ID `abc`.\n\
     exec_buffer\n  SUCCESS\n\n\
     Full test results in `/tmp/test-out`.\n\
     Test Successful in 0.003s. 8 tests run.\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Test_pass { count = 8; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_pass { count; _ } ] ->
      fail (Printf.sprintf "expected count=8, got %d" count)
  | _ -> fail "expected Test_pass marker"

let test_pytest_pass_counts () =
  let stdout =
    "===== test session starts =====\n\
     platform darwin -- Python 3.12\n\
     collected 12 items\n\n\
     tests/test_a.py ............                            [100%]\n\n\
     ===== 12 passed in 0.45s =====\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Test_pass { count = 12; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_pass { count; _ } ] ->
      fail (Printf.sprintf "expected pytest count=12, got %d" count)
  | _ -> fail "expected Test_pass marker from pytest output"

let test_pytest_fail_counts () =
  let stdout =
    "===== test session starts =====\n\
     collected 10 items\n\n\
     tests/test_b.py FFFFF.....                              [100%]\n\n\
     ===== 5 failed, 5 passed in 1.23s =====\n"
  in
  match call ~stdout (`Fail 1) with
  | [ Cdal_judge.Test_fail { count = 5; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_fail { count; _ } ] ->
      fail (Printf.sprintf "expected pytest failed=5, got %d" count)
  | _ -> fail "expected Test_fail marker from pytest output"

let test_pytest_banner_required () =
  (* Bare "12 passed" without the "=====" banner must NOT classify as
     pytest — the summary-line anchor prevents false positives where
     source code, docstrings, or framework prose mention "N passed". *)
  let stdout =
    "some log output mentioning 12 passed tests in passing\n"
  in
  match call ~stdout `Ok with
  | [] -> ()
  | markers ->
      fail ("expected [] without pytest banner, got "
            ^ String.concat ","
                (List.map Cdal_judge.marker_to_string markers))

let test_go_test_pass_counts () =
  let stdout =
    "=== RUN   TestA\n\
     --- PASS: TestA (0.00s)\n\
     === RUN   TestB\n\
     --- PASS: TestB (0.01s)\n\
     === RUN   TestC\n\
     --- PASS: TestC (0.00s)\n\
     PASS\n\
     ok   example.com/pkg    0.023s\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Test_pass { count = 3; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_pass { count; _ } ] ->
      fail (Printf.sprintf "expected go test count=3, got %d" count)
  | _ -> fail "expected Test_pass marker from go test output"

let test_go_test_fail_counts () =
  let stdout =
    "=== RUN   TestA\n\
     --- FAIL: TestA (0.00s)\n\
         test_a.go:10: expected 1, got 2\n\
     === RUN   TestB\n\
     --- FAIL: TestB (0.00s)\n\
     === RUN   TestC\n\
     --- PASS: TestC (0.00s)\n\
     FAIL\n\
     exit status 1\n\
     FAIL   example.com/pkg   0.012s\n"
  in
  match call ~stdout (`Fail 1) with
  | [ Cdal_judge.Test_fail { count = 2; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_fail { count; _ } ] ->
      fail (Printf.sprintf "expected go test failed=2, got %d" count)
  | _ -> fail "expected Test_fail marker from go test output"

let test_go_test_banner_required () =
  (* Bare "PASS" / "FAIL" words in prose must NOT classify as go test —
     the "--- PASS:" / "--- FAIL:" / "=== RUN" preface is required. *)
  let stdout =
    "doc: the test passed successfully\n\
     user-visible result: PASS\n"
  in
  match call ~stdout `Ok with
  | [] -> ()
  | markers ->
      fail ("expected [] without go test preface, got "
            ^ String.concat ","
                (List.map Cdal_judge.marker_to_string markers))

let test_jest_pass_counts () =
  let stdout =
    "PASS src/component.test.ts\n\
     PASS src/other.test.ts\n\n\
     Test Suites: 2 passed, 2 total\n\
     Tests:       7 passed, 7 total\n\
     Snapshots:   0 total\n\
     Time:        1.234 s\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Test_pass { count = 7; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_pass { count; _ } ] ->
      fail (Printf.sprintf "expected jest count=7, got %d" count)
  | _ -> fail "expected Test_pass marker from jest output"

let test_jest_fail_counts () =
  let stdout =
    "FAIL src/component.test.ts\n\n\
     Test Suites: 1 failed, 1 passed, 2 total\n\
     Tests:       2 failed, 5 passed, 7 total\n\
     Snapshots:   0 total\n"
  in
  match call ~stdout (`Fail 1) with
  | [ Cdal_judge.Test_fail { count = 2; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_fail { count; _ } ] ->
      fail (Printf.sprintf "expected jest failed=2, got %d" count)
  | _ -> fail "expected Test_fail marker from jest output"

let test_vitest_pass_counts () =
  let stdout =
    " \xe2\x9c\x93 src/foo.test.ts (3)\n\
     \xe2\x9c\x93 src/bar.test.ts (2)\n\n\
     Test Files  2 passed (2)\n\
     \x20\x20    Tests  5 passed (5)\n\
     \x20   Start at  10:00:00\n\
     \x20Duration  0.50s\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Test_pass { count = 5; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_pass { count; _ } ] ->
      fail (Printf.sprintf "expected vitest count=5, got %d" count)
  | _ -> fail "expected Test_pass marker from vitest output"

let test_vitest_fail_counts () =
  let stdout =
    " \xe2\x9d\xaf src/foo.test.ts (3)\n\
     \x20\x20 \xc3\x97 test 1\n\n\
     Test Files  1 failed | 1 passed (2)\n\
     \x20    Tests  2 failed | 3 passed (5)\n\
     \x20 Duration  0.50s\n"
  in
  match call ~stdout (`Fail 1) with
  | [ Cdal_judge.Test_fail { count = 2; confidence = `Heuristic } ] -> ()
  | [ Cdal_judge.Test_fail { count; _ } ] ->
      fail (Printf.sprintf "expected vitest failed=2, got %d" count)
  | _ -> fail "expected Test_fail marker from vitest output"

let test_jest_vitest_banner_required () =
  (* Bare prose containing "Tests" / "passed" without the "Test Suites:"
     (jest) or "Test Files " (vitest) banner must NOT classify — the
     banner is the runner-specific fingerprint. *)
  let stdout =
    "doc: the Tests passed successfully on all 12 runs\n\
     user-visible result: Tests complete\n"
  in
  match call ~stdout `Ok with
  | [] -> ()
  | markers ->
      fail ("expected [] without jest/vitest banner, got "
            ^ String.concat ","
                (List.map Cdal_judge.marker_to_string markers))

let test_git_status_clean_exact () =
  let stdout = "On branch main\nnothing to commit, working tree clean\n" in
  match call ~stdout `Ok with
  | [ Cdal_judge.Git_clean { confidence = `Exact } ] -> ()
  | _ -> fail "expected Git_clean Exact"

let test_git_status_dirty_exact () =
  let stdout =
    "On branch main\nChanges not staged for commit:\n\tmodified: a.ml\n"
  in
  match call ~stdout `Ok with
  | [ Cdal_judge.Git_dirty { confidence = `Exact } ] -> ()
  | _ -> fail "expected Git_dirty Exact"

let test_timeout_emits_nothing () =
  check marker_list "timeout yields []" [] (call (`Timeout 5.0))

let test_policy_denied_emits_nothing () =
  check marker_list "policy_denied yields []" []
    (call (`Policy_denied "rm -rf /"))

let test_tool_missing_emits_nothing () =
  check marker_list "tool_missing yields []" []
    (call (`Tool_missing "cargo"))

let test_marker_wire_format () =
  check string "test_pass wire"
    "test_pass:3:heuristic"
    (Cdal_judge.marker_to_string
       (Cdal_judge.Test_pass { count = 3; confidence = `Heuristic }));
  check string "git_not_a_repo wire"
    "git_not_a_repo:exact"
    (Cdal_judge.marker_to_string Cdal_judge.Git_not_a_repo)

let () =
  run "cdal_verifiable_markers" [
    ("semantic_passthrough", [
      test_case "git_not_a_repo emits single marker" `Quick
        test_git_not_a_repo_exact;
      test_case "timeout emits nothing" `Quick test_timeout_emits_nothing;
      test_case "policy_denied emits nothing" `Quick
        test_policy_denied_emits_nothing;
      test_case "tool_missing emits nothing" `Quick
        test_tool_missing_emits_nothing;
    ]);
    ("classifiers", [
      test_case "unknown ok → []" `Quick test_ok_with_nothing_known_emits_empty;
      test_case "dune build ok" `Quick test_dune_build_ok_heuristic;
      test_case "dune build fail" `Quick test_dune_build_fail_heuristic;
      test_case "alcotest pass count" `Quick test_alcotest_pass_counts;
      test_case "pytest pass count" `Quick test_pytest_pass_counts;
      test_case "pytest fail count" `Quick test_pytest_fail_counts;
      test_case "pytest banner required" `Quick test_pytest_banner_required;
      test_case "go test pass count" `Quick test_go_test_pass_counts;
      test_case "go test fail count" `Quick test_go_test_fail_counts;
      test_case "go test banner required" `Quick test_go_test_banner_required;
      test_case "jest pass count" `Quick test_jest_pass_counts;
      test_case "jest fail count" `Quick test_jest_fail_counts;
      test_case "vitest pass count" `Quick test_vitest_pass_counts;
      test_case "vitest fail count" `Quick test_vitest_fail_counts;
      test_case "jest/vitest banner required" `Quick
        test_jest_vitest_banner_required;
      test_case "git status clean" `Quick test_git_status_clean_exact;
      test_case "git status dirty" `Quick test_git_status_dirty_exact;
    ]);
    ("wire", [
      test_case "marker_to_string stable" `Quick test_marker_wire_format;
    ]);
  ]
