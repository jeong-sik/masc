(* RFC 5545 VEVENT recurrence-identity tests for Schedule_ical_vevent. *)

open Alcotest
module V = Schedule_ical_vevent
module C = Schedule_ical_content_line
module R = Schedule_ical_recur

let cl line =
  match C.parse ~line:1 line with
  | Ok cl -> cl
  | Error e -> failf "content line %S rejected: %s" line (C.parse_error_to_string e)

let parse_ok lines =
  match V.parse (List.map cl lines) with
  | Ok t -> t
  | Error e -> failf "vevent rejected: %s" (V.parse_error_to_string e)

let parse_error lines = V.parse (List.map cl lines)

let test_minimal_utc () =
  let t =
    parse_ok
      [ "UID:event-1@example.com"
      ; "DTSTART:19980118T230000Z"
      ]
  in
  check string "uid" "event-1@example.com" t.V.uid;
  (match t.V.dtstart with
   | V.Start_utc (d, tm) ->
     check bool "date" true (d.R.year = 1998 && d.R.month = 1 && d.R.day = 18);
     check bool "time" true (tm.R.hour = 23 && tm.R.minute = 0 && tm.R.second = 0)
   | _ -> fail "expected Start_utc");
  check bool "no rid" true (t.V.recurrence_id = None);
  check bool "no rrule" true (t.V.rrule = None)

let test_date_dtstart_with_date_until () =
  let t =
    parse_ok
      [ "UID:e2"
      ; "DTSTART;VALUE=DATE:19980118"
      ; "RRULE:FREQ=DAILY;UNTIL=19980201"
      ]
  in
  (match t.V.dtstart with
   | V.Start_date d ->
     check bool "date" true (d.R.year = 1998 && d.R.month = 1 && d.R.day = 18)
   | _ -> fail "expected Start_date");
  match t.V.rrule with
  | Some r -> (
    match r.R.bound with
    | R.Until (R.Until_date d) ->
      check bool "until date" true (d.R.month = 2 && d.R.day = 1)
    | _ -> fail "expected Until_date")
  | None -> fail "expected rrule"

let test_tzid_dtstart_allows_utc_until () =
  let t =
    parse_ok
      [ "UID:e3"
      ; "DTSTART;TZID=America/New_York:19980119T020000"
      ; "RRULE:FREQ=WEEKLY;UNTIL=19980301T000000Z"
      ]
  in
  match t.V.dtstart with
  | V.Start_tzid (tzid, _, _) ->
    check string "tzid" "America/New_York" (tzid :> string)
  | _ -> fail "expected Start_tzid"

let test_local_dtstart_with_local_until () =
  let _ =
    parse_ok
      [ "UID:e4"
      ; "DTSTART:19980119T020000"
      ; "RRULE:FREQ=DAILY;UNTIL=19980131T000000"
      ]
  in
  ()

let test_recurrence_id_matching_form () =
  let t =
    parse_ok
      [ "UID:e5"
      ; "DTSTART:19980118T230000Z"
      ; "RECURRENCE-ID:19980125T230000Z"
      ; "RRULE:FREQ=WEEKLY"
      ]
  in
  match t.V.recurrence_id with
  | Some { V.value = V.Start_utc (d, _); range = None } ->
    check bool "rid date" true (d.R.day = 25)
  | _ -> fail "expected one exact utc recurrence-id"

let test_range_this_and_future () =
  let t =
    parse_ok
      [ "UID:e6"
      ; "DTSTART:19980118T230000Z"
      ; "RECURRENCE-ID;RANGE=THISANDFUTURE:19980125T230000Z"
      ]
  in
  match t.V.recurrence_id with
  | Some { V.range = Some V.This_and_future; _ } -> ()
  | _ -> fail "expected THISANDFUTURE"

let test_explicit_date_time_value () =
  let t =
    parse_ok
      [ "UID:explicit-date-time"
      ; "DTSTART;VALUE=DATE-TIME:19980118T230000Z"
      ]
  in
  match t.V.dtstart with
  | V.Start_utc _ -> ()
  | _ -> fail "explicit VALUE=DATE-TIME must be accepted"

let test_uid_identity_is_exact () =
  let t = parse_ok [ "UID:  event-identity  "; "DTSTART:19980118T230000Z" ] in
  check string "uid bytes" "  event-identity  " t.V.uid

let test_tzid_identity_is_exact () =
  let t =
    parse_ok
      [ "UID:tzid-identity"
      ; "DTSTART;TZID=\" America/New_York \":19980119T020000"
      ]
  in
  match t.V.dtstart with
  | V.Start_tzid (tzid, _, _) ->
    check string "tzid bytes" " America/New_York " (tzid :> string)
  | _ -> fail "expected TZID-referenced DTSTART"

