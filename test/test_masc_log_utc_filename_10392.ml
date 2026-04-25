(** #10392: system_log filename used [Unix.localtime] (KST in operator
    setup) while entries used UTC.  Result: system_log_2026-04-26.jsonl
    contained only entries dated 2026-04-25T15:xx:xxZ — KST midnight
    boundary lands at UTC 15:00, so [grep 2026-04-26] hit zero rows in
    today's file.  These tests pin the now-UTC convention against
    synthetic timestamps so the regression cannot creep back in via a
    timezone-naive helper. *)

open Alcotest
module L = Log

(* 2026-04-25T15:00:00Z = KST 2026-04-26T00:00:00 — this is the exact
   boundary that pre-fix landed entries in the wrong file. *)
let kst_midnight_utc = 1777129200.0

(* Sanity: a known UTC instant. *)
let known_utc = 1777089600.0  (* 2026-04-25T04:00:00Z *)

let test_kst_midnight_lands_in_utc_25 () =
  check string "KST midnight is still UTC date 2026-04-25"
    "2026-04-25"
    (L.format_utc_date_of kst_midnight_utc)

let test_kst_midnight_minus_1s_also_25 () =
  check string "1 second before KST midnight is also UTC 2026-04-25"
    "2026-04-25"
    (L.format_utc_date_of (kst_midnight_utc -. 1.0))

let test_kst_midnight_plus_1s_still_25 () =
  check string "1 second after KST midnight is still UTC 2026-04-25"
    "2026-04-25"
    (L.format_utc_date_of (kst_midnight_utc +. 1.0))

let test_known_utc_morning () =
  check string "2026-04-25T04:00:00Z formats as 2026-04-25"
    "2026-04-25"
    (L.format_utc_date_of known_utc)

let test_utc_day_boundary () =
  (* 2026-04-26T00:00:00Z = UTC midnight = KST 09:00 same day *)
  check string "UTC midnight rolls the date over"
    "2026-04-26"
    (L.format_utc_date_of (kst_midnight_utc +. 9.0 *. 3600.0))

let () =
  run "masc_log_utc_filename_10392" [
    ("utc_filename", [
        test_case "KST midnight lands in UTC date -1" `Quick
          test_kst_midnight_lands_in_utc_25;
        test_case "1s before KST midnight" `Quick
          test_kst_midnight_minus_1s_also_25;
        test_case "1s after KST midnight (UTC 15:00:01)" `Quick
          test_kst_midnight_plus_1s_still_25;
        test_case "known UTC morning timestamp" `Quick
          test_known_utc_morning;
        test_case "UTC midnight rolls forward" `Quick
          test_utc_day_boundary;
      ]);
  ]
