open Alcotest

module Broadcast_wakeup = Server_bootstrap_loops.For_testing

let test_mention_wakes_target () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "rondo") with
  | `Wake_keeper "rondo" -> ()
  | `Wake_keeper other -> failf "unexpected wake target: %s" other
  | `Suppress_no_target -> fail "expected explicit mention to wake target"

let test_none_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action None with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected no-target wake: %s" target

let test_blank_is_passive () =
  match Broadcast_wakeup.broadcast_mention_wakeup_action (Some "  ") with
  | `Suppress_no_target -> ()
  | `Wake_keeper target -> failf "unexpected blank-target wake: %s" target

let () =
  run
    "broadcast_wakeup_policy"
    [
      ( "mention_policy"
      , [
          test_case "explicit mention wakes target" `Quick test_mention_wakes_target
        ; test_case "no mention is passive" `Quick test_none_is_passive
        ; test_case "blank mention is passive" `Quick test_blank_is_passive
        ] )
    ]
