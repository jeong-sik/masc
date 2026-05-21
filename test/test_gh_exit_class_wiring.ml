(* test/test_gh_exit_class_wiring.ml

   Verifies that the shared command-semantics predicate identifies gh
   commands, and that the docker-sandbox JSON emission path consumes
   that predicate to call [Gh_exit_class.classify] and increment the
   matching [Legendary_counters] bucket. Covers only the helper surface
   — the docker exec itself is out of scope for a unit test. *)

module KSD = Masc_mcp.Keeper_shell_docker
module KSC = Masc_mcp.Keeper_shell_command_semantics
module LC = Masc_mcp.Legendary_counters
module GEC = Masc_mcp.Gh_exit_class

let test_cmd_targets_gh_positive () =
  Alcotest.(check bool) "gh pr list → true" true
    (KSC.cmd_targets_gh "gh pr list");
  Alcotest.(check bool) "env-wrapped gh → true" true
    (KSC.cmd_targets_gh "env GH_TOKEN=redacted gh pr view 1");
  Alcotest.(check bool) "opam exec -- gh → true" true
    (KSC.cmd_targets_gh "opam exec -- gh pr view 1")

let test_cmd_targets_gh_negative () =
  Alcotest.(check bool) "git status → false" false
    (KSC.cmd_targets_gh "git status");
  Alcotest.(check bool) "ls -la → false" false
    (KSC.cmd_targets_gh "ls -la");
  Alcotest.(check bool) "literal gh arg is not a command" false
    (KSC.cmd_targets_gh "echo gh");
  Alcotest.(check bool) "logic chain is not interpreted" false
    (KSC.cmd_targets_gh "cd /repo && gh pr view 1");
  Alcotest.(check bool) "opam exec option is not guessed" false
    (KSC.cmd_targets_gh "opam exec --switch default gh pr view 1");
  Alcotest.(check bool) "empty → false" false
    (KSC.cmd_targets_gh "")

let test_field_empty_for_non_gh () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd:"git status" ~status:(Unix.WEXITED 0) ~output:""
  in
  Alcotest.(check int) "no field emitted" 0 (List.length fields);
  let s = LC.snapshot () in
  Alcotest.(check int) "Ok_0 counter untouched" 0 s.gh_exit_ok_0

let test_field_ok_for_gh_exit_0 () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd:"gh pr list" ~status:(Unix.WEXITED 0) ~output:""
  in
  Alcotest.(check int) "one field emitted" 1 (List.length fields);
  (match fields with
   | [ ("gh_exit_class", `String v) ] ->
     Alcotest.(check string) "Ok_0 payload"
       (GEC.to_string GEC.Ok_0) v
   | _ -> Alcotest.fail "unexpected field shape");
  let s = LC.snapshot () in
  Alcotest.(check int) "Ok_0 counter ticked" 1 s.gh_exit_ok_0

let test_field_auth_failed_from_combined_output () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd:"gh api /user"
      ~status:(Unix.WEXITED 1)
      ~output:"HTTP 401: Bad credentials (https://api.github.com/user)"
  in
  (match fields with
   | [ ("gh_exit_class", `String v) ] ->
     Alcotest.(check string) "Auth_failed payload"
       (GEC.to_string GEC.Auth_failed) v
   | _ -> Alcotest.fail "unexpected field shape");
  let s = LC.snapshot () in
  Alcotest.(check int) "Auth_failed counter ticked" 1 s.gh_exit_auth_failed

let test_field_signal_maps_to_unknown () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd:"gh pr list" ~status:(Unix.WSIGNALED 9) ~output:""
  in
  (match fields with
   | [ ("gh_exit_class", `String v) ] ->
     (* signal 9 → exit_code 128+9=137, no rule matches, Unknown *)
     Alcotest.(check string) "Unknown payload"
       (GEC.to_string GEC.Unknown) v
   | _ -> Alcotest.fail "unexpected field shape");
  let s = LC.snapshot () in
  Alcotest.(check int) "Unknown counter ticked" 1 s.gh_exit_unknown

let () =
  Alcotest.run "gh_exit_class_wiring"
    [
      ( "cmd_targets_gh",
        [
          Alcotest.test_case "positive" `Quick test_cmd_targets_gh_positive;
          Alcotest.test_case "negative" `Quick test_cmd_targets_gh_negative;
        ] );
      ( "gh_exit_class_field",
        [
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
