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

let latest_keeper_log_matching needle =
  Log.Ring.recent
    ~limit:50
    ~min_level:(Log.level_to_int Log.Debug)
    ~module_filter:"Keeper"
    ()
  |> List.find_opt (fun entry -> contains_substring entry.Log.Ring.message needle)
;;

let assert_latest_failure_envelope ~label ~needle ~cause_code ~operator_action =
  match latest_keeper_log_matching needle with
  | None -> Alcotest.failf "%s: no matching Keeper log for %S" label needle
  | Some entry ->
    let open Yojson.Safe.Util in
    let envelope = entry.Log.Ring.details |> member "failure_envelope" in
    Alcotest.(check string)
      (label ^ ": cause_code")
      cause_code
      (envelope |> member "cause_code" |> to_string);
    Alcotest.(check string)
      (label ^ ": operator_action")
      operator_action
      (envelope |> member "operator_action" |> to_string)
;;

let test_missing_env_fails_closed_without_calling_fn () =
  Masc_eio_env.reset_for_test ();
  let called = ref false in
  let result =
    Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0 (fun () ->
      called := true;
      Ok "should-not-run")
  in
  assert_no_clock_error ~label:"missing env" ~called result;
  assert_latest_failure_envelope
    ~label:"missing env"
    ~needle:"Eio clock unavailable"
    ~cause_code:"eio_clock_unavailable"
    ~operator_action:"check_masc_eio_env"
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

let test_timeout_log_carries_failure_envelope () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        match
          Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:0.001 (fun () ->
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.02;
            Ok "late")
        with
        | Error (Agent_sdk.Error.Api (Timeout _)) ->
          assert_latest_failure_envelope
            ~label:"timeout"
            ~needle:"OAS execution timed out"
            ~cause_code:"oas_timeout_budget"
            ~operator_action:"inspect_timeout_budget"
        | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
        | Ok value -> Alcotest.failf "unexpected success: %s" value)))
;;

let test_hitl_headroom_exceeds_default_approval_wait () =
  let floor =
    Keeper_approval_queue.default_noncritical_approval_timeout_s +. 30.0
  in
  Alcotest.(check (float 0.001))
    "short bridge timeout is raised above HITL wait"
    floor
    (Keeper_llm_bridge.with_hitl_approval_headroom 292.0);
  Alcotest.(check (float 0.001))
    "long bridge timeout is preserved"
    900.0
    (Keeper_llm_bridge.with_hitl_approval_headroom 900.0)
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
        ; Alcotest.test_case
            "timeout log carries failure envelope"
            `Quick
            test_timeout_log_carries_failure_envelope
        ; Alcotest.test_case
            "HITL approval headroom"
            `Quick
            test_hitl_headroom_exceeds_default_approval_wait
        ] )
    ]
;;
