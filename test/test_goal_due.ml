(* Goal_due: the one reading of a Goal's due date. A due date is YYYY-MM-DD
   for a day that exists, and it falls due at 23:59:59 UTC of that day. Every
   instant is an argument; nothing here reads a clock. *)

open Alcotest

let utc year month day hour minute second =
  match Ptime.of_date_time ((year, month, day), ((hour, minute, second), 0)) with
  | Some instant -> instant
  | None -> failwith "test setup: not a calendar instant"

let ptime = testable Ptime.pp Ptime.equal

let due_date raw = Goal_due.read (Some raw)

let unreadable raw =
  match due_date raw with
  | Goal_due.Unreadable_due_date kept ->
    check string (Printf.sprintf "%S is kept as written" raw) raw kept
  | Goal_due.No_due_date -> failf "%S read as no due date" raw
  | Goal_due.Due_date _ -> failf "%S was read as a due date" raw

let test_no_value_is_no_due_date () =
  match Goal_due.read None with
  | Goal_due.No_due_date -> ()
  | Goal_due.Due_date _ | Goal_due.Unreadable_due_date _ ->
    fail "None was read as a value"

let test_a_calendar_day_falls_due_at_the_last_second_utc () =
  match due_date "2026-09-23" with
  | Goal_due.Due_date { date; instant } ->
    check (triple int int int) "the day as written" (2026, 9, 23) date;
    check ptime "23:59:59 UTC of that day" (utc 2026 9 23 23 59 59) instant
  | Goal_due.No_due_date | Goal_due.Unreadable_due_date _ ->
    fail "2026-09-23 was not read as a due date"

(* The leap-day rule is the calendar's, not this reader's: 2000 and 2028 have a
   29 February, 1900 and 2027 do not. *)
let test_leap_days_follow_the_calendar () =
  List.iter
    (fun raw ->
      match due_date raw with
      | Goal_due.Due_date _ -> ()
      | Goal_due.No_due_date | Goal_due.Unreadable_due_date _ ->
        failf "%S was not read as a due date" raw)
    [ "2000-02-29"; "2028-02-29"; "9999-12-31" ];
  List.iter unreadable [ "1900-02-29"; "2027-02-29"; "2026-02-30" ]

(* Only YYYY-MM-DD is a due date. "2026-9-3" is the one the old readers took as
   a date. "2_26", "+026", "0x1f", "1_" and "2_" are what [int_of_string_opt]
   alone would accept as a number. *)
let test_only_the_exact_shape_is_readable () =
  List.iter unreadable
    [ ""; "TBD"; "tomorrow"; "2026-9-3"; "2026-09-3"; "2026-9-03"; "26-09-23"
    ; "20260-09-23"; "2026-09"; "2026-09-23-01"; "2026/09/23"; "2026-13-01"
    ; "2026-00-10"; "2026-09-00"; "2026-09-31"; " 2026-09-23"; "2026-09-23 "
    ; "2026-09-23\n"; "2026-09-23T10:00:00Z"; "2026-0x-23"; "+026-09-23"
    ; "-026-09-23"; "2_26-09-23"; "2026-1_-23"; "2026-09-2_"; "0x1f-09-23" ]

(* The calendar is the oracle: for every well-formed digit string, the reader
   agrees with [Ptime.of_date] on whether the day exists. *)
let test_readable_exactly_when_the_day_exists () =
  for year = 1896 to 2104 do
    for month = 0 to 13 do
      for day = 0 to 32 do
        let raw = Printf.sprintf "%04d-%02d-%02d" year month day in
        let exists = Option.is_some (Ptime.of_date (year, month, day)) in
        match due_date raw with
        | Goal_due.Due_date { date; _ } ->
          check bool (raw ^ " exists") true exists;
          check (triple int int int) (raw ^ " keeps its digits") (year, month, day) date
        | Goal_due.Unreadable_due_date _ -> check bool (raw ^ " does not exist") false exists
        | Goal_due.No_due_date -> failf "%S read as no due date" raw
      done
    done
  done

(* Overdue is strictly after 23:59:59 UTC. The due instant itself is not late. *)
let test_overdue_is_strictly_after_the_due_instant () =
  let due = due_date "2026-09-23" in
  check bool "the morning of the day" false
    (Goal_due.is_overdue ~now:(utc 2026 9 23 0 0 0) due);
  check bool "23:59:58" false (Goal_due.is_overdue ~now:(utc 2026 9 23 23 59 58) due);
  check bool "23:59:59 is the due instant" false
    (Goal_due.is_overdue ~now:(utc 2026 9 23 23 59 59) due);
  check bool "00:00:00 the next day" true
    (Goal_due.is_overdue ~now:(utc 2026 9 24 0 0 0) due);
  check bool "a year later" true (Goal_due.is_overdue ~now:(utc 2027 9 23 12 0 0) due)

