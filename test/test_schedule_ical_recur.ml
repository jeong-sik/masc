(* RFC 5545 §3.3.10 RECUR value tests for Schedule_ical_recur.

   Pure parser/serializer tests: valid fixtures bind exact typed values,
   malformed/semantic violations bind the exact typed error, and the
   canonical serializer round-trips through the parser. *)

open Alcotest
module R = Schedule_ical_recur

let parse_ok raw =
  match R.parse raw with
  | Ok t -> t
  | Error e -> failf "parse %S rejected: %s" raw (R.parse_error_to_string e)

let parse_error raw =
  match R.parse raw with
  | Ok _ -> failf "parse %S unexpectedly accepted" raw
  | Error e -> e

(* ---------------------------------------------------------------- *)
(* Valid grammar                                                    *)
(* ---------------------------------------------------------------- *)

let test_freq_only_defaults () =
  let t = parse_ok "FREQ=DAILY" in
  check bool "freq" true (t.R.freq = R.Daily);
  check int "interval default 1" 1 t.R.interval;
  check bool "forever" true (match t.R.bound with R.Forever -> true | _ -> false);
  check bool "wkst default MO" true (t.R.wkst = R.Monday);
  check bool "by lists empty" true
    (t.R.bysecond = [] && t.R.byminute = [] && t.R.byhour = []
    && t.R.byday = [] && t.R.bymonthday = [] && t.R.byyearday = []
    && t.R.byweekno = [] && t.R.bymonth = [] && t.R.bysetpos = [])

let test_all_freqs_accepted () =
  List.iter
    (fun (raw, expected) ->
      let t = parse_ok ("FREQ=" ^ raw) in
      check bool raw true (t.R.freq = expected))
    [ "SECONDLY", R.Secondly
    ; "MINUTELY", R.Minutely
    ; "HOURLY", R.Hourly
    ; "DAILY", R.Daily
    ; "WEEKLY", R.Weekly
    ; "MONTHLY", R.Monthly
    ; "YEARLY", R.Yearly
    ]

let test_parts_any_order () =
  (* The RFC requires parsers to accept any part order. *)
  let t = parse_ok "INTERVAL=2;COUNT=10;FREQ=WEEKLY;BYDAY=MO,WE" in
  check int "interval" 2 t.R.interval;
  check bool "count" true
    (match t.R.bound with R.Count 10 -> true | _ -> false);
  check bool "byday" true
    (match t.R.byday with
     | [ { R.ordinal = None; day = R.Monday }
       ; { R.ordinal = None; day = R.Wednesday }
       ] -> true
     | _ -> false)

let test_case_insensitive_names_and_enums () =
  let t = parse_ok "freq=weekly;byday=mo,fr;wkst=su" in
  check bool "freq" true (t.R.freq = R.Weekly);
  check bool "wkst" true (t.R.wkst = R.Sunday)

let test_numeric_byday_monthly () =
  let t = parse_ok "FREQ=MONTHLY;BYDAY=1MO,-1FR" in
  check bool "ordinals" true
    (match t.R.byday with
     | [ { R.ordinal = Some 1; day = R.Monday }
       ; { R.ordinal = Some (-1); day = R.Friday }
       ] -> true
     | _ -> false)

let test_until_utc () =
  let t = parse_ok "FREQ=DAILY;UNTIL=19971102T020000Z" in
  match t.R.bound with
  | R.Until (R.Until_utc (d, tm)) ->
    check bool "date" true
      (d.R.year = 1997 && d.R.month = 11 && d.R.day = 2);
    check bool "time" true
      (tm.R.hour = 2 && tm.R.minute = 0 && tm.R.second = 0)
  | _ -> fail "expected Until_utc"

