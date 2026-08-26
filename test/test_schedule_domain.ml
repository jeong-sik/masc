open Alcotest
open Schedule_domain

let human ?display_name id = { id; kind = Human_operator; display_name }

let payload_json ?(kind = "consumer.note") ?body () =
  let body =
    Option.value body
      ~default:(`Assoc [ "text", `String "ship the thing" ])
  in
  `Assoc
    [ "kind", `String kind
    ; "body", body
    ]
;;

let request
  ?(requested_by = human "requester")
  ?(scheduled_by = human "scheduler")
  ?expires_at
  ?recurrence
  ()
  =
  match
    create_request ~schedule_id:"sched-1" ~requested_by ~scheduled_by
      ~requested_at:100.0 ~due_at:200.0
      ?expires_at ~payload:(payload_json ()) ~source:Operator_request ?recurrence ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let check_status label expected actual =
  check string label (schedule_status_to_string expected) (schedule_status_to_string actual)
;;

let timestamp value =
  match Ptime.of_rfc3339 value with
  | Ok (time, _, _) -> Ptime.to_float_s time
  | Error _ -> fail ("invalid test timestamp: " ^ value)
;;

let test_request_starts_scheduled () =
  let req = request () in
  check_status "status" Scheduled req.status
;;

let test_payload_requires_object_envelope () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(`String "do later") ~source:Operator_request ()
  with
  | Ok _ -> fail "expected invalid payload"
  | Error msg -> check string "payload error" "payload must be a JSON object" msg
;;

let test_payload_requires_known_envelope_fields () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(`Assoc [ "body", `Assoc [] ]) ~source:Operator_request ()
  with
  | Ok _ -> fail "expected invalid payload"
  | Error msg -> check string "payload error" "missing field: kind" msg
;;

let test_payload_rejects_retired_schema_version () =
  let payload =
    match payload_json () with
    | `Assoc fields -> `Assoc (("schema_version", `Int 1) :: fields)
    | other -> other
  in
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload ~source:Operator_request ()
  with
  | Ok _ -> fail "retired payload schema_version was silently accepted"
  | Error msg ->
    check string "retired field error"
      "schedule payload contains unsupported field schema_version"
      msg
;;

let test_invalid_recurrence_rejected () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~source:Operator_request
      ~recurrence:(Interval { interval_sec = 0 })
      ()
  with
  | Ok _ -> fail "expected invalid recurrence"
  | Error msg ->
    check string "recurrence error" "recurrence.interval_sec must be positive" msg
;;

let test_mark_due_only_scheduled () =
  let scheduled = request () in
  let due = mark_due ~now:201.0 scheduled in
  check_status "scheduled becomes due" Due due.status;
  let running = { scheduled with status = Running } in
  let unchanged = mark_due ~now:201.0 running in
  check_status "running unchanged" Running unchanged.status
;;

let test_interval_recurrence_next_due () =
  let req =
    request
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  match next_due_after ~now:201.0 req with
  | None -> fail "expected next interval due"
  | Some due_at -> check (float 0.001) "next due" 260.0 due_at
;;

let test_daily_recurrence_next_due_uses_fixed_offset_alias () =
  let req =
    request
      ~recurrence:
        (Daily { hour = 9; minute = 0; second = 0; timezone = "Asia/Seoul" })
      ()
  in
  match next_due_after ~now:1.0 req with
  | None -> fail "expected next daily due"
  | Some due_at -> check (float 0.001) "next KST 09:00" 86400.0 due_at
;;

let test_daily_recurrence_next_due_accepts_explicit_fixed_offset () =
  let req =
    request
      ~recurrence:
        (Daily { hour = 9; minute = 0; second = 0; timezone = "+09:00" })
      ()
  in
  match next_due_after ~now:1.0 req with
  | None -> fail "expected next daily due"
  | Some due_at -> check (float 0.001) "next +09:00 09:00" 86400.0 due_at
;;

let test_daily_recurrence_rejects_dst_iana_timezone () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~source:Operator_request
      ~recurrence:
        (Daily { hour = 9; minute = 0; second = 0; timezone = "America/New_York" })
      ()
  with
  | Ok _ -> fail "expected DST-aware IANA timezone rejection"
  | Error msg ->
    check string "timezone error"
      "recurrence.timezone must be UTC, Asia/Seoul, KST, or a fixed offset like +09:00; DST-aware IANA zones are not supported"
      msg
;;

let test_cron_recurrence_next_due_weekdays () =
  let req =
    request
      ~recurrence:(Cron { expression = "0 9 * * 1-5"; timezone = "UTC" })
      ()
  in
  match next_due_after ~now:32400.0 req with
  | None -> fail "expected next cron due"
  | Some due_at -> check (float 0.001) "next weekday 09:00" 118800.0 due_at
;;

