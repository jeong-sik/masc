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
      test_case "git status clean" `Quick test_git_status_clean_exact;
      test_case "git status dirty" `Quick test_git_status_dirty_exact;
    ]);
    ("wire", [
      test_case "marker_to_string stable" `Quick test_marker_wire_format;
    ]);
  ]
