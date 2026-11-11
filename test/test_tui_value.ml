(* What is checked is the decision a notation rests on, not the text a screen
   draws with it: which of today, this year and another year a moment falls
   in, and where a count's separators go around a sign. *)

module Instant = Masc_tui_value.Instant
module Count = Masc_tui_value.Count

(* [Unix.tm] counts years from 1900. *)
let tm_year_origin = 1900

let day ~year ~yday ~hour ~minute =
  { Unix.tm_sec = 0
  ; tm_min = minute
  ; tm_hour = hour
  ; tm_mday = 1
  ; tm_mon = 0
  ; tm_year = year - tm_year_origin
  ; tm_wday = 0
  ; tm_yday = yday
  ; tm_isdst = false
  }

let distance =
  Alcotest.testable
    (fun ppf distance ->
      Format.pp_print_string ppf
        (match distance with
         | Instant.Same_day -> "Same_day"
         | Instant.Same_year -> "Same_year"
         | Instant.Other_year -> "Other_year"))
    ( = )

let november_11 = 314
let last_day_of_the_year = 364

let test_a_moment_earlier_today_is_the_same_day () =
  Alcotest.check distance "morning read in the evening" Instant.Same_day
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:19 ~minute:39)
       (day ~year:2026 ~yday:november_11 ~hour:0 ~minute:1))

(* The last minute of yesterday is two minutes old and still another day: the
   clock alone would read as if it were tonight's 23:59, which has not come. *)
let test_midnight_ends_the_day () =
  Alcotest.check distance "23:59 read at 00:01" Instant.Same_year
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:0 ~minute:1)
       (day ~year:2026 ~yday:(november_11 - 1) ~hour:23 ~minute:59))

(* The same day of the year, a year apart. A comparison that read the day
   alone would call it today and draw last year's moment as a bare clock. *)
let test_the_same_date_last_year_is_another_year () =
  Alcotest.check distance "one year back to the day" Instant.Other_year
    (Instant.distance
       ~now:(day ~year:2026 ~yday:november_11 ~hour:19 ~minute:39)
       (day ~year:2025 ~yday:november_11 ~hour:19 ~minute:39))

let test_new_year_ends_the_year () =
  Alcotest.check distance "December 31 read on January 1" Instant.Other_year
    (Instant.distance
       ~now:(day ~year:2027 ~yday:0 ~hour:0 ~minute:1)
       (day ~year:2026 ~yday:last_day_of_the_year ~hour:23 ~minute:59))

(* Two of the three copies this function replaced counted the minus sign as a
   digit, which puts a separator straight after it. *)
let test_a_sign_is_not_a_digit () =
  List.iter
    (fun (value, expected) ->
      Alcotest.(check string) (string_of_int value) expected (Count.grouped value))
    [ (999, "999")
    ; (1000, "1,000")
    ; (-999, "-999")
    ; (-1000, "-1,000")
    ; (-123456, "-123,456")
    ]

let () =
  Alcotest.run "tui_value"
    [ ( "instant distance",
        [ Alcotest.test_case "earlier today" `Quick
            test_a_moment_earlier_today_is_the_same_day
        ; Alcotest.test_case "midnight ends the day" `Quick test_midnight_ends_the_day
        ; Alcotest.test_case "the same date last year" `Quick
            test_the_same_date_last_year_is_another_year
        ; Alcotest.test_case "new year ends the year" `Quick test_new_year_ends_the_year
        ] )
    ; ( "count",
        [ Alcotest.test_case "a sign is not a digit" `Quick test_a_sign_is_not_a_digit ] )
    ]