let test_a_value_that_is_not_a_due_date_is_never_overdue () =
  let far_future = utc 9999 12 31 23 59 59 in
  check bool "no due date" false (Goal_due.is_overdue ~now:far_future Goal_due.No_due_date);
  List.iter
    (fun raw ->
      check bool (raw ^ " is not overdue") false
        (Goal_due.is_overdue ~now:far_future (due_date raw)))
    [ ""; "TBD"; "2000-1-1"; " 2000-01-01"; "2000-13-01" ]

(* The day count is by UTC calendar day, so it turns over at 00:00:00Z. *)
let test_days_left_counts_utc_calendar_days () =
  let due = due_date "2026-09-23" in
  let days_left now = Goal_due.days_left ~now due in
  check (option int) "a week before, at the last second" (Some 7)
    (days_left (utc 2026 9 16 23 59 59));
  check (option int) "the day before, at midnight" (Some 1)
    (days_left (utc 2026 9 22 0 0 0));
  check (option int) "the day before, at the last second" (Some 1)
    (days_left (utc 2026 9 22 23 59 59));
  check (option int) "the due day, at midnight" (Some 0)
    (days_left (utc 2026 9 23 0 0 0));
  check (option int) "the due day, at the due instant" (Some 0)
    (days_left (utc 2026 9 23 23 59 59));
  check (option int) "the next day, at midnight" (Some (-1))
    (days_left (utc 2026 9 24 0 0 0));
  check (option int) "a month after" (Some (-30)) (days_left (utc 2026 10 23 12 0 0))

let test_days_left_crosses_a_year_and_a_leap_day () =
  check (option int) "31 December to 1 January" (Some 1)
    (Goal_due.days_left ~now:(utc 2026 12 31 12 0 0) (due_date "2027-01-01"));
  check (option int) "28 February to 1 March in a leap year" (Some 2)
    (Goal_due.days_left ~now:(utc 2028 2 28 12 0 0) (due_date "2028-03-01"));
  check (option int) "28 February to 1 March in a common year" (Some 1)
    (Goal_due.days_left ~now:(utc 2027 2 28 12 0 0) (due_date "2027-03-01"))

let test_days_left_needs_a_due_date () =
  let now = utc 2026 9 23 12 0 0 in
  check (option int) "no due date" None (Goal_due.days_left ~now Goal_due.No_due_date);
  check (option int) "an unreadable value" None (Goal_due.days_left ~now (due_date "TBD"))

let test_instant_is_the_due_moment_only_for_a_due_date () =
  check (option ptime) "a due date" (Some (utc 2026 9 23 23 59 59))
    (Goal_due.instant (due_date "2026-09-23"));
  check (option ptime) "no due date" None (Goal_due.instant Goal_due.No_due_date);
  check (option ptime) "an unreadable value" None (Goal_due.instant (due_date "TBD"))

let () =
  run "goal_due"
    [ ( "read"
      , [ test_case "no value is no due date" `Quick test_no_value_is_no_due_date
        ; test_case "a calendar day falls due at the last second UTC" `Quick
            test_a_calendar_day_falls_due_at_the_last_second_utc
        ; test_case "leap days follow the calendar" `Quick
            test_leap_days_follow_the_calendar
        ; test_case "only the exact shape is readable" `Quick
            test_only_the_exact_shape_is_readable
        ; test_case "readable exactly when the day exists" `Quick
            test_readable_exactly_when_the_day_exists
        ] )
    ; ( "overdue"
      , [ test_case "strictly after the due instant" `Quick
            test_overdue_is_strictly_after_the_due_instant
        ; test_case "a value that is not a due date is never overdue" `Quick
            test_a_value_that_is_not_a_due_date_is_never_overdue
        ] )
    ; ( "days left"
      , [ test_case "counts UTC calendar days" `Quick
            test_days_left_counts_utc_calendar_days
        ; test_case "crosses a year and a leap day" `Quick
            test_days_left_crosses_a_year_and_a_leap_day
        ; test_case "needs a due date" `Quick test_days_left_needs_a_due_date
        ] )
    ; ( "instant"
      , [ test_case "is the due moment only for a due date" `Quick
            test_instant_is_the_due_moment_only_for_a_due_date
        ] )
    ]
