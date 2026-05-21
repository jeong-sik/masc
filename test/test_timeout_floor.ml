open Masc_mcp

let check_float name expected actual =
  Alcotest.(check (float 0.0001)) name expected actual
;;

let test_default_table () =
  check_float "docker run" 20.0 (Timeout_floor.default_sec Timeout_floor.Docker_run);
  check_float "native shell" 5.0 (Timeout_floor.default_sec Timeout_floor.Native_shell);
  check_float "tool dispatch" 15.0 (Timeout_floor.default_sec Timeout_floor.Tool_dispatch);
  check_float "llm call" 1.0 (Timeout_floor.default_sec Timeout_floor.Llm_call)
;;

let test_clamp () =
  check_float "raises low docker timeout" 20.0
    (Timeout_floor.clamp Timeout_floor.Docker_run 1.0);
  check_float "preserves higher docker timeout" 30.0
    (Timeout_floor.clamp Timeout_floor.Docker_run 30.0)
;;

let test_load_bearing () =
  Alcotest.(check bool)
    "docker"
    true
    (Timeout_floor.is_load_bearing Timeout_floor.Docker_run);
  Alcotest.(check bool)
    "tool"
    true
    (Timeout_floor.is_load_bearing Timeout_floor.Tool_dispatch);
  Alcotest.(check bool)
    "llm"
    false
    (Timeout_floor.is_load_bearing Timeout_floor.Llm_call)
;;

let () =
  Alcotest.run
    "timeout_floor"
    [ ( "typed floors"
      , [ Alcotest.test_case "defaults" `Quick test_default_table
        ; Alcotest.test_case "clamp" `Quick test_clamp
        ; Alcotest.test_case "load-bearing" `Quick test_load_bearing
        ] )
    ]
;;