let test_ignored_other_properties () =
  let t =
    parse_ok
      [ "UID:e7"
      ; "SUMMARY:Weekly sync"
      ; "DTSTART:19980118T230000Z"
      ; "X-CUSTOM:anything"
      ]
  in
  check string "uid" "e7" t.V.uid

(* ---------------------------------------------------------------- *)

let test_missing_uid () =
  match parse_error [ "DTSTART:19980118T230000Z" ] with
  | Error V.Missing_uid -> ()
  | _ -> fail "expected Missing_uid"

let test_empty_uid () =
  match parse_error [ "UID:"; "DTSTART:19980118T230000Z" ] with
  | Error V.Empty_uid -> ()
  | _ -> fail "expected Empty_uid"

let test_duplicate_uid () =
  match
    parse_error [ "UID:a"; "UID:b"; "DTSTART:19980118T230000Z" ]
  with
  | Error V.Duplicate_uid -> ()
  | _ -> fail "expected Duplicate_uid"

let test_missing_dtstart () =
  match parse_error [ "UID:e1" ] with
  | Error V.Missing_dtstart -> ()
  | _ -> fail "expected Missing_dtstart"

let test_duplicate_dtstart () =
  match
    parse_error
      [ "UID:e1"; "DTSTART:19980118T230000Z"; "DTSTART:19980119T230000Z" ]
  with
  | Error V.Duplicate_dtstart -> ()
  | _ -> fail "expected Duplicate_dtstart"

let test_invalid_dtstart () =
  match parse_error [ "UID:e1"; "DTSTART:not-a-date" ] with
  | Error (V.Invalid_dtstart _) -> ()
  | _ -> fail "expected Invalid_dtstart"

let test_tzid_on_utc_rejected () =
  match
    parse_error [ "UID:e1"; "DTSTART;TZID=UTC:19980118T230000Z" ]
  with
  | Error (V.Invalid_dtstart _) -> ()
  | _ -> fail "expected Invalid_dtstart (TZID on UTC value)"

let test_tzid_on_date_rejected () =
  match
    parse_error [ "UID:e1"; "DTSTART;VALUE=DATE;TZID=Asia/Seoul:19980118" ]
  with
  | Error (V.Invalid_dtstart _) -> ()
  | _ -> fail "expected Invalid_dtstart (TZID on DATE value)"

let test_duplicate_parameters_rejected () =
  let cases =
    [ ( [ "UID:e1"
        ; "DTSTART;VALUE=DATE;VALUE=DATE:19980118"
        ]
      , "DTSTART"
      , "VALUE" )
    ; ( [ "UID:e1"
        ; "DTSTART;TZID=Asia/Seoul;TZID=Asia/Seoul:19980119T020000"
        ]
      , "DTSTART"
      , "TZID" )
    ; ( [ "UID:e1"
        ; "DTSTART:19980118T230000Z"
        ; "RECURRENCE-ID;RANGE=THISANDFUTURE;RANGE=THISANDFUTURE:19980125T230000Z"
        ]
      , "RECURRENCE-ID"
      , "RANGE" )
    ]
  in
  List.iter
    (fun (lines, property, parameter) ->
       match parse_error lines with
       | Error
           (V.Parameter_error
              (V.Duplicate_parameter
                 { property = actual_property; parameter = actual_parameter })) ->
         check string "property" property actual_property;
         check string "parameter" parameter actual_parameter
       | _ -> failf "%s duplicate %s was not rejected" property parameter)
    cases

let test_multi_valued_parameter_rejected () =
  match
    parse_error
      [ "UID:e1"; "DTSTART;VALUE=DATE,DATE-TIME:19980118" ]
  with
  | Error
      (V.Parameter_error
        (V.Multiple_parameter_values
          { property = "DTSTART"; parameter = "VALUE" })) ->
    ()
  | _ -> fail "multi-valued VALUE was not rejected"

let test_recurrence_id_form_mismatch () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART;VALUE=DATE:19980118"
      ; "RECURRENCE-ID:19980125T230000Z"
      ]
  with
  | Error V.Recurrence_id_value_mismatch -> ()
  | _ -> fail "expected Recurrence_id_value_mismatch"

let test_recurrence_id_tzid_mismatch () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART;TZID=Asia/Seoul:19980119T020000"
      ; "RECURRENCE-ID;TZID=America/New_York:19980126T020000"
      ]
  with
  | Error V.Recurrence_id_value_mismatch -> ()
  | _ -> fail "expected Recurrence_id_value_mismatch"

