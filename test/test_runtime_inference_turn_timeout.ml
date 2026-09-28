(** Tests for [Runtime_inference.turn_timeout_s_of_declared].

    Pinned rule (single site; all runtime keepers share it):

    1. [None] → [Some default]: an undeclared turn timeout falls back to the
       keeper's own default.
    2. [Some s] with [s > 0.0] → [Some s]: a positive declaration wins.
    3. [Some s] with [s <= 0.0] → [None]: a zero/negative declaration disables
       the timeout (fail-open by operator intent, like timeout=0 on the CLI).
*)

open Alcotest

let timeout = option (float 0.001)

let test_absent_falls_back_to_default () =
  check timeout "absent" (Some 300.0)
    (Runtime_inference.turn_timeout_s_of_declared ~default:300.0 None)
;;

let test_positive_declaration_wins () =
  check timeout "positive" (Some 90.0)
    (Runtime_inference.turn_timeout_s_of_declared ~default:300.0 (Some 90.0))
;;

let test_zero_disables_timeout () =
  check timeout "zero" None
    (Runtime_inference.turn_timeout_s_of_declared ~default:300.0 (Some 0.0))
;;

let test_negative_disables_timeout () =
  check timeout "negative" None
    (Runtime_inference.turn_timeout_s_of_declared ~default:300.0 (Some (-1.0)))
;;

let () =
  run
    "runtime-inference-turn-timeout"
    [ ( "turn_timeout_s_of_declared"
      , [ test_case "absent falls back to default" `Quick
            test_absent_falls_back_to_default
        ; test_case "positive declaration wins" `Quick
            test_positive_declaration_wins
        ; test_case "zero disables timeout" `Quick test_zero_disables_timeout
        ; test_case "negative disables timeout" `Quick
            test_negative_disables_timeout
        ] )
    ]
;;
