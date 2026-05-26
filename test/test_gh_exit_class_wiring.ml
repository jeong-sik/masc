(* test/test_gh_exit_class_wiring.ml

   Verifies that the docker-sandbox JSON emission path calls
   [Shell_ir_github_exit.classify] for gh commands. Covers only the helper
   surface — the docker exec itself is out of scope for a unit test.

   The helper accepts typed shell stages only. These tests parse command
   strings locally to obtain stages, then exercise that typed contract. *)

module KSD = Masc_mcp.Keeper_sandbox_docker
module KSCS = Masc_mcp.Keeper_shell_command_semantics
module GEC = Masc_mcp.Shell_ir_github_exit

let stages_of cmd = KSCS.effective_stages_of_cmd cmd

let targets_gh cmd = KSCS.stages_targets_gh (stages_of cmd)

let test_stages_target_gh_positive () =
  Alcotest.(check bool) "gh pr list → true" true
    (targets_gh "gh pr list")

let test_stages_target_gh_negative () =
  Alcotest.(check bool) "git status → false" false
    (targets_gh "git status");
  Alcotest.(check bool) "cd /repo && gh pr view 1 → false" false
    (targets_gh "cd /repo && gh pr view 1");
  Alcotest.(check bool) "ls -la → false" false
    (targets_gh "ls -la");
  Alcotest.(check bool) "empty → false" false
    (targets_gh "")

let field_for ~cmd ~status ~output =
  KSD.gh_exit_class_field
    ~status ~output
    ~stages:(stages_of cmd)

let test_field_empty_for_non_gh () =
  let fields = field_for ~cmd:"git status" ~status:(Unix.WEXITED 0) ~output:"" in
  Alcotest.(check int) "no field emitted" 0 (List.length fields)

let test_field_ok_for_gh_exit_0 () =
  let fields = field_for ~cmd:"gh pr list" ~status:(Unix.WEXITED 0) ~output:"" in
  Alcotest.(check int) "one field emitted" 1 (List.length fields);
  (match fields with
   | [ ("shell_ir_github_exit", `String v) ] ->
     Alcotest.(check string) "Ok_0 payload"
       (GEC.to_string GEC.Ok_0) v
   | _ -> Alcotest.fail "unexpected field shape")

let test_field_auth_failed_from_combined_output () =
  let fields =
    field_for
      ~cmd:"gh api /user"
      ~status:(Unix.WEXITED 1)
      ~output:"HTTP 401: Bad credentials (https://api.github.com/user)"
  in
  (match fields with
   | [ ("shell_ir_github_exit", `String v) ] ->
     Alcotest.(check string) "Auth_failed payload"
       (GEC.to_string GEC.Auth_failed) v
   | _ -> Alcotest.fail "unexpected field shape")

let test_field_signal_maps_to_unknown () =
  let fields =
    field_for ~cmd:"gh pr list" ~status:(Unix.WSIGNALED 9) ~output:""
  in
  (match fields with
   | [ ("shell_ir_github_exit", `String v) ] ->
     (* signal 9 → exit_code 128+9=137, no rule matches, Unknown *)
     Alcotest.(check string) "Unknown payload"
       (GEC.to_string GEC.Unknown) v
   | _ -> Alcotest.fail "unexpected field shape")

let () =
  Alcotest.run "gh_exit_class_wiring"
    [
      ( "gh_exit_class_field",
        [
          Alcotest.test_case "cmd target positive" `Quick
            test_stages_target_gh_positive;
          Alcotest.test_case "cmd target negative" `Quick
            test_stages_target_gh_negative;
          Alcotest.test_case "non-gh emits no field" `Quick
            test_field_empty_for_non_gh;
          Alcotest.test_case "gh exit 0 → Ok_0" `Quick
            test_field_ok_for_gh_exit_0;
          Alcotest.test_case "gh + Bad credentials → Auth_failed" `Quick
            test_field_auth_failed_from_combined_output;
          Alcotest.test_case "signalled gh → Unknown" `Quick
            test_field_signal_maps_to_unknown;
        ] );
    ]