let test_until_date_and_local () =
  let a = parse_ok "FREQ=DAILY;UNTIL=19971102" in
  (match a.R.bound with
   | R.Until (R.Until_date d) ->
     check bool "date form" true
       (d.R.year = 1997 && d.R.month = 11 && d.R.day = 2)
   | _ -> fail "expected Until_date");
  let b = parse_ok "FREQ=DAILY;UNTIL=19971102T020000" in
  match b.R.bound with
  | R.Until (R.Until_local (d, tm)) ->
    check bool "local date" true
      (d.R.year = 1997 && d.R.month = 11 && d.R.day = 2);
    check bool "local time" true
      (tm.R.hour = 2 && tm.R.minute = 0 && tm.R.second = 0)
  | _ -> fail "expected Until_local"

let test_full_example () =
  (* RFC 5545 example: last work day of the month. *)
  let t = parse_ok "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1" in
  check bool "bysetpos" true (t.R.bysetpos = [ -1 ]);
  check int "byday length" 5 (List.length t.R.byday)

let test_signed_lists () =
  let t =
    parse_ok
      "FREQ=YEARLY;BYWEEKNO=20,-1;BYMONTH=1,12;BYYEARDAY=1,-306;BYMONTHDAY=1,-31"
  in
  check bool "byweekno" true (t.R.byweekno = [ 20; -1 ]);
  check bool "bymonth" true (t.R.bymonth = [ 1; 12 ]);
  check bool "byyearday" true (t.R.byyearday = [ 1; -306 ]);
  check bool "bymonthday" true (t.R.bymonthday = [ 1; -31 ])

let test_leap_second_and_date () =
  let t = parse_ok "FREQ=MINUTELY;BYSECOND=0,60;UNTIL=20240229T235960Z" in
  check bool "bysecond 60 ok" true (t.R.bysecond = [ 0; 60 ]);
  match t.R.bound with
  | R.Until (R.Until_utc (d, tm)) ->
    check bool "leap day ok" true
      (d.R.year = 2024 && d.R.month = 2 && d.R.day = 29);
    check bool "leap second ok" true
      (tm.R.hour = 23 && tm.R.minute = 59 && tm.R.second = 60)
  | _ -> fail "expected Until_utc"

(* ---------------------------------------------------------------- *)
(* Grammar violations                                               *)
(* ---------------------------------------------------------------- *)

let test_missing_freq () =
  match parse_error "COUNT=3" with
  | R.Missing_freq -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_empty_input_and_parts () =
  check bool "empty" true (R.parse "" = Error R.Empty_part);
  check bool "double semicolon" true
    (R.parse "FREQ=DAILY;;INTERVAL=2" = Error R.Empty_part);
  check bool "trailing semicolon" true
    (R.parse "FREQ=DAILY;" = Error R.Empty_part)

let test_missing_equals () =
  match parse_error "FREQ" with
  | R.Missing_equals "FREQ" -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_unknown_part () =
  match parse_error "FREQ=DAILY;BYEPOCH=1" with
  | R.Unknown_part "BYEPOCH" -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_duplicate_part () =
  match parse_error "FREQ=DAILY;FREQ=WEEKLY" with
  | R.Duplicate_part "FREQ" -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_invalid_freq () =
  match parse_error "FREQ=FORTNIGHTLY" with
  | R.Invalid_freq "FORTNIGHTLY" -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_invalid_number () =
  check bool "nondigit" true
    (match R.parse "FREQ=DAILY;INTERVAL=x" with
     | Error (R.Invalid_number { part = "INTERVAL"; _ }) -> true
     | _ -> false);
  check bool "signed count rejected" true
    (match R.parse "FREQ=DAILY;COUNT=+3" with
     | Error (R.Invalid_number { part = "COUNT"; _ }) -> true
     | _ -> false);
  check bool "empty list element" true
    (match R.parse "FREQ=DAILY;BYMONTH=1,,2" with
     | Error (R.Invalid_number { part = "BYMONTH"; _ }) -> true
     | _ -> false)

