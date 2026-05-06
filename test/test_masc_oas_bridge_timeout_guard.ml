open Masc_mcp

let expected_invalid_timeout timeout_s =
  Invalid_argument
    (Printf.sprintf
       "Masc_oas_bridge.run_safe: timeout_s must be positive and finite (got %.6g)"
       timeout_s)
;;

let check_rejects_timeout ~name timeout_s =
  let called = ref false in
  let run () =
    Masc_oas_bridge.run_safe ~timeout_s (fun () ->
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

let test_rejects_non_finite_timeout () =
  check_rejects_timeout ~name:"infinite timeout rejected" Float.infinity;
  check_rejects_timeout ~name:"nan timeout rejected" Float.nan
;;

let test_accepts_positive_timeout_without_eio_env () =
  match Masc_eio_env.get_opt () with
  | Some _ ->
    failwith
      "test_accepts_positive_timeout_without_eio_env requires Masc_eio_env.get_opt () = \
       None before calling run_safe"
  | None ->
    let called = ref false in
    (match
       Masc_oas_bridge.run_safe ~timeout_s:0.1 (fun () ->
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
            "rejects non-finite timeout"
            `Quick
            test_rejects_non_finite_timeout
        ; Alcotest.test_case
            "accepts positive timeout without eio env"
            `Quick
            test_accepts_positive_timeout_without_eio_env
        ] )
    ]
;;
