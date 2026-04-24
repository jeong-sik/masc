(* test/test_gh_exit_class.ml

   RFC-0007 rev.3 PR-2 — classifier contract.

   Principles under test:
   1. Ok_0 on exit_code=0 regardless of stderr (stderr may carry warnings).
   2. Policy_blocked rides reserved masc-mcp exit codes, not regex.
   3. Auth_failed matches on stderr substrings that production has
      actually observed (Bad credentials, 401, gh auth login prompt).
   4. Network uses curl/TLS keywords, not stdout.
   5. Type_mismatch on exit=2 (Go/cobra argparse) or flag/command errors.
   6. Unknown is a first-class, stable bucket — never misclassify.
   7. [install_overrides] takes precedence over defaults.
   8. [to_legacy_result] preserves the one-release compat contract. *)

module GEC = Masc_mcp.Gh_exit_class

let eq_class t label expected actual =
  Alcotest.(check string) label
    (GEC.to_string expected) (GEC.to_string actual);
  ignore t

let test_ok_zero () =
  let c = GEC.classify ~exit_code:0 ~stderr:"" in
  eq_class () "exit 0 → Ok_0" GEC.Ok_0 c;
  let c' = GEC.classify ~exit_code:0 ~stderr:"warning: something" in
  eq_class () "exit 0 with warning stderr → Ok_0" GEC.Ok_0 c'

let test_policy_blocked () =
  let c200 = GEC.classify ~exit_code:200 ~stderr:"" in
  eq_class () "exit 200 → Policy_blocked" GEC.Policy_blocked c200;
  let c201 = GEC.classify ~exit_code:201 ~stderr:"anything" in
  eq_class () "exit 201 → Policy_blocked" GEC.Policy_blocked c201

let test_auth_failure_variants () =
  let c_4 = GEC.classify ~exit_code:4 ~stderr:"" in
  eq_class () "exit 4 → Auth_failed" GEC.Auth_failed c_4;
  let c_bad = GEC.classify ~exit_code:1
    ~stderr:"HTTP 401: Bad credentials (https://api.github.com/)" in
  eq_class () "Bad credentials → Auth_failed" GEC.Auth_failed c_bad;
  let c_login = GEC.classify ~exit_code:1
    ~stderr:"Please run: gh auth login" in
  eq_class () "gh auth login prompt → Auth_failed" GEC.Auth_failed c_login;
  let c_403 = GEC.classify ~exit_code:1
    ~stderr:"HTTP 403 Forbidden" in
  eq_class () "403 Forbidden → Auth_failed" GEC.Auth_failed c_403

let test_network_variants () =
  let dns = GEC.classify ~exit_code:1
    ~stderr:"Could not resolve host: api.github.com" in
  eq_class () "DNS fail → Network" GEC.Network dns;
  let tls = GEC.classify ~exit_code:1
    ~stderr:"remote error: tls: handshake failure" in
  eq_class () "TLS handshake → Network" GEC.Network tls;
  let timeout = GEC.classify ~exit_code:1
    ~stderr:"dial tcp 140.82.114.4:443: i/o timeout" in
  eq_class () "dial tcp timeout → Network" GEC.Network timeout

let test_type_mismatch () =
  let c_2 = GEC.classify ~exit_code:2 ~stderr:"" in
  eq_class () "exit 2 → Type_mismatch" GEC.Type_mismatch c_2;
  let c_flag = GEC.classify ~exit_code:1
    ~stderr:"Error: unknown flag: --foo" in
  eq_class () "unknown flag → Type_mismatch" GEC.Type_mismatch c_flag;
  let c_cmd = GEC.classify ~exit_code:1
    ~stderr:"Error: unknown command \"foobar\" for \"gh\"" in
  eq_class () "unknown command → Type_mismatch" GEC.Type_mismatch c_cmd

let test_unknown_fallback () =
  let c = GEC.classify ~exit_code:137 ~stderr:"" in
  eq_class () "exit 137 (SIGKILL) → Unknown" GEC.Unknown c;
  let c' = GEC.classify ~exit_code:1 ~stderr:"some random unmatched error text" in
  eq_class () "arbitrary stderr → Unknown" GEC.Unknown c'

let test_make_carries_interpretation () =
  let r = GEC.make ~stdout:"" ~stderr:"Bad credentials" ~exit_code:1 in
  Alcotest.(check string) "class"
    (GEC.to_string GEC.Auth_failed) (GEC.to_string r.class_);
  (match r.interpretation with
   | Some s ->
     Alcotest.(check bool) "interpretation mentions auth"
       true
       (String.length s > 0
        && (String.length s >= 4
            && (let lower = String.lowercase_ascii s in
                let rec sub_at i =
                  if i + 4 > String.length lower then false
                  else if String.sub lower i 4 = "auth" then true
                  else sub_at (i + 1)
                in sub_at 0)))
   | None -> Alcotest.fail "expected interpretation for Auth_failed")

let test_to_legacy_ok () =
  let r = GEC.make ~stdout:"hello\n" ~stderr:"" ~exit_code:0 in
  match GEC.to_legacy_result r with
  | Ok s -> Alcotest.(check string) "stdout preserved" "hello\n" s
  | Error e -> Alcotest.fail ("expected Ok, got Error: " ^ e)

let test_to_legacy_err_prefix () =
  let r = GEC.make ~stdout:"" ~stderr:"Bad credentials" ~exit_code:1 in
  match GEC.to_legacy_result r with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error body ->
    (* The error body must be prefixed by the class name in square
       brackets. Callers may grep for [Auth_failed] etc. *)
    let has_prefix =
      String.length body >= 14
      && String.sub body 0 13 = "[Auth_failed]"
    in
    Alcotest.(check bool) "legacy Error starts with class tag" true has_prefix

let test_overrides_precedence () =
  (* Override: stderr containing "QUOTA" + exit 1 → Policy_blocked.
     Without the override, defaults bucket this to Unknown. *)
  let before = GEC.classify ~exit_code:1 ~stderr:"QUOTA exceeded" in
  eq_class () "before override" GEC.Unknown before;
  GEC.install_overrides
    [ { GEC.exit_code = 1;
        stderr_contains = Some "QUOTA";
        class_ = GEC.Policy_blocked } ];
  let after = GEC.classify ~exit_code:1 ~stderr:"QUOTA exceeded" in
  eq_class () "after override" GEC.Policy_blocked after

let () =
  Alcotest.run "gh_exit_class"
    [
      ( "classify",
        [
          Alcotest.test_case "Ok_0"             `Quick test_ok_zero;
          Alcotest.test_case "Policy_blocked"   `Quick test_policy_blocked;
          Alcotest.test_case "Auth variants"    `Quick test_auth_failure_variants;
          Alcotest.test_case "Network variants" `Quick test_network_variants;
          Alcotest.test_case "Type_mismatch"    `Quick test_type_mismatch;
          Alcotest.test_case "Unknown fallback" `Quick test_unknown_fallback;
        ] );
      ( "gh_result",
        [
          Alcotest.test_case "make carries interpretation"
            `Quick test_make_carries_interpretation;
          Alcotest.test_case "to_legacy Ok"  `Quick test_to_legacy_ok;
          Alcotest.test_case "to_legacy Err prefix" `Quick test_to_legacy_err_prefix;
        ] );
      ( "overrides",
        [
          Alcotest.test_case "override precedence" `Quick test_overrides_precedence;
        ] );
    ]