let test_out_of_range () =
  let cases =
    [ "FREQ=DAILY;BYHOUR=24", ("BYHOUR", 24, 0, 23)
    ; "FREQ=DAILY;BYMINUTE=60", ("BYMINUTE", 60, 0, 59)
    ; "FREQ=DAILY;BYSECOND=61", ("BYSECOND", 61, 0, 60)
    ; "FREQ=DAILY;BYMONTH=13", ("BYMONTH", 13, 1, 12)
    ; "FREQ=YEARLY;BYWEEKNO=54", ("BYWEEKNO", 54, -53, 53)
    ; "FREQ=DAILY;BYMONTHDAY=32", ("BYMONTHDAY", 32, -31, 31)
    ; "FREQ=YEARLY;BYYEARDAY=367", ("BYYEARDAY", 367, -366, 366)
    ; "FREQ=MONTHLY;BYDAY=54MO", ("BYDAY", 54, -53, 53)
    ; "FREQ=DAILY;INTERVAL=0", ("INTERVAL", 0, 1, max_int)
    ; "FREQ=DAILY;COUNT=0", ("COUNT", 0, 1, max_int)
    ]
  in
  List.iter
    (fun (raw, (part, value, min, max)) ->
      match R.parse raw with
      | Error (R.Out_of_range got) ->
        check string "part" part got.part;
        check int "value" value got.value;
        check int "min" min got.min;
        check int "max" max got.max
      | _ -> failf "parse %S: expected Out_of_range" raw)
    cases

let test_zero_in_signed_lists () =
  check bool "byday 0" true
    (R.parse "FREQ=MONTHLY;BYDAY=0MO"
    = Error (R.Out_of_range { part = "BYDAY"; value = 0; min = -53; max = 53 }));
  check bool "bysetpos 0" true
    (match R.parse "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=0" with
     | Error (R.Out_of_range { part = "BYSETPOS"; value = 0; _ }) -> true
     | _ -> false)

let test_grammar_digit_caps () =
  (* Bounded numeric parts carry ABNF digit caps (1*2DIGIT / 1*3DIGIT);
     excess digits are a grammar violation, not a value to normalize. *)
  let rejected =
    [ "FREQ=MONTHLY;BYDAY=001MO", "BYDAY"
    ; "FREQ=DAILY;BYSECOND=001", "BYSECOND"
    ; "FREQ=DAILY;BYMINUTE=007", "BYMINUTE"
    ; "FREQ=DAILY;BYHOUR=009", "BYHOUR"
    ; "FREQ=DAILY;BYMONTH=013", "BYMONTH"
    ; "FREQ=DAILY;BYMONTHDAY=015", "BYMONTHDAY"
    ; "FREQ=YEARLY;BYWEEKNO=020", "BYWEEKNO"
    ; "FREQ=YEARLY;BYYEARDAY=0001", "BYYEARDAY"
    ; "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=0001", "BYSETPOS"
    ]
  in
  List.iter
    (fun (raw, part) ->
      match R.parse raw with
      | Error (R.Invalid_number got) ->
        check string "part" part got.part
      | _ -> failf "parse %S: expected Invalid_number" raw)
    rejected;
  (* COUNT and INTERVAL are 1*DIGIT (uncapped): leading zeros are legal. *)
  (match R.parse "FREQ=DAILY;COUNT=000003" with
   | Ok t ->
     check bool "count leading zeros" true
       (match t.R.bound with R.Count 3 -> true | _ -> false)
   | Error e -> failf "COUNT leading zeros rejected: %s"
       (R.parse_error_to_string e));
  match R.parse "FREQ=DAILY;INTERVAL=007" with
  | Ok t -> check int "interval leading zeros" 7 t.R.interval
  | Error e -> failf "INTERVAL leading zeros rejected: %s"
      (R.parse_error_to_string e)

let test_invalid_dates () =
  check bool "feb 30" true
    (R.parse "FREQ=DAILY;UNTIL=20260230"
    = Error (R.Invalid_until "20260230"));
  check bool "month 13" true
    (R.parse "FREQ=DAILY;UNTIL=20261301"
    = Error (R.Invalid_until "20261301"));
  check bool "non-leap feb 29" true
    (R.parse "FREQ=DAILY;UNTIL=20260229"
    = Error (R.Invalid_until "20260229"));
  check bool "leap feb 29 ok" true
    (match R.parse "FREQ=DAILY;UNTIL=20280229" with
     | Ok _ -> true
     | Error _ -> false)