let test_cron_recurrence_supports_steps_ranges_and_sunday_alias () =
  let req =
    request
      ~recurrence:(Cron { expression = "*/30 9-10 * * 7"; timezone = "UTC" })
      ()
  in
  match next_due_after ~now:259199.0 req with
  | None -> fail "expected next Sunday cron due"
  | Some due_at -> check (float 0.001) "Sunday 09:00" 291600.0 due_at
;;

let test_cron_recurrence_rejects_invalid_expression () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~source:Operator_request
      ~recurrence:(Cron { expression = "*/0 9 * * 1-5"; timezone = "UTC" })
      ()
  with
  | Ok _ -> fail "expected invalid cron rejection"
  | Error msg ->
    check string "cron error" "recurrence.cron.minute step must be positive" msg
;;

let test_cron_recurrence_finds_occurrence_beyond_five_years () =
  let req =
    request
      ~recurrence:(Cron { expression = "0 9 29 2 *"; timezone = "UTC" })
      ()
  in
  let now = timestamp "2096-03-01T00:00:00Z" in
  match next_due_after ~now req with
  | None -> fail "expected the 2104 leap-day occurrence"
  | Some due_at ->
    check (float 0.001) "next leap day has no five-year horizon"
      (timestamp "2104-02-29T09:00:00Z") due_at
;;

let test_cron_recurrence_rejects_impossible_calendar_date () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~source:Operator_request
      ~recurrence:(Cron { expression = "0 9 31 2 *"; timezone = "UTC" })
      ()
  with
  | Ok _ -> fail "expected impossible cron date rejection"
  | Error msg ->
    check string "cron error" "recurrence.cron has no possible calendar date" msg
;;

let test_schedule_roundtrip () =
  let req =
    request
      ~recurrence:(Interval { interval_sec = 300 })
      ()
  in
  match schedule_request_to_yojson req |> schedule_request_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "schedule_id" req.schedule_id decoded.schedule_id;
    check string "schedule instance id" req.schedule_instance_id
      decoded.schedule_instance_id;
    check_status "status" req.status decoded.status;
    check string "recurrence" "interval"
      (recurrence_kind_to_string decoded.recurrence);
    check string "payload digest" (payload_digest req.payload)
      (payload_digest decoded.payload)
;;

let test_cron_schedule_roundtrip () =
  let req =
    request
      ~recurrence:(Cron { expression = "0 9 * * 1-5"; timezone = "Asia/Seoul" })
      ()
  in
  match schedule_request_to_yojson req |> schedule_request_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "recurrence" "cron"
      (recurrence_kind_to_string decoded.recurrence);
    (match decoded.recurrence with
     | Cron { expression; timezone } ->
       check string "expression" "0 9 * * 1-5" expression;
       check string "timezone" "Asia/Seoul" timezone
     | _ -> fail "expected cron recurrence")
;;

let test_recurrence_summary () =
  check string "one-shot summary" "one_shot" (recurrence_summary One_shot);
  check string "interval summary" "every 900s"
    (recurrence_summary (Interval { interval_sec = 900 }));
  check string "daily summary" "daily 09:05:07 Asia/Seoul"
    (recurrence_summary
       (Daily { hour = 9; minute = 5; second = 7; timezone = "Asia/Seoul" }));
  check string "cron summary" "cron 0 9 * * 1-5 UTC"
    (recurrence_summary (Cron { expression = "0 9 * * 1-5"; timezone = "UTC" }))
;;

let test_missing_recurrence_is_rejected () =
  let req = request () in
  let json =
    match schedule_request_to_yojson req with
    | `Assoc fields -> `Assoc (List.remove_assoc "recurrence" fields)
    | other -> other
  in
  match schedule_request_of_yojson json with
  | Error _ -> ()
  | Ok _ -> fail "missing recurrence must be rejected"
;;

let test_wake_record_roundtrip () =
  let req = request () in
  let wake =
    { schedule_instance_id = req.schedule_instance_id
    ; schedule_id = req.schedule_id
    ; started_at = 201.0
    ; finished_at = Some 202.0
    ; due_at = req.due_at
    ; payload_digest = payload_digest req.payload
    ; status = Wake_succeeded
    ; detail = Some (`Assoc [ "kind", `String "test.done" ])
    ; error = None
    }
  in
  match wake_record_to_yojson wake |> wake_record_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "status" "succeeded"
      (wake_status_to_string decoded.status);
    check (option (float 0.001)) "finished_at" wake.finished_at
      decoded.finished_at;
    check string "payload digest" wake.payload_digest
      decoded.payload_digest
;;


(* {1 mark_due transition matrix}

   [mark_due] decided the pass-through case with [| _ -> request], so a new
   schedule_status silently stayed put -- the FSM Sparse Match shape from
   CLAUDE.md. It now enumerates, and these cases pin what each status does
   under the three inputs the guards distinguish. Iterating
   [all_schedule_statuses] means a new status joins the matrix on its own. *)

