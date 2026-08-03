open Alcotest

module Broadcast_wakeup = Server_bootstrap_loops.For_testing

let test_mention_wakes_target () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "rondo") with
  | `Wake_keeper "rondo" -> ()
  | `Wake_keeper other -> failf "unexpected wake target: %s" other
  | `Wake_all_keepers -> fail "expected explicit mention to wake target"

let test_none_wakes_all () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action None with
  | `Wake_all_keepers -> ()
  | `Wake_keeper target -> failf "unexpected targeted wake: %s" target

let test_blank_wakes_all () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "  ") with
  | `Wake_all_keepers -> ()
  | `Wake_keeper target -> failf "unexpected targeted wake: %s" target

let () =
  run
    "broadcast_wakeup_policy"
    [
      ( "mention_policy"
      , [
          test_case "explicit mention wakes target" `Quick test_mention_wakes_target
        ; test_case "no mention wakes all keepers" `Quick test_none_wakes_all
        ; test_case "blank mention wakes all keepers" `Quick test_blank_wakes_all
        ] )
    ]
