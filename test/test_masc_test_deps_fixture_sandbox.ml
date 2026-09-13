(* What one fixture case is worth once its sandbox teardown has reported.

   Proves that a teardown [Error] is the case's verdict, not a stderr line the
   runner never reads. On origin/main [Masc_test_deps.teardown_fixture_sandbox]
   printed the detail with Printf.eprintf and returned unit, so a case whose
   body passed kept passing while the container it leaked stayed up; there was
   no verdict to assert on and this file did not compile. Every arm of the
   arbitration is pinned here without a daemon:

   - body returned, teardown ok      -> the value comes back untouched
   - body raised,   teardown ok      -> the same exception, same backtrace
   - body returned, teardown failed  -> a failure that carries the detail
   - body raised,   teardown failed  -> a failure that carries both *)

exception Body_broke of string

let keeper_name = "fixture-under-test"
let detail = "docker rm timed out after 10.0s"
let backtrace () = Printexc.get_callstack 4

let test_body_returned_and_teardown_ok () =
  match
    Masc_test_deps.fixture_case_verdict
      ~keeper_name
      ~body:(Ok 42)
      ~teardown:(Ok ())
  with
  | Masc_test_deps.Case_passed value -> Alcotest.(check int) "value" 42 value
  | Masc_test_deps.Case_raised _ -> Alcotest.fail "a passing body was reported as raised"
  | Masc_test_deps.Teardown_failed _ ->
    Alcotest.fail "an Ok teardown was reported as failed"
;;

let test_body_raised_and_teardown_ok () =
  let raised = Body_broke "assertion in the body" in
  let raised_at = backtrace () in
  match
    Masc_test_deps.fixture_case_verdict
      ~keeper_name
      ~body:(Error (raised, raised_at))
      ~teardown:(Ok ())
  with
  | Masc_test_deps.Case_raised (exn, at) ->
    Alcotest.(check bool) "same exception" true (exn == raised);
    Alcotest.(check bool) "same backtrace" true (at == raised_at)
  | Masc_test_deps.Case_passed () -> Alcotest.fail "a raising body was reported as passed"
  | Masc_test_deps.Teardown_failed _ ->
    Alcotest.fail "an Ok teardown was reported as failed"
;;

let test_body_returned_and_teardown_failed () =
  match
    Masc_test_deps.fixture_case_verdict
      ~keeper_name
      ~body:(Ok ())
      ~teardown:(Error detail)
  with
  | Masc_test_deps.Teardown_failed { keeper_name = named; body_failure; detail = got } ->
    Alcotest.(check string) "keeper" keeper_name named;
    Alcotest.(check (option string)) "no body failure" None body_failure;
    Alcotest.(check string) "detail" detail got
  | Masc_test_deps.Case_passed () ->
    Alcotest.fail "a failed teardown let the case pass"
  | Masc_test_deps.Case_raised _ ->
    Alcotest.fail "a failed teardown was reported as the body raising"
;;

let test_body_raised_and_teardown_failed () =
  let raised = Body_broke "assertion in the body" in
  match
    Masc_test_deps.fixture_case_verdict
      ~keeper_name
      ~body:(Error (raised, backtrace ()))
      ~teardown:(Error detail)
  with
  | Masc_test_deps.Teardown_failed { keeper_name = named; body_failure; detail = got } ->
    Alcotest.(check string) "keeper" keeper_name named;
    Alcotest.(check (option string))
      "body failure kept"
      (Some (Printexc.to_string raised))
      body_failure;
    Alcotest.(check string) "detail" detail got
  | Masc_test_deps.Case_passed () ->
    Alcotest.fail "two failures let the case pass"
  | Masc_test_deps.Case_raised _ ->
    Alcotest.fail "a failed teardown was dropped behind the body's exception"
;;

let test_failure_message_names_both () =
  Alcotest.(check string)
    "teardown only"
    "fixture sandbox teardown for fixture-under-test: docker rm timed out after 10.0s"
    (Masc_test_deps.fixture_case_failure_message
       ~keeper_name
       ~body_failure:None
       ~detail);
  Alcotest.(check string)
    "body and teardown"
    "body says no; and then fixture sandbox teardown for fixture-under-test: \
     docker rm timed out after 10.0s"
    (Masc_test_deps.fixture_case_failure_message
       ~keeper_name
       ~body_failure:(Some "body says no")
       ~detail)
;;

let () =
  Alcotest.run
    "masc_test_deps fixture sandbox"
    [ ( "verdict"
      , [ Alcotest.test_case
            "body returned, teardown ok: value"
            `Quick
            test_body_returned_and_teardown_ok
        ; Alcotest.test_case
            "body raised, teardown ok: same exception"
            `Quick
            test_body_raised_and_teardown_ok
        ; Alcotest.test_case
            "body returned, teardown failed: case fails with the detail"
            `Quick
            test_body_returned_and_teardown_failed
        ; Alcotest.test_case
            "body raised, teardown failed: case fails with both"
            `Quick
            test_body_raised_and_teardown_failed
        ; Alcotest.test_case
            "failure message names keeper, body failure and detail"
            `Quick
            test_failure_message_names_both
        ] )
    ]
;;
