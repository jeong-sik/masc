open Masc

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0
;;

let expected_invalid_timeout timeout_s =
  Invalid_argument
    (Printf.sprintf
       "Masc_oas_bridge.run_safe: timeout_s must be positive or infinite (got %.6g)"
       timeout_s)
;;

let check_internal_contract_rejected ~label ~reason_contains = function
  | Ok _ -> Alcotest.failf "%s: expected Internal_contract_rejected error" label
  | Error err ->
    (match Keeper_internal_error.classify_masc_internal_error err with
     | Some (Keeper_internal_error.Internal_contract_rejected { reason }) ->
       Alcotest.(check bool)
         (label ^ " reason")
         true
         (contains ~needle:reason_contains reason)
     | Some other ->
       Alcotest.failf
         "%s: unexpected internal error kind %s"
         label
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf "%s: unexpected SDK error %s" label (Agent_sdk.Error.to_string err))
;;

let restore_masc_eio_env = function
  | None -> Masc_eio_env.reset_for_test ()
  | Some env ->
    Masc_eio_env.init
      ~sw:env.Masc_eio_env.sw
      ~net:env.Masc_eio_env.net
      ~clock:env.Masc_eio_env.clock
      ()
;;

let with_no_masc_eio_env f =
  let previous = Masc_eio_env.get_opt () in
  Masc_eio_env.reset_for_test ();
  Fun.protect ~finally:(fun () -> restore_masc_eio_env previous) f
;;

let with_masc_eio_env_clock f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let previous = Masc_eio_env.get_opt () in
  Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
  Fun.protect ~finally:(fun () -> restore_masc_eio_env previous) f
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

let test_rejects_when_eio_env_not_initialized () =
  with_no_masc_eio_env (fun () ->
    let called = ref false in
    let result =
      Masc_oas_bridge.run_safe ~caller:"test_timeout_guard" ~timeout_s:0.1 (fun () ->
        called := true;
        Ok "ok")
    in
    check_internal_contract_rejected
      ~label:"run_safe missing env"
      ~reason_contains:"Masc_eio_env is not initialized"
      result;
    Alcotest.(check bool) "fn was not called" false !called)
;;

let test_run_with_caller_rejects_when_eio_env_not_initialized () =
  let caller = Env_config_oas_bridge.Anti_rationalization in
  with_no_masc_eio_env (fun () ->
    let called = ref false in
    let result =
      Masc_oas_bridge.run_with_caller ~caller (fun () ->
        called := true;
        Ok "ok")
    in
    check_internal_contract_rejected
      ~label:"run_with_caller missing env"
      ~reason_contains:"Masc_eio_env is not initialized"
      result;
    Alcotest.(check bool) "fn was not called" false !called)
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

let test_run_with_caller_accepts_infinity_env_timeout () =
  let caller = Env_config_oas_bridge.Anti_rationalization in
  let env_name = Env_config_oas_bridge.per_caller_env_var ~caller in
  with_env env_name "infinity" (fun () ->
    Alcotest.(check bool)
      "infinity resolves as no-fire"
      true
      (match Float.classify_float (Env_config_oas_bridge.timeout_sec ~caller ()) with
       | FP_infinite -> true
       | _ -> false);
    with_masc_eio_env_clock (fun () ->
      let called = ref false in
      match
        Masc_oas_bridge.run_with_caller ~caller (fun () ->
          called := true;
          Ok "ok")
      with
      | Ok "ok" -> Alcotest.(check bool) "fn was called" true !called
      | Ok other -> failwith ("unexpected result: " ^ other)
      | Error err -> failwith (Agent_sdk.Error.to_string err)))
;;

let test_run_unbounded_requires_initialized_env () =
  with_no_masc_eio_env (fun () ->
    let called = ref false in
    let result =
      Masc_oas_bridge.run_unbounded ~caller:"test_timeout_guard" (fun () ->
        called := true;
        Ok "ok")
    in
    check_internal_contract_rejected
      ~label:"run_unbounded missing env"
      ~reason_contains:"Masc_eio_env is not initialized"
      result;
    Alcotest.(check bool) "fn was not called" false !called)
;;

let test_run_unbounded_runs_without_timeout () =
  with_masc_eio_env_clock (fun () ->
    let called = ref false in
    match
      Masc_oas_bridge.run_unbounded ~caller:"test_timeout_guard" (fun () ->
        called := true;
        Ok "ok")
    with
    | Ok "ok" -> Alcotest.(check bool) "fn was called" true !called
    | Ok other -> failwith ("unexpected result: " ^ other)
    | Error err -> failwith (Agent_sdk.Error.to_string err))
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
            "rejects when eio env not initialized"
            `Quick
            test_rejects_when_eio_env_not_initialized
        ; Alcotest.test_case
            "run_with_caller rejects when eio env not initialized"
            `Quick
            test_run_with_caller_rejects_when_eio_env_not_initialized
        ; Alcotest.test_case
            "run_with_caller accepts infinity env timeout"
            `Quick
            test_run_with_caller_accepts_infinity_env_timeout
        ; Alcotest.test_case
            "run_unbounded requires initialized env"
            `Quick
            test_run_unbounded_requires_initialized_env
        ; Alcotest.test_case
            "run_unbounded runs without timeout"
            `Quick
            test_run_unbounded_runs_without_timeout
        ] )
    ]
;;