let test_invalid_range () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART:19980118T230000Z"
      ; "RECURRENCE-ID;RANGE=Everything:19980125T230000Z"
      ]
  with
  | Error (V.Invalid_range "Everything") -> ()
  | _ -> fail "expected Invalid_range"

let test_this_and_prior_rejected () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART:19980118T230000Z"
      ; "RECURRENCE-ID;RANGE=THISANDPRIOR:19980125T230000Z"
      ]
  with
  | Error (V.Invalid_range "THISANDPRIOR") -> ()
  | _ -> fail "THISANDPRIOR is not defined by RFC 5545"

let test_duplicate_rrule () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART:19980118T230000Z"
      ; "RRULE:FREQ=DAILY"
      ; "RRULE:FREQ=WEEKLY"
      ]
  with
  | Error V.Duplicate_rrule -> ()
  | _ -> fail "expected Duplicate_rrule"

let test_rrule_error_propagates () =
  match
    parse_error
      [ "UID:e1"; "DTSTART:19980118T230000Z"; "RRULE:FREQ=FORTNIGHTLY" ]
  with
  | Error (V.Rrule_error (R.Invalid_freq "FORTNIGHTLY")) -> ()
  | _ -> fail "expected Rrule_error Invalid_freq"

let test_until_form_mismatch () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART;VALUE=DATE:19980118"
      ; "RRULE:FREQ=DAILY;UNTIL=19980201T000000Z"
      ]
  with
  | Error
      (V.Until_dtstart_mismatch
        { dtstart_form = "date"; until_form = "utc" }) ->
    ()
  | _ -> fail "expected Until_dtstart_mismatch"

let test_local_dtstart_utc_until_mismatch () =
  match
    parse_error
      [ "UID:e1"
      ; "DTSTART:19980119T020000"
      ; "RRULE:FREQ=DAILY;UNTIL=19980131T000000Z"
      ]
  with
  | Error (V.Until_dtstart_mismatch _) -> ()
  | _ -> fail "expected Until_dtstart_mismatch"

let () =
  run "Schedule_ical_vevent"
    [ "valid"
      , [ test_case "minimal utc" `Quick test_minimal_utc
        ; test_case "date dtstart + date until" `Quick
            test_date_dtstart_with_date_until
        ; test_case "tzid dtstart allows utc until" `Quick
            test_tzid_dtstart_allows_utc_until
        ; test_case "local dtstart + local until" `Quick
            test_local_dtstart_with_local_until
        ; test_case "recurrence-id matching form" `Quick
            test_recurrence_id_matching_form
        ; test_case "range thisandfuture" `Quick test_range_this_and_future
        ; test_case "explicit date-time value" `Quick test_explicit_date_time_value
        ; test_case "uid identity exact" `Quick test_uid_identity_is_exact
        ; test_case "tzid identity exact" `Quick test_tzid_identity_is_exact
        ; test_case "other properties ignored" `Quick
            test_ignored_other_properties
        ]
    ; "rejections"
      , [ test_case "missing uid" `Quick test_missing_uid
        ; test_case "empty uid" `Quick test_empty_uid
        ; test_case "duplicate uid" `Quick test_duplicate_uid
        ; test_case "missing dtstart" `Quick test_missing_dtstart
        ; test_case "duplicate dtstart" `Quick test_duplicate_dtstart
        ; test_case "invalid dtstart" `Quick test_invalid_dtstart
        ; test_case "tzid on utc rejected" `Quick test_tzid_on_utc_rejected
        ; test_case "tzid on date rejected" `Quick test_tzid_on_date_rejected
        ; test_case "duplicate parameters rejected" `Quick
            test_duplicate_parameters_rejected
        ; test_case "multi-valued parameter rejected" `Quick
            test_multi_valued_parameter_rejected
        ; test_case "recurrence-id form mismatch" `Quick
            test_recurrence_id_form_mismatch
        ; test_case "recurrence-id tzid mismatch" `Quick
            test_recurrence_id_tzid_mismatch
        ; test_case "invalid range" `Quick test_invalid_range
        ; test_case "thisandprior rejected" `Quick test_this_and_prior_rejected
        ; test_case "duplicate rrule" `Quick test_duplicate_rrule
        ; test_case "rrule error propagates" `Quick
            test_rrule_error_propagates
        ; test_case "until form mismatch" `Quick test_until_form_mismatch
        ; test_case "local dtstart utc until mismatch" `Quick
            test_local_dtstart_utc_until_mismatch
        ]
    ]