let test_invalid_until_shape () =
  check bool "garbage" true
    (match R.parse "FREQ=DAILY;UNTIL=tomorrow" with
     | Error (R.Invalid_until _) -> true
     | _ -> false);
  check bool "offset form forbidden" true
    (match R.parse "FREQ=DAILY;UNTIL=19980119T230000-0800" with
     | Error (R.Invalid_until _) -> true
     | _ -> false)

let test_invalid_weekday () =
  match parse_error "FREQ=WEEKLY;BYDAY=XX" with
  | R.Invalid_weekday "XX" -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

(* ---------------------------------------------------------------- *)
(* Semantic (cross-part) violations                                 *)
(* ---------------------------------------------------------------- *)

let test_until_count_conflict () =
  match parse_error "FREQ=DAILY;UNTIL=19971102T020000Z;COUNT=3" with
  | R.Until_count_conflict -> ()
  | e -> failf "wrong error: %s" (R.parse_error_to_string e)

let test_numeric_byday_freq_rule () =
  check bool "daily rejected" true
    (R.parse "FREQ=DAILY;BYDAY=1MO"
    = Error (R.Numeric_byday_not_allowed R.Daily));
  check bool "weekly rejected" true
    (R.parse "FREQ=WEEKLY;BYDAY=1MO"
    = Error (R.Numeric_byday_not_allowed R.Weekly));
  check bool "monthly ok" true
    (match R.parse "FREQ=MONTHLY;BYDAY=1MO" with
     | Ok _ -> true
     | Error _ -> false);
  check bool "yearly ok" true
    (match R.parse "FREQ=YEARLY;BYDAY=20MO" with
     | Ok _ -> true
     | Error _ -> false)

let test_numeric_byday_with_byweekno () =
  check bool "yearly+byweekno rejected" true
    (R.parse "FREQ=YEARLY;BYDAY=1MO;BYWEEKNO=20"
    = Error R.Numeric_byday_with_byweekno)

let test_bymonthday_weekly () =
  check bool "weekly rejected" true
    (R.parse "FREQ=WEEKLY;BYMONTHDAY=15" = Error R.Bymonthday_with_weekly)

let test_byyearday_freq_rule () =
  List.iter
    (fun (raw_freq, expected) ->
      check bool raw_freq true
        (R.parse (Printf.sprintf "FREQ=%s;BYYEARDAY=100" raw_freq)
        = Error (R.Byyearday_not_allowed expected)))
    [ "DAILY", R.Daily; "WEEKLY", R.Weekly; "MONTHLY", R.Monthly ];
  check bool "yearly ok" true
    (match R.parse "FREQ=YEARLY;BYYEARDAY=100" with
     | Ok _ -> true
     | Error _ -> false)

let test_byweekno_freq_rule () =
  check bool "monthly rejected" true
    (R.parse "FREQ=MONTHLY;BYWEEKNO=20"
    = Error (R.Byweekno_not_allowed R.Monthly))

let test_bysetpos_requires_byxxx () =
  check bool "alone rejected" true
    (R.parse "FREQ=MONTHLY;BYSETPOS=-1" = Error R.Bysetpos_without_byxxx);
  check bool "with bymonth ok" true
    (match R.parse "FREQ=YEARLY;BYMONTH=6,7;BYSETPOS=1" with
     | Ok _ -> true
     | Error _ -> false)

(* ---------------------------------------------------------------- *)
(* Canonical serialization round-trip                               *)
(* ---------------------------------------------------------------- *)

