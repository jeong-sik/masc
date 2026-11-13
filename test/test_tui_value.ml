(* What is checked is the decision a notation rests on, not the text a screen
   draws with it: which of today, this year and another year a moment falls
   in, how far the operator's zone stands from UTC across a year's end,
   where a count's separators go around a sign, and which numbers an English
   count names in the singular. *)

module Instant = Masc_tui_value.Instant
module Count = Masc_tui_value.Count
module Hash = Masc_tui_value.Hash

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

(* East of Greenwich the local day turns first. At 00:30 on January 1 in
   UTC+9 it is still December 31 in UTC, in another year with a larger day
   number: the clock fields alone would put the zone fifteen hours behind. *)
let test_the_offset_survives_new_year_east_of_utc () =
  Alcotest.(check int) "00:30 January 1 against 15:30 December 31" 540
    (Instant.offset_minutes
       ~utc:(day ~year:2026 ~yday:last_day_of_the_year ~hour:15 ~minute:30)
       ~local:(day ~year:2027 ~yday:0 ~hour:0 ~minute:30))

let test_the_offset_survives_new_year_west_of_utc () =
  Alcotest.(check int) "16:00 December 31 against 00:00 January 1" (-480)
    (Instant.offset_minutes
       ~utc:(day ~year:2027 ~yday:0 ~hour:0 ~minute:0)
       ~local:(day ~year:2026 ~yday:last_day_of_the_year ~hour:16 ~minute:0))

(* A zone behind UTC by hours and minutes: the sign belongs to the whole
   distance, not to the hour figure alone. *)
let test_a_zone_label_carries_one_sign () =
  List.iter
    (fun (offset_minutes, expected) ->
      Alcotest.(check string) (string_of_int offset_minutes) expected
        (Instant.zone_label ~offset_minutes))
    [ (0, "UTC"); (540, "UTC+9"); (-480, "UTC-8"); (330, "UTC+5:30"); (-210, "UTC-3:30") ]

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

(* English names one thing in the singular and every other number, zero
   included, in the plural, and the figure is grouped like any other. *)
let test_only_one_is_singular () =
  List.iter
    (fun (count, expected) ->
      Alcotest.(check string) (string_of_int count) expected
        (Count.reading ~ko:false Count.Entry count))
    [ (0, "0 entries"); (1, "1 entry"); (2, "2 entries"); (8347, "8,347 entries") ]

(* A digest is drawn by its head, so the shown text is the start a reader can
   find in the copied whole. A value shorter than the cut comes back whole
   instead of raising. *)
let test_a_hash_keeps_its_head () =
  let digest = "0b9c6e1f4a2d7c3e8f5a1b6c2d7e3f8a4b9c5d0e1f6a2b7c3d8e4f9a5b0c6d1e" in
  Alcotest.(check string) "a 64-character digest" (String.sub digest 0 12)
    (Hash.short digest);
  Alcotest.(check string) "a value shorter than the cut" "0b9c" (Hash.short "0b9c")

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
    ; ( "zone",
        [ Alcotest.test_case "offset across new year, east" `Quick
            test_the_offset_survives_new_year_east_of_utc
        ; Alcotest.test_case "offset across new year, west" `Quick
            test_the_offset_survives_new_year_west_of_utc
        ; Alcotest.test_case "a label carries one sign" `Quick
            test_a_zone_label_carries_one_sign
        ] )
    ; ( "count",
        [ Alcotest.test_case "a sign is not a digit" `Quick test_a_sign_is_not_a_digit
        ; Alcotest.test_case "only one is singular" `Quick test_only_one_is_singular
        ] )
    ; ( "hash",
        [ Alcotest.test_case "a hash keeps its head" `Quick test_a_hash_keeps_its_head ] )
    ]
