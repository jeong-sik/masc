open Alcotest

(* 2026-09-23T00:31:39Z, the instant the live screen below was drawn. *)
let now = 1790123499.

let text = Masc_tui_wire_age.text ~now

(* The defect this closes. The cell drew the clock alone, so a dashboard
   session last seen on 2026-09-21 at 11:49 local read as 11:49 today --
   later than the 09:31 header beside it. *)
let test_a_stamp_from_another_day_says_how_long_ago () =
  check string "a day and some, not a clock" "1d21h"
    (text "2026-09-21T02:49:28Z")

let test_a_stamp_from_today_says_the_same_way () =
  check string "hours and minutes" "7h42m" (text "2026-09-22T16:48:58Z");
  check string "seconds" "1s" (text "2026-09-23T00:31:38Z")

(* Nothing was ever seen, which is not "seen a long time ago". *)
let test_no_stamp_is_never () = check string "never" "never" (text "")

(* A clock ahead of this one measures no age. Drawing a span would say how
   long ago something that has not happened yet happened. *)
let test_a_stamp_ahead_of_the_clock_is_not_a_span () =
  check string "the stamp as it came" "2026-09-23T09:00:00Z"
    (text "2026-09-23T09:00:00Z")

(* And neither does text the codec cannot read. *)
let test_an_unreadable_stamp_is_shown_as_it_came () =
  check string "the text as it came" "whenever" (text "whenever")

(* Whatever it draws is safe to draw: the fallbacks pass the wire text
   through, and a terminal escape in it must not reach the screen. *)
let test_a_fallback_neutralises_an_escape () =
  let drawn = text "\x1b[31mnot-a-time" in
  check bool
    (Printf.sprintf "%S carries no ESC byte" drawn)
    false
    (String.exists (fun c -> Char.code c = 0x1b) drawn)

let () =
  run "tui wire age"
    [ ( "how long ago a wire stamp was"
      , [ test_case "a stamp from another day says how long ago" `Quick
            test_a_stamp_from_another_day_says_how_long_ago
        ; test_case "a stamp from today says the same way" `Quick
            test_a_stamp_from_today_says_the_same_way
        ; test_case "no stamp is never" `Quick test_no_stamp_is_never
        ; test_case "a stamp ahead of the clock is not a span" `Quick
            test_a_stamp_ahead_of_the_clock_is_not_a_span
        ; test_case "an unreadable stamp is shown as it came" `Quick
            test_an_unreadable_stamp_is_shown_as_it_came
        ; test_case "a fallback neutralises an escape" `Quick
            test_a_fallback_neutralises_an_escape
        ] )
    ]
