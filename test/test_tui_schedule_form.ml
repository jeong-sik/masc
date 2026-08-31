(* The schedule-create form's pure half: field order under each kind, and the
   typed request the submit builds. The send itself is one POST the cancel
   already exercises; what can rot silently is this mapping, so it is the
   part pinned here. *)

open Masc_tui_types

let form ?(kind = Schedule_kind_one_shot) ?(keeper = "edgar")
    ?(message = "check the queue") ?(when_text = "") ?(timezone = "+09:00") ()
    =
  { scf_kind = kind;
    scf_field = Schedule_field_keeper;
    scf_keeper = keeper;
    scf_message = message;
    scf_when = when_text;
    scf_timezone = timezone;
  }

let test_field_order_follows_kind () =
  let next kind field =
    schedule_create_next_field
      { (form ~kind ()) with scf_field = field }
  in
  Alcotest.(check bool) "one-shot ends on when" true
    (next Schedule_kind_one_shot Schedule_field_when = None);
  Alcotest.(check bool) "interval ends on when" true
    (next Schedule_kind_interval Schedule_field_when = None);
  Alcotest.(check bool) "daily continues to timezone" true
    (next Schedule_kind_daily Schedule_field_when
    = Some Schedule_field_timezone);
  Alcotest.(check bool) "cron ends on timezone" true
    (next Schedule_kind_cron Schedule_field_timezone = None)

let test_kind_cycle_covers_all_kinds () =
  let start = Schedule_kind_one_shot in
  let one = schedule_create_kind_next start in
  let two = schedule_create_kind_next one in
  let three = schedule_create_kind_next two in
  let back = schedule_create_kind_next three in
  Alcotest.(check bool) "four steps return to the start" true (back = start);
  Alcotest.(check bool) "the cycle visits distinct kinds" true
    (List.length
       (List.sort_uniq compare [ start; one; two; three ])
    = 4)

let expect_error name f =
  match schedule_create_request_of_form f with
  | Error _ -> ()
  | Ok _ -> Alcotest.failf "%s: expected a rejection" name

let test_blank_required_fields_reject () =
  expect_error "blank keeper" (form ~keeper:"  " ~when_text:"3600" ());
  expect_error "blank message" (form ~message:"" ~when_text:"3600" ());
  expect_error "blank when" (form ())

let test_one_shot_passes_time_text_through () =
  match
    schedule_create_request_of_form
      (form ~when_text:" 2026-09-02T09:00:00+09:00 " ())
  with
  | Error err -> Alcotest.fail err
  | Ok request ->
      Alcotest.(check string) "keeper trimmed" "edgar" request.scr_keeper;
      (match request.scr_spec with
       | Schedule_spec_one_shot { due_at_iso } ->
           (* Trimmed but otherwise untouched: time syntax is the tool's
              contract, not this form's. *)
           Alcotest.(check string) "due_at_iso"
             "2026-09-02T09:00:00+09:00" due_at_iso
       | _ -> Alcotest.fail "expected a one-shot spec")

let test_interval_requires_positive_integer_seconds () =
  expect_error "words are not seconds"
    (form ~kind:Schedule_kind_interval ~when_text:"hourly" ());
  expect_error "zero is not a cadence"
    (form ~kind:Schedule_kind_interval ~when_text:"0" ());
  match
    schedule_create_request_of_form
      (form ~kind:Schedule_kind_interval ~when_text:"3600" ())
  with
  | Ok { scr_spec = Schedule_spec_interval { interval_sec }; _ } ->
      Alcotest.(check int) "seconds" 3600 interval_sec
  | Ok _ -> Alcotest.fail "expected an interval spec"
  | Error err -> Alcotest.fail err

let test_daily_parses_clock_and_keeps_timezone () =
  expect_error "daily wants HH:MM"
    (form ~kind:Schedule_kind_daily ~when_text:"nine" ());
  expect_error "an out-of-range hour rejects"
    (form ~kind:Schedule_kind_daily ~when_text:"24:00" ());
  expect_error "daily without a timezone rejects"
    (form ~kind:Schedule_kind_daily ~when_text:"09:30" ~timezone:" " ());
  match
    schedule_create_request_of_form
      (form ~kind:Schedule_kind_daily ~when_text:"09:30" ())
  with
  | Ok { scr_spec = Schedule_spec_daily { hour; minute; timezone }; _ } ->
      Alcotest.(check int) "hour" 9 hour;
      Alcotest.(check int) "minute" 30 minute;
      Alcotest.(check string) "timezone" "+09:00" timezone
  | Ok _ -> Alcotest.fail "expected a daily spec"
  | Error err -> Alcotest.fail err

let test_cron_passes_expression_through () =
  expect_error "cron without a timezone rejects"
    (form ~kind:Schedule_kind_cron ~when_text:"0 9 * * 1-5" ~timezone:"" ());
  match
    schedule_create_request_of_form
      (form ~kind:Schedule_kind_cron ~when_text:"0 9 * * 1-5" ())
  with
  | Ok { scr_spec = Schedule_spec_cron { cron; timezone }; _ } ->
      (* The expression's validity is the tool's judgment; the form only
         refuses to send it with nowhere to anchor its clock. *)
      Alcotest.(check string) "cron" "0 9 * * 1-5" cron;
      Alcotest.(check string) "timezone" "+09:00" timezone
  | Ok _ -> Alcotest.fail "expected a cron spec"
  | Error err -> Alcotest.fail err

let test_form_rows_follow_the_kind () =
  let rows kind =
    schedule_create_form_rows (Some (form ~kind ~when_text:"x" ()))
  in
  let has_timezone kind =
    List.exists
      (fun row ->
        Astring.String.is_infix ~affix:"timezone" row)
      (rows kind)
  in
  Alcotest.(check bool) "one-shot draws no timezone row" false
    (has_timezone Schedule_kind_one_shot);
  Alcotest.(check bool) "daily draws a timezone row" true
    (has_timezone Schedule_kind_daily);
  Alcotest.(check bool) "cron draws a timezone row" true
    (has_timezone Schedule_kind_cron);
  Alcotest.(check int) "a closed form draws nothing" 0
    (List.length (schedule_create_form_rows None))

let () =
  Alcotest.run "tui schedule create form"
    [ ( "form",
        [ Alcotest.test_case "field order follows kind" `Quick
            test_field_order_follows_kind;
          Alcotest.test_case "kind cycle covers all kinds" `Quick
            test_kind_cycle_covers_all_kinds;
          Alcotest.test_case "blank required fields reject" `Quick
            test_blank_required_fields_reject;
          Alcotest.test_case "one-shot passes time text through" `Quick
            test_one_shot_passes_time_text_through;
          Alcotest.test_case "interval wants positive integer seconds" `Quick
            test_interval_requires_positive_integer_seconds;
          Alcotest.test_case "daily parses the clock and keeps the timezone"
            `Quick test_daily_parses_clock_and_keeps_timezone;
          Alcotest.test_case "cron passes the expression through" `Quick
            test_cron_passes_expression_through;
          Alcotest.test_case "form rows follow the kind" `Quick
            test_form_rows_follow_the_kind;
        ] );
    ]
