(** The Board score cell signs a negative tally exactly once.

    The row used to print "+%d" over the integer, so a negative tally read
    "+-3". The cell now goes through one helper; these pin its sign contract
    so the row cannot reintroduce the doubled sign. *)

open Alcotest

let test_a_negative_tally_keeps_its_own_sign () =
  check string "-3, never +-3" "-3" (Masc_tui_board_score.text (-3))

let test_a_positive_tally_is_explicitly_signed () =
  check string "+3" "+3" (Masc_tui_board_score.text 3)

let test_zero_is_signed () =
  check string "+0" "+0" (Masc_tui_board_score.text 0)

let () =
  run "tui_board_score"
    [ ( "score cell"
      , [ test_case "a negative tally keeps its own sign" `Quick
            test_a_negative_tally_keeps_its_own_sign
        ; test_case "a positive tally is explicitly signed" `Quick
            test_a_positive_tally_is_explicitly_signed
        ; test_case "zero is signed" `Quick test_zero_is_signed
        ] )
    ]
