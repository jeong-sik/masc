open Masc

let expected_invalid_timeout timeout_s =
  Invalid_argument
    (Printf.sprintf
       "Masc_oas_bridge.run_safe: timeout_s must be positive or infinite (got %.6g)"
       timeout_s)
;;

let check_internal_contract_rejected label err =
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Internal_contract_rejected _) -> ()
  | Some other ->
    Alcotest.failf
      "%s: expected Internal_contract_rejected, got %s"
      label
      (Keeper_internal_error.kind_of_masc_internal_error other)
  | None ->
    Alcotest.failf "%s: expected structured MASC internal error" label
;;

let with_masc_eio_env f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Masc_eio_env.reset_for_test ();
      Fun.protect
        ~finally:Masc_eio_env.reset_for_test
        (fun () ->
          Masc_eio_env.init
            ~sw
            ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env)
            ();
          f ())))
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

let test_accepts_infinite_timeout_with_eio_clock () =
  with_masc_eio_env (fun () ->
    let called = ref false in
    match
      Masc_oas_bridge.run_safe
        ~caller:"test_timeout_guard"
        ~timeout_s:Float.infinity
        (fun () ->
          called := true;
          Ok "ok")
    with
    | Ok "ok" -> Alcotest.(check bool) "fn was called" true !called
    | Ok other -> failwith ("unexpected result: " ^ other)
    | Error err -> failwith (Agent_sdk.Error.to_string err))
;;

let test_rejects_positive_timeout_without_eio_clock () =
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "test_rejects_positive_timeout_without_eio_clock requires Masc_eio_env.get_opt () = \
       None before calling run_safe"
  | None ->
    let called = ref false in
    (match
       Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s:0.1 (fun () ->
         called := true;
         Ok "ok")
     with
     | Error err ->
       Alcotest.(check bool) "fn was not called" false !called;
       check_internal_contract_rejected "missing clock" err
     | Ok value -> failwith ("unexpected success: " ^ value))
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

let check_run_with_caller_uses_fallback_for_invalid_env ~name raw_value =
  let caller = Env_config_oas_bridge.Anti_rationalization in
  let env_name = Env_config_oas_bridge.per_caller_env_var ~caller in
  with_masc_eio_env (fun () ->
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

let test_run_with_caller_rejects_invalid_env_timeouts_at_boundary () =
  check_run_with_caller_uses_fallback_for_invalid_env ~name:"zero env fallback" "0";
  check_run_with_caller_uses_fallback_for_invalid_env ~name:"negative env fallback" "-1";
  check_run_with_caller_uses_fallback_for_invalid_env ~name:"nan env fallback" "nan";
  check_run_with_caller_uses_fallback_for_invalid_env
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
            "accepts infinite timeout with eio clock"
            `Quick
            test_accepts_infinite_timeout_with_eio_clock
        ; Alcotest.test_case
            "rejects positive timeout without eio clock"
            `Quick
            test_rejects_positive_timeout_without_eio_clock
        ; Alcotest.test_case
            "run_with_caller falls back for invalid env timeouts"
            `Quick
            test_run_with_caller_rejects_invalid_env_timeouts_at_boundary
        ] )
    ]
;;
