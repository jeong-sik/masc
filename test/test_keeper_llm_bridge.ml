open Masc

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

let test_env_uninitialized_domain_returns_none () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        let worker = Domain.spawn (fun () -> Masc_eio_env.get_opt ()) in
        Alcotest.(check (option pass))
          "uninitialized domain returns None"
          None
          (Domain.join worker))))
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
            ~cause_code:"provider_timeout"
            ~operator_action:"inspect_provider_stream"
        | Error err -> Alcotest.fail (Agent_sdk.Error.to_string err)
        | Ok value -> Alcotest.failf "unexpected success: %s" value)))
;;

let test_parent_timeout_cancel_logs_info () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        let cancelled =
          try
            ignore
              (Keeper_llm_bridge.run_with_timeout_and_fallback
                 ~cancel_classification:Keeper_llm_bridge.Routine_parent_cancel
                 ~timeout_s:1.0
                 (fun () -> raise (Eio.Cancel.Cancelled Eio.Time.Timeout)));
            false
          with
          | Eio.Cancel.Cancelled _ -> true
        in
        Alcotest.(check bool) "cancel re-raised" true cancelled;
        match latest_keeper_log_matching "bucket=fast inner=Eio__Time.Timeout" with
        | None -> Alcotest.fail "missing parent timeout cancel log"
        | Some entry ->
          let open Yojson.Safe.Util in
          Alcotest.(check string)
            "routine parent timeout cancel is info"
            "INFO"
            (Log.level_to_string entry.Log.Ring.level);
          Alcotest.(check string)
            "log class"
            "routine_parent_cancel"
            (entry.Log.Ring.details |> member "log_class" |> to_string))))
;;

let test_default_timeout_inner_cancel_logs_info () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        let cancelled =
          try
            ignore
              (Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0
                 (fun () -> raise (Eio.Cancel.Cancelled Eio.Time.Timeout)));
            false
          with
          | Eio.Cancel.Cancelled _ -> true
        in
        Alcotest.(check bool) "cancel re-raised" true cancelled;
        match latest_keeper_log_matching "bucket=fast inner=Eio__Time.Timeout" with
        | None -> Alcotest.fail "missing default timeout cancel log"
        | Some entry ->
          let open Yojson.Safe.Util in
          Alcotest.(check string)
            "default timeout inner cancel is info"
            "INFO"
            (Log.level_to_string entry.Log.Ring.level);
          Alcotest.(check string)
            "log class"
            "inner_timeout_cancel"
            (entry.Log.Ring.details |> member "log_class" |> to_string);
          Alcotest.(check string)
            "cancel classification"
            "inner_timeout_cancel"
            (entry.Log.Ring.details |> member "cancel_classification" |> to_string))))
;;

let test_unknown_cancel_stays_warn () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
        let cancelled =
          try
            ignore
              (Keeper_llm_bridge.run_with_timeout_and_fallback ~timeout_s:1.0
                 (fun () -> raise (Eio.Cancel.Cancelled (Failure "operator-stop-test"))));
            false
          with
          | Eio.Cancel.Cancelled _ -> true
        in
        Alcotest.(check bool) "cancel re-raised" true cancelled;
        match latest_keeper_log_matching "inner=Failure(operator-stop-test)" with
        | None -> Alcotest.fail "missing unknown cancel log"
        | Some entry ->
          let open Yojson.Safe.Util in
          Alcotest.(check string)
            "unknown cancel stays warn"
            "WARN"
            (Log.level_to_string entry.Log.Ring.level);
          Alcotest.(check string)
            "log class"
            "warn_cancel"
            (entry.Log.Ring.details |> member "log_class" |> to_string))))
;;

let test_hitl_headworkspace_exceeds_default_approval_wait () =
  let floor = 3630.0 in
  Alcotest.(check (float 0.001))
    "short bridge timeout is raised above HITL wait"
    floor
    (Keeper_llm_bridge.with_hitl_approval_headroom 292.0);
  Alcotest.(check (float 0.001))
    "long bridge timeout is preserved"
    3900.0
    (Keeper_llm_bridge.with_hitl_approval_headroom 3900.0)
;;

let test_timeout_inner_cancel_classification () =
  Alcotest.(check bool)
    "timeout cancel after budget is timeout"
    true
    (Keeper_llm_bridge.For_testing.cancelled_timeout_exceeded
       ~timeout_s:600.0
       ~wall:2133.4
       Eio.Time.Timeout);
  Alcotest.(check bool)
    "timeout cancel before budget remains parent cancel"
    false
    (Keeper_llm_bridge.For_testing.cancelled_timeout_exceeded
       ~timeout_s:600.0
       ~wall:30.0
       Eio.Time.Timeout);
  Alcotest.(check bool)
    "non-timeout cancel after budget remains parent cancel"
    false
    (Keeper_llm_bridge.For_testing.cancelled_timeout_exceeded
       ~timeout_s:600.0
       ~wall:2133.4
       (Failure "shutdown"))
;;

let () =
  Alcotest.run
    "keeper_llm_bridge"
    [ ( "timeout clock"
      , [ Alcotest.test_case
            "missing env fails closed"
            `Quick
            test_missing_env_fails_closed_without_calling_fn
        ; Alcotest.test_case "clocked env runs" `Quick test_clocked_env_runs_function
        ; Alcotest.test_case
            "uninitialized domain returns None"
            `Quick
            test_env_uninitialized_domain_returns_none
        ; Alcotest.test_case
            "timeout log carries failure envelope"
            `Quick
            test_timeout_log_carries_failure_envelope
        ; Alcotest.test_case
            "parent timeout cancel logs info"
            `Quick
            test_parent_timeout_cancel_logs_info
        ; Alcotest.test_case
            "default timeout inner cancel logs info"
            `Quick
            test_default_timeout_inner_cancel_logs_info
        ; Alcotest.test_case
            "unknown cancel stays warn"
            `Quick
            test_unknown_cancel_stays_warn
        ; Alcotest.test_case
            "HITL approval headroom"
            `Quick
            test_hitl_headworkspace_exceeds_default_approval_wait
        ; Alcotest.test_case
            "timeout inner cancel classification"
            `Quick
            test_timeout_inner_cancel_classification
        ] )
    ]
;;