let test_round_trip () =
  let fixtures =
    [ "FREQ=DAILY"
    ; "FREQ=SECONDLY;INTERVAL=90"
    ; "FREQ=WEEKLY;BYDAY=MO,WE,FR;WKST=SU;COUNT=10"
    ; "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"
    ; "FREQ=MONTHLY;BYDAY=1MO,-1FR;BYMONTH=3,6,9,12"
    ; "FREQ=YEARLY;BYWEEKNO=20;BYDAY=MO;BYMONTH=5"
    ; "FREQ=YEARLY;BYYEARDAY=1,100,-1;BYHOUR=9,18;BYMINUTE=30;BYSECOND=0"
    ; "FREQ=DAILY;UNTIL=19971102T020000Z"
    ; "FREQ=DAILY;UNTIL=19971102"
    ; "FREQ=DAILY;UNTIL=19971102T020000"
    ; "FREQ=HOURLY;INTERVAL=3;UNTIL=20280229T000000Z"
    ; "FREQ=YEARLY;BYMONTHDAY=1,-31;BYMONTH=2"
    ]
  in
  List.iter
    (fun raw ->
      let t = parse_ok raw in
      let rendered = R.to_string t in
      match R.parse rendered with
      | Ok t2 ->
        check bool (Printf.sprintf "round-trip %S" raw) true (t = t2)
      | Error e ->
        failf "re-parse of %S failed: %s" rendered
          (R.parse_error_to_string e))
    fixtures

let test_canonical_order () =
  (* FREQ first regardless of input order (RFC backward-compat rule). *)
  let t = parse_ok "COUNT=5;BYDAY=TU;FREQ=WEEKLY" in
  check string "canonical" "FREQ=WEEKLY;COUNT=5;INTERVAL=1;BYDAY=TU;WKST=MO"
    (R.to_string t)

(* ---------------------------------------------------------------- *)

let () =
  run "Schedule_ical_recur"
    [ "valid"
      , [ test_case "freq only defaults" `Quick test_freq_only_defaults
        ; test_case "all freqs accepted" `Quick test_all_freqs_accepted
        ; test_case "parts any order" `Quick test_parts_any_order
        ; test_case "case insensitive" `Quick
            test_case_insensitive_names_and_enums
        ; test_case "numeric byday monthly" `Quick test_numeric_byday_monthly
        ; test_case "until utc" `Quick test_until_utc
        ; test_case "until date and local" `Quick test_until_date_and_local
        ; test_case "full example" `Quick test_full_example
        ; test_case "signed lists" `Quick test_signed_lists
        ; test_case "leap second and date" `Quick test_leap_second_and_date
        ]
    ; "grammar violations"
      , [ test_case "missing freq" `Quick test_missing_freq
        ; test_case "empty input and parts" `Quick
            test_empty_input_and_parts
        ; test_case "missing equals" `Quick test_missing_equals
        ; test_case "unknown part" `Quick test_unknown_part
        ; test_case "duplicate part" `Quick test_duplicate_part
        ; test_case "invalid freq" `Quick test_invalid_freq
        ; test_case "invalid number" `Quick test_invalid_number
        ; test_case "out of range" `Quick test_out_of_range
        ; test_case "zero in signed lists" `Quick test_zero_in_signed_lists
        ; test_case "grammar digit caps" `Quick test_grammar_digit_caps
        ; test_case "invalid dates" `Quick test_invalid_dates
        ; test_case "invalid until shape" `Quick test_invalid_until_shape
        ; test_case "invalid weekday" `Quick test_invalid_weekday
        ]
    ; "semantic violations"
      , [ test_case "until+count conflict" `Quick test_until_count_conflict
        ; test_case "numeric byday freq rule" `Quick
            test_numeric_byday_freq_rule
        ; test_case "numeric byday + byweekno" `Quick
            test_numeric_byday_with_byweekno
        ; test_case "bymonthday weekly" `Quick test_bymonthday_weekly
        ; test_case "byyearday freq rule" `Quick test_byyearday_freq_rule
        ; test_case "byweekno freq rule" `Quick test_byweekno_freq_rule
        ; test_case "bysetpos requires byxxx" `Quick
            test_bysetpos_requires_byxxx
        ]
    ; "serialization"
      , [ test_case "round trip" `Quick test_round_trip
        ; test_case "canonical order" `Quick test_canonical_order
        ]
    ]