let with_status status (request : schedule_request) = { request with status }

let mark_due_matrix ~label ~now ~expires_at ~expected =
  List.iter
    (fun status ->
      let before = with_status status (request ?expires_at ()) in
      let after = mark_due ~now before in
      check_status
        (Printf.sprintf "%s: %s" label (schedule_status_to_string status))
        (expected status)
        after.status)
    all_schedule_statuses
;;

(* A matrix over an empty status list would pass by testing nothing. *)
let test_all_statuses_is_populated () =
  check int "every schedule_status is in all_schedule_statuses" 7
    (List.length all_schedule_statuses)
;;

(* Expiry wins over becoming due: now is past both due_at and expires_at. *)
let test_mark_due_expiry_precedes_due () =
  mark_due_matrix ~label:"expired" ~now:300.0 ~expires_at:(Some 150.0)
    ~expected:(function
      | Scheduled | Due -> Expired
      | (Running | Succeeded | Failed | Cancelled | Expired) as s -> s)
;;

(* Past due_at, no expiry: only Scheduled advances. *)
let test_mark_due_advances_scheduled_only () =
  mark_due_matrix ~label:"due" ~now:250.0 ~expires_at:None
    ~expected:(function
      | Scheduled -> Due
      | (Due | Running | Succeeded | Failed | Cancelled | Expired) as s -> s)
;;

(* Before due_at: nothing moves. *)
let test_mark_due_leaves_early_requests_alone () =
  mark_due_matrix ~label:"not yet due" ~now:150.0 ~expires_at:None
    ~expected:(fun s -> s)
;;

(* The record is returned untouched for pass-through statuses. *)
let test_mark_due_preserves_other_fields () =
  let before = with_status Running (request ~expires_at:150.0 ()) in
  let after = mark_due ~now:300.0 before in
  check string "schedule instance id" before.schedule_instance_id
    after.schedule_instance_id;
  check (float 0.0001) "due_at" before.due_at after.due_at
;;

let () =
  run "Schedule_domain"
    [
      ( "request",
        [
          test_case "request starts scheduled" `Quick
            test_request_starts_scheduled;
          test_case "payload requires object envelope" `Quick
            test_payload_requires_object_envelope;
          test_case "payload requires envelope fields" `Quick
            test_payload_requires_known_envelope_fields;
          test_case "payload rejects retired schema_version" `Quick
            test_payload_rejects_retired_schema_version;
          test_case "invalid recurrence rejected" `Quick
            test_invalid_recurrence_rejected;
          test_case "mark due only affects scheduled" `Quick
            test_mark_due_only_scheduled;
          test_case "interval recurrence next due" `Quick
            test_interval_recurrence_next_due;
          test_case "daily recurrence next due uses fixed-offset alias" `Quick
            test_daily_recurrence_next_due_uses_fixed_offset_alias;
          test_case "daily recurrence next due accepts explicit fixed offset" `Quick
            test_daily_recurrence_next_due_accepts_explicit_fixed_offset;
          test_case "daily recurrence rejects DST IANA timezone" `Quick
            test_daily_recurrence_rejects_dst_iana_timezone;
          test_case "cron recurrence next due weekdays" `Quick
            test_cron_recurrence_next_due_weekdays;
          test_case "cron recurrence supports steps ranges and Sunday alias" `Quick
            test_cron_recurrence_supports_steps_ranges_and_sunday_alias;
          test_case "cron recurrence rejects invalid expression" `Quick
            test_cron_recurrence_rejects_invalid_expression;
          test_case "cron recurrence finds occurrence beyond five years" `Quick
            test_cron_recurrence_finds_occurrence_beyond_five_years;
          test_case "cron recurrence rejects impossible calendar date" `Quick
            test_cron_recurrence_rejects_impossible_calendar_date;
        ] );
      ( "mark_due",
        [
          test_case "all_schedule_statuses is populated" `Quick
            test_all_statuses_is_populated;
          test_case "expiry precedes becoming due" `Quick
            test_mark_due_expiry_precedes_due;
          test_case "only Scheduled advances to Due" `Quick
            test_mark_due_advances_scheduled_only;
          test_case "requests before due_at are untouched" `Quick
            test_mark_due_leaves_early_requests_alone;
          test_case "pass-through preserves other fields" `Quick
            test_mark_due_preserves_other_fields;
        ] );
      ( "codec",
        [
          test_case "schedule roundtrip" `Quick test_schedule_roundtrip;
          test_case "cron schedule roundtrip" `Quick test_cron_schedule_roundtrip;
          test_case "recurrence summary" `Quick test_recurrence_summary;
          test_case "missing recurrence is rejected" `Quick
            test_missing_recurrence_is_rejected;
          test_case "wake record roundtrip" `Quick
            test_wake_record_roundtrip;
        ] );
    ]
;;
