(* Test coverage for PR #21175 — Phase3a: inverse recency bonus
   Tests keeper_heartbeat_stimulus_intake.stimulus_class_to_string *)

open Masc
open Masc_keeper_runtime

let test_stimulus_class_to_string_board_signal () =
  Alcotest.check Alcotest.string
    "same label" "board_signal"
    (Keeper_heartbeat_stimulus_intake.stimulus_class_to_string
       Keeper_event_queue.Board_signal)

let test_stimulus_class_to_string_bootstrap () =
  Alcotest.check Alcotest.string
    "same label" "bootstrap"
    (Keeper_heartbeat_stimulus_intake.stimulus_class_to_string
       Keeper_event_queue.Bootstrap)

let test_stimulus_class_to_string_stay_silent () =
  Alcotest.check Alcotest.string
    "same label" "stay_silent_recovery"
    (Keeper_heartbeat_stimulus_intake.stimulus_class_to_string
       Keeper_event_queue.Stay_silent_recovery)

let test_stimulus_class_to_string_unsupported () =
  Alcotest.check Alcotest.string
    "unsupported prefix" "unsupported"
    (Keeper_heartbeat_stimulus_intake.stimulus_class_to_string
       (Keeper_event_queue.Unsupported "unknown_test"))

let suite =
  [ ("stimulus_class_to_string", `Quick,
     [ Alcotest.test_case "board_signal" `Quick test_stimulus_class_to_string_board_signal
     ; Alcotest.test_case "bootstrap" `Quick test_stimulus_class_to_string_bootstrap
     ; Alcotest.test_case "stay_silent_recovery" `Quick test_stimulus_class_to_string_stay_silent
     ; Alcotest.test_case "unsupported" `Quick test_stimulus_class_to_string_unsupported
     ])
  ]

let () =
  Alcotest.run "Keeper_heartbeat_stimulus_intake" suite