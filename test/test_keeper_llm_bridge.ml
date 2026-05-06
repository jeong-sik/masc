open Masc_mcp

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let assert_no_clock_error ~label ~called result =
  Alcotest.(check bool) (label ^ ": function was not called") false !called;
  match result with
  | Error (Agent_sdk.Error.Internal msg) ->
    Alcotest.(check bool)
      (label ^ ": message names no-clock failure")
      true
      (contains_substring msg "Eio clock unavailable");
    Alcotest.(check bool)
      (label ^ ": message names timeout")
      true
      (contains_substring msg "timeout_s=1")
  | Error err ->
    Alcotest.failf "unexpected error shape: %s" (Agent_sdk.Error.to_string err)
  | Ok value -> Alcotest.failf "unexpected success: %s" value
;;

let test_missing_env_fails_closed_without_calling_fn () =
  Masc_eio_env.reset_for_test ();
  let called = ref false in
  let result =
    Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0 (fun () ->
      called := true;
      Ok "should-not-run")
  in
  assert_no_clock_error ~label:"missing env" ~called result
;;

let test_clockless_env_fails_closed_without_calling_fn () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ();
        let called = ref false in
        let result =
          Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0 (fun () ->
            called := true;
            Ok "should-not-run")
        in
        assert_no_clock_error ~label:"clockless env" ~called result)))
;;

let test_clocked_env_runs_function () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        let called = ref false in
        match
          Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0 (fun () ->
            called := true;
            Ok "ok")
        with
        | Ok "ok" -> Alcotest.(check bool) "function was called" true !called
        | Ok other -> Alcotest.failf "unexpected success: %s" other
        | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err))))
;;

let () =
  Alcotest.run
    "keeper_llm_bridge"
    [ ( "timeout clock"
      , [ Alcotest.test_case
            "missing env fails closed"
            `Quick
            test_missing_env_fails_closed_without_calling_fn
        ; Alcotest.test_case
            "clockless env fails closed"
            `Quick
            test_clockless_env_fails_closed_without_calling_fn
        ; Alcotest.test_case "clocked env runs" `Quick test_clocked_env_runs_function
        ] )
    ]
;;
