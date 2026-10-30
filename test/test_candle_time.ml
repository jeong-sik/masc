(** The instant a Candle ledger row carries: whole-second UTC, and only that. *)

let check_error label result =
  Alcotest.(check bool)
    label
    true
    (match result with
     | Ok _ -> false
     | Error _ -> true)
;;

let test_time_reads_only_what_it_writes () =
  let text = "2026-09-29T06:00:00Z" in
  (match Candle_time.of_rfc3339 text with
   | Ok instant -> Alcotest.(check string) "round trip" text (Candle_time.to_rfc3339 instant)
   | Error detail -> Alcotest.failf "%s" detail);
  List.iter
    (fun (label, text) -> check_error label (Candle_time.of_rfc3339 text))
    [ "offset", "2026-09-29T15:00:00+09:00"
    ; "fraction", "2026-09-29T06:00:00.5Z"
    ; "lowercase z", "2026-09-29T06:00:00z"
    ; "space", "2026-09-29 06:00:00Z"
    ; "short month", "2026-9-29T06:00:00Z"
    ; "date only", "2026-09-29"
    ; "trailing text", "2026-09-29T06:00:00Z "
    ; "empty", ""
    ]
;;

let test_time_truncates_a_source_fraction () =
  match Ptime.of_rfc3339 "2026-09-29T06:00:00.750Z" with
  | Error _ -> Alcotest.fail "the probe timestamp does not parse"
  | Ok (instant, _, _) ->
    Alcotest.(check string)
      "whole second"
      "2026-09-29T06:00:00Z"
      (Candle_time.to_rfc3339 (Candle_time.of_ptime instant))
;;

let test_time_compares_like_its_text () =
  let earlier = Result.get_ok (Candle_time.of_rfc3339 "2026-09-29T06:00:00Z") in
  let later = Result.get_ok (Candle_time.of_rfc3339 "2026-09-29T06:00:01Z") in
  Alcotest.(check bool) "before" true (Candle_time.compare earlier later < 0);
  Alcotest.(check bool) "equal" true (Candle_time.equal earlier earlier)
;;

let () =
  Alcotest.run
    "candle_time"
    [ ( "time"
      , [ Alcotest.test_case "reads only what it writes" `Quick test_time_reads_only_what_it_writes
        ; Alcotest.test_case
            "truncates a source fraction"
            `Quick
            test_time_truncates_a_source_fraction
        ; Alcotest.test_case "compares like its text" `Quick test_time_compares_like_its_text
        ] )
    ]
;;
