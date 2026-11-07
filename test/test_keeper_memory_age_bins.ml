module Age_bins = Masc.Keeper_memory_age_bins

let now = 1_000_000.0

let test_classify () =
  let hour = Masc_time_constants.hour in
  let day = Masc_time_constants.day in
  let week = Masc_time_constants.days_to_seconds 7 in
  Alcotest.(check bool) "future treated as under_hour" true
    (Age_bins.classify ~now (now +. 100.0) = Age_bins.Under_hour);
  Alcotest.(check bool) "now is under_hour" true
    (Age_bins.classify ~now now = Age_bins.Under_hour);
  Alcotest.(check bool) "30m ago is under_hour" true
    (Age_bins.classify ~now (now -. (hour /. 2.0)) = Age_bins.Under_hour);
  Alcotest.(check bool) "exact 1h ago is under_day" true
    (Age_bins.classify ~now (now -. hour) = Age_bins.Under_day);
  Alcotest.(check bool) "5h ago is under_day" true
    (Age_bins.classify ~now (now -. (5.0 *. hour)) = Age_bins.Under_day);
  Alcotest.(check bool) "exact 1d ago is under_week" true
    (Age_bins.classify ~now (now -. day) = Age_bins.Under_week);
  Alcotest.(check bool) "3d ago is under_week" true
    (Age_bins.classify ~now (now -. (3.0 *. day)) = Age_bins.Under_week);
  Alcotest.(check bool) "exact 7d ago is older" true
    (Age_bins.classify ~now (now -. week) = Age_bins.Older);
  Alcotest.(check bool) "30d ago is older" true
    (Age_bins.classify ~now (now -. (30.0 *. day)) = Age_bins.Older)
;;

let test_of_first_seen () =
  let hour = Masc_time_constants.hour in
  let day = Masc_time_constants.day in
  let week = Masc_time_constants.days_to_seconds 7 in
  let empty = Age_bins.of_first_seen ~now [] in
  Alcotest.(check int) "empty under_hour" 0 empty.under_hour;
  Alcotest.(check int) "empty under_day" 0 empty.under_day;
  Alcotest.(check int) "empty under_week" 0 empty.under_week;
  Alcotest.(check int) "empty older" 0 empty.older;
  Alcotest.(check int) "empty total" 0 (Age_bins.total empty);

  let timestamps =
    [ now +. 10.0             (* future -> under_hour *)
    ; now -. 300.0            (* 5m ago -> under_hour *)
    ; now -. (2.0 *. hour)    (* 2h ago -> under_day *)
    ; now -. (10.0 *. hour)   (* 10h ago -> under_day *)
    ; now -. (20.0 *. hour)   (* 20h ago -> under_day *)
    ; now -. (2.0 *. day)     (* 2d ago -> under_week *)
    ; now -. (10.0 *. day)    (* 10d ago -> older *)
    ]
  in
  let bins = Age_bins.of_first_seen ~now timestamps in
  Alcotest.(check int) "2 under_hour" 2 bins.under_hour;
  Alcotest.(check int) "3 under_day" 3 bins.under_day;
  Alcotest.(check int) "1 under_week" 1 bins.under_week;
  Alcotest.(check int) "1 older" 1 bins.older;
  Alcotest.(check int) "total equals length" 7 (Age_bins.total bins)
;;

let test_json_roundtrip () =
  let bins : Age_bins.t =
    { under_hour = 12
    ; under_day = 34
    ; under_week = 56
    ; older = 78
    }
  in
  let json = Age_bins.to_json bins in
  match Age_bins.of_json json with
  | Error err -> Alcotest.fail err
  | Ok decoded ->
    Alcotest.(check int) "under_hour" 12 decoded.under_hour;
    Alcotest.(check int) "under_day" 34 decoded.under_day;
    Alcotest.(check int) "under_week" 56 decoded.under_week;
    Alcotest.(check int) "older" 78 decoded.older
;;

let test_json_rejects_malformed () =
  Alcotest.(check bool) "reject non-object" true
    (Result.is_error (Age_bins.of_json (`String "not an object")));
  let missing_field =
    `Assoc [ "under_hour", `Int 1; "under_day", `Int 2; "under_week", `Int 3 ]
  in
  Alcotest.(check bool) "reject missing field" true
    (Result.is_error (Age_bins.of_json missing_field));
  let negative_int =
    `Assoc
      [ "under_hour", `Int (-1)
      ; "under_day", `Int 2
      ; "under_week", `Int 3
      ; "older", `Int 4
      ]
  in
  Alcotest.(check bool) "reject negative int" true
    (Result.is_error (Age_bins.of_json negative_int))
;;

let () =
  Alcotest.run
    "keeper_memory_age_bins"
    [ ( "bins"
      , [ Alcotest.test_case "classify" `Quick test_classify
        ; Alcotest.test_case "of_first_seen" `Quick test_of_first_seen
        ; Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip
        ; Alcotest.test_case "json rejects malformed" `Quick test_json_rejects_malformed
        ] )
    ]
;;
