open Masc

module Cfg = Env_config_oas_bridge

let test_typed_caller_keys () =
  Alcotest.(check string)
    "anti-rationalization attribution"
    "anti_rationalization"
    (Cfg.caller_key Cfg.Anti_rationalization);
  Alcotest.(check string)
    "operator judge attribution"
    "operator_judge"
    (Cfg.caller_key Cfg.Operator_judge);
  Alcotest.(check string)
    "future caller attribution"
    "future"
    (Cfg.caller_key (Cfg.Unknown "future"))
;;

let () =
  Alcotest.run
    "oas_bridge_judge_callers_9629"
    [ "attribution", [ Alcotest.test_case "typed caller keys" `Quick test_typed_caller_keys ] ]
;;
