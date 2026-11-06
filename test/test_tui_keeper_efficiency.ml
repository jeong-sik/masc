(* The Info tab's efficiency read: which month it asks for, the request it
   sends, and that an answer it cannot read is a failure rather than an empty
   month. *)

module E = Masc_tui_keeper_efficiency

let test_the_read_asks_for_the_utc_month_of_now () =
  let month now = E.month_of ~now in
  Alcotest.(check string) "the last second of October, UTC" "2026-10" (month 1793491199.);
  Alcotest.(check string) "the first second of November, UTC" "2026-11" (month 1793491200.);
  Alcotest.(check string) "the year turns over" "2027-01" (month 1798761600.);
  Alcotest.(check string) "the same month the route answers without one"
    (Keeper_efficiency.month_of_unix_time 1798761599.)
    (month 1798761599.)
;;

let test_the_read_names_the_month_in_the_request () =
  Alcotest.(check string) "the month is always sent"
    "/api/v1/keeper-efficiency?month=2026-11" (E.path ~month:"2026-11")
;;

let test_an_unreadable_answer_is_a_failure () =
  let failed label json =
    match E.decode json with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "%s is not read as a month" label
  in
  failed "an empty object" (`Assoc []);
  failed "another schema" (`Assoc [ "schema", `String "masc.keeper-efficiency/v0" ]);
  failed "not an object" (`List [])
;;

let () =
  Alcotest.run
    "tui_keeper_efficiency"
    [ ( "read"
      , [ Alcotest.test_case "the read asks for the UTC month of now" `Quick
            test_the_read_asks_for_the_utc_month_of_now
        ; Alcotest.test_case "the read names the month in the request" `Quick
            test_the_read_names_the_month_in_the_request
        ; Alcotest.test_case "an unreadable answer is a failure" `Quick
            test_an_unreadable_answer_is_a_failure
        ] )
    ]
;;
