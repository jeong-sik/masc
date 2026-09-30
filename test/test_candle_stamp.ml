(** The times a runtime step puts on a ledger row: its own clock reading, and
    times copied from another store's text. *)

let is_error label = function
  | Ok (_ : Candle_time.t) -> Alcotest.failf "%s: expected an error" label
  | Error (_ : string) -> ()
;;

let test_the_clock_reading_is_cut_to_the_second () =
  match Candle_stamp.at ~now:(fun () -> 1_790_000_000.9) with
  | Ok instant ->
    Alcotest.(check string) "whole second" "2026-09-21T14:13:20Z" (Candle_time.to_rfc3339 instant)
  | Error detail -> Alcotest.failf "%s" detail
;;

let test_a_reading_outside_the_calendar_is_refused () =
  List.iter
    (fun (label, reading) -> is_error label (Candle_stamp.at ~now:(fun () -> reading)))
    [ "not a number", Float.nan
    ; "infinite", Float.infinity
    ; "far past the last year", 1e30
    ]
;;

let test_a_copied_time_is_taken_in_the_ledgers_form_only () =
  (match Candle_stamp.copied ~what:"the verdict's recorded_at" "2026-09-28T06:32:00Z" with
   | Ok instant ->
     Alcotest.(check string) "kept" "2026-09-28T06:32:00Z" (Candle_time.to_rfc3339 instant)
   | Error detail -> Alcotest.failf "%s" detail);
  match Candle_stamp.copied ~what:"the verdict's recorded_at" "2026-09-28T15:32:00+09:00" with
  | Ok _ -> Alcotest.fail "an offset was taken"
  | Error detail ->
    Alcotest.(check bool)
      "the error names the time"
      true
      (String_util.contains_substring detail "the verdict's recorded_at")
;;

let () =
  Alcotest.run
    "candle_stamp"
    [ ( "at"
      , [ Alcotest.test_case "the clock reading is cut to the second" `Quick
            test_the_clock_reading_is_cut_to_the_second
        ; Alcotest.test_case "a reading outside the calendar is refused" `Quick
            test_a_reading_outside_the_calendar_is_refused
        ] )
    ; ( "copied"
      , [ Alcotest.test_case "a copied time is taken in the ledger's form only" `Quick
            test_a_copied_time_is_taken_in_the_ledgers_form_only
        ] )
    ]
;;
