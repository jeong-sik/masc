(* Goal_due: the one reading of a Goal's due date. A due date is YYYY-MM-DD
   for a day that exists, and it falls due at 23:59:59 UTC of that day. *)

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
  | Goal_due.Due_date { instant } ->
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
        | Goal_due.Due_date { instant } ->
          check bool (raw ^ " exists") true exists;
          check (triple int int int) (raw ^ " keeps its digits") (year, month, day)
            (Ptime.to_date instant)
        | Goal_due.Unreadable_due_date _ -> check bool (raw ^ " does not exist") false exists
        | Goal_due.No_due_date -> failf "%S read as no due date" raw
      done
    done
  done

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
    ]
