(* test/test_gh_exit_class_wiring.ml

   Verifies that the docker-sandbox JSON emission path calls
   [Gh_exit_class.classify] for gh commands and increments the
   matching [Legendary_counters] bucket, without touching counters
   for non-gh commands. Covers only the helper surface — the docker
   exec itself is out of scope for a unit test. *)

module KSD = Masc_mcp.Keeper_shell_docker
module KSCS = Masc_mcp.Keeper_shell_command_semantics
module LC = Masc_mcp.Legendary_counters
module GEC = Masc_mcp.Gh_exit_class

(* [gh_exit_class_field] now consumes typed [parsed_stage list] (RFC-0160
   Shell IR first-class promotion); [effective_stages_of_cmd] is the
   canonical string-to-stages adapter for tests that originate from a
   raw command line. *)
let stages_of cmd = KSCS.effective_stages_of_cmd cmd

(* Removed [test_cmd_targets_gh_{positive,negative}]: the [cmd_targets_gh]
   classifier was inlined into [Keeper_shell_docker]'s internal call sites
   and dropped from the public surface (PR #18100 — "drop dead facade").
   The gh-vs-non-gh discrimination is still exercised indirectly through
   [gh_exit_class_field] (next group) which only emits the field for
   commands the internal classifier accepts. *)

let test_field_empty_for_non_gh () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd_stages:(stages_of "git status")
      ~status:(Unix.WEXITED 0) ~output:""
      ()
  in
  Alcotest.(check int) "no field emitted" 0 (List.length fields);
  let s = LC.snapshot () in
  Alcotest.(check int) "Ok_0 counter untouched" 0 s.gh_exit_ok_0

let test_field_ok_for_gh_exit_0 () =
  LC.reset ();
  let fields =
    KSD.gh_exit_class_field
      ~cmd_stages:(stages_of "gh pr list")
      ~status:(Unix.WEXITED 0) ~output:""
      ()
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
      ~cmd_stages:(stages_of "gh api /user")
      ~status:(Unix.WEXITED 1)
      ~output:"HTTP 401: Bad credentials (https://api.github.com/user)"
      ()
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
      ~cmd_stages:(stages_of "gh pr list")
      ~status:(Unix.WSIGNALED 9) ~output:""
      ()
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
