open Masc

let expected_invalid_timeout timeout_s =
  Invalid_argument
    (Printf.sprintf
       "Masc_oas_bridge.run_safe: timeout_s must be positive and finite \
        (got %.6g)"
       timeout_s)
;;

let check_rejects_timeout ~name timeout_s =
  let called = ref false in
  let run () =
    Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s (fun () ->
      called := true;
      Ok "should-not-run")
    |> ignore
  in
  Alcotest.check_raises name (expected_invalid_timeout timeout_s) run;
  Alcotest.(check bool) "fn was not called" false !called
;;

let test_rejects_non_positive_timeout () =
  check_rejects_timeout ~name:"zero timeout rejected" 0.0;
  check_rejects_timeout ~name:"negative timeout rejected" (-0.5)
;;

let test_rejects_nan_timeout () =
  check_rejects_timeout ~name:"nan timeout rejected" Float.nan
;;

let test_rejects_infinite_timeout () =
  check_rejects_timeout ~name:"infinite timeout rejected" Float.infinity;
  check_rejects_timeout ~name:"negative infinite timeout rejected" Float.neg_infinity
;;

let test_missing_eio_env_fails_closed_without_calling_fn () =
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "test_missing_eio_env_fails_closed_without_calling_fn requires Masc_eio_env.get_opt () = \
       None before calling run_safe"
  | None ->
    let called = ref false in
    (match
       Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s:0.1 (fun () ->
         called := true;
         Ok "should-not-run")
     with
     | Error _ -> Alcotest.(check bool) "fn was not called" false !called
     | Ok other -> failwith ("unexpected success: " ^ other))
;;

let with_eio_env f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect ~finally:Masc_eio_env.reset_for_test (fun () ->
        let clock = Eio.Stdenv.clock env in
        Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock ();
        f clock)))
;;

let test_clocked_env_times_out_sleep () =
  with_eio_env (fun clock ->
    let called = ref false in
    match
      Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s:0.001 (fun () ->
        called := true;
        Eio.Time.sleep clock 0.05;
        Ok "late")
    with
    | Error (Agent_sdk.Error.Api (Timeout _)) ->
      Alcotest.(check bool) "fn was started" true !called
    | Error err -> failwith (Agent_sdk.Error.to_string err)
    | Ok other -> failwith ("unexpected success: " ^ other))
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some old -> Unix.putenv name old
      | None -> Unix.putenv name "")
    f
;;

let check_run_with_caller_uses_resolved_env_timeout ~name raw_value =
  let caller = Env_config_oas_bridge.Anti_rationalization in
  let env_name = Env_config_oas_bridge.per_caller_env_var ~caller in
  with_eio_env (fun _clock ->
    with_env env_name raw_value (fun () ->
      let called = ref false in
      match
        Masc_oas_bridge.run_with_caller ~caller (fun () ->
          called := true;
          Ok "ok")
      with
      | Ok "ok" -> Alcotest.(check bool) name true !called
      | Ok other -> failwith ("unexpected result: " ^ other)
      | Error err -> failwith (Agent_sdk.Error.to_string err)))
;;

let test_run_with_caller_resolves_env_timeouts_at_boundary () =
  check_run_with_caller_uses_resolved_env_timeout ~name:"zero env fallback" "0";
  check_run_with_caller_uses_resolved_env_timeout ~name:"negative env fallback" "-1";
  check_run_with_caller_uses_resolved_env_timeout ~name:"nan env fallback" "nan";
  check_run_with_caller_uses_resolved_env_timeout
    ~name:"infinite env fallback"
    "infinity"
;;

let () =
  Alcotest.run
    "Masc_oas_bridge_timeout_guard"
    [ ( "run_safe"
      , [ Alcotest.test_case
            "rejects non-positive timeout"
            `Quick
            test_rejects_non_positive_timeout
        ; Alcotest.test_case
            "rejects nan timeout"
            `Quick
            test_rejects_nan_timeout
        ; Alcotest.test_case
            "rejects infinite timeout"
            `Quick
            test_rejects_infinite_timeout
        ; Alcotest.test_case
            "missing eio env fails closed"
            `Quick
            test_missing_eio_env_fails_closed_without_calling_fn
        ; Alcotest.test_case
            "clocked env times out sleep"
            `Quick
            test_clocked_env_times_out_sleep
        ; Alcotest.test_case
            "run_with_caller resolves env timeouts"
            `Quick
            test_run_with_caller_resolves_env_timeouts_at_boundary
        ] )
    ]
;;
