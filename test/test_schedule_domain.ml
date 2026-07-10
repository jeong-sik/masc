open Alcotest
open Schedule_domain

let human ?display_name id = { id; kind = Human_operator; display_name }
let automated ?display_name id = { id; kind = Automated_actor; display_name }

let payload_json ?(kind = "consumer.note") ?(schema_version = 1) ?body () =
  let body =
    Option.value body
      ~default:(`Assoc [ "text", `String "ship the thing" ])
  in
  `Assoc
    [ "kind", `String kind
    ; "schema_version", `Int schema_version
    ; "body", body
    ]
;;

let request
  ?(risk_class = Workspace_write)
  ?(approval_required = false)
  ?(requested_by = human "requester")
  ?(scheduled_by = human "scheduler")
  ?expires_at
  ?recurrence
  ()
  =
  match
    create_request ~schedule_id:"sched-1" ~requested_by ~scheduled_by
      ~requested_at:100.0 ~due_at:200.0
      ?expires_at ~payload:(payload_json ()) ~risk_class ~approval_required
      ~source:Operator_request ?recurrence ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let grant ?decision ?approved_by ?(scope = Grant_occurrence) request =
  let decision = Option.value ~default:Approve decision in
  let approved_by = Option.value ~default:(human "approver") approved_by in
  create_execution_grant ~grant_id:"grant-1" ~approved_by ~approved_at:150.0
    ~decision ~scope request
;;

let check_status label expected actual =
  check string label (schedule_status_to_string expected) (schedule_status_to_string actual)
;;

let check_error label expected result =
  match result with
  | Ok _ -> fail (label ^ ": expected error")
  | Error actual ->
    check string label (grant_error_to_string expected) (grant_error_to_string actual)
;;

let test_side_effecting_starts_pending () =
  let req = request ~risk_class:Workspace_write () in
  check bool "approval forced" true req.approval_required;
  check_status "status" Pending_approval req.status
;;

let test_read_only_can_start_scheduled () =
  let req = request ~risk_class:Read_only () in
  check bool "approval not required" false req.approval_required;
  check_status "status" Scheduled req.status
;;

let test_payload_requires_object_envelope () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(`String "do later") ~risk_class:Read_only
      ~approval_required:false ~source:Operator_request ()
  with
  | Ok _ -> fail "expected invalid payload"
  | Error msg -> check string "payload error" "payload must be a JSON object" msg
;;

let test_payload_requires_known_envelope_fields () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(`Assoc [ "body", `Assoc [] ]) ~risk_class:Read_only
      ~approval_required:false ~source:Operator_request ()
  with
  | Ok _ -> fail "expected invalid payload"
  | Error msg -> check string "payload error" "missing field: kind" msg
;;

let test_invalid_recurrence_rejected () =
  match
    create_request ~schedule_id:"sched-1" ~requested_by:(human "requester")
      ~scheduled_by:(human "scheduler") ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~risk_class:Read_only
      ~approval_required:false ~source:Operator_request
      ~recurrence:(Interval { interval_sec = 0 })
      ()
  with
  | Ok _ -> fail "expected invalid recurrence"
  | Error msg ->
    check string "recurrence error" "recurrence.interval_sec must be positive" msg
;;

let test_separate_human_approval_accepts () =
  let req = request () in
  let grant = grant req in
  match apply_execution_grant req grant with
  | Error err -> fail (grant_error_to_string err)
  | Ok updated -> check_status "approved schedule status" Scheduled updated.status
;;

let test_reject_grant_marks_rejected () =
  let req = request () in
  let grant = grant ~decision:(Reject "not safe enough") req in
  match apply_execution_grant req grant with
  | Error err -> fail (grant_error_to_string err)
  | Ok updated -> check_status "rejected schedule status" Rejected updated.status
;;

let test_due_grant_keeps_request_due () =
  let due = { (request ()) with status = Due } in
  let grant = grant due in
  match apply_execution_grant due grant with
  | Error err -> fail (grant_error_to_string err)
  | Ok updated -> check_status "due approval stays due" Due updated.status
;;

let test_expired_schedule_blocks_grant () =
  let req = request ~expires_at:149.0 () in
  let grant = grant req in
  check_error "expired approval" Schedule_terminal
    (validate_execution_grant req grant)
;;

let test_requester_cannot_approve () =
  let requested_by = human "same-human" in
  let req = request ~requested_by () in
  let grant = grant ~approved_by:requested_by req in
  check_error "requester approval" Approver_is_requester
    (validate_execution_grant req grant)
;;

let test_scheduler_cannot_approve () =
  let scheduled_by = human "same-human" in
  let req = request ~scheduled_by () in
  let grant = grant ~approved_by:scheduled_by req in
  check_error "scheduler approval" Approver_is_scheduler
    (validate_execution_grant req grant)
;;

let test_automated_actor_cannot_approve_side_effecting () =
  let req = request () in
  let grant = grant ~approved_by:(automated "automation-a") req in
  check_error "automated approval" Approver_not_human
    (validate_execution_grant req grant)
;;

let test_evidence_mismatch_rejected () =
  let req = request () in
  let valid_grant = grant req in
  let bad_evidence = { valid_grant.evidence with due_at = 201.0 } in
  let bad_grant = { valid_grant with evidence = bad_evidence } in
  check_error "evidence due_at" Evidence_due_at_mismatch
    (validate_execution_grant req bad_grant)
;;

let test_terminal_schedule_blocks_grant () =
  let req = { (request ()) with status = Cancelled } in
  let grant = grant req in
  check_error "terminal schedule" Schedule_terminal
    (validate_execution_grant req grant)
;;

let test_standing_scope_requires_recurring_schedule () =
  let req = request () in
  check_error
    "one-shot standing grant"
    Standing_scope_requires_recurring
    (apply_execution_grant req (grant ~scope:Grant_standing req))
;;

let test_mark_due_only_scheduled () =
  let scheduled = request ~risk_class:Read_only () in
  let due = mark_due ~now:201.0 scheduled in
  check_status "scheduled becomes due" Due due.status;
  let pending = request () in
  let unchanged = mark_due ~now:201.0 pending in
  check_status "pending unchanged" Pending_approval unchanged.status
;;

let test_interval_recurrence_next_due () =
  let req =
    request ~risk_class:Read_only
      ~recurrence:(Interval { interval_sec = 60 })
      ()
  in
  check bool "is recurring" true (is_recurring req.recurrence);
  match next_due_after ~now:201.0 req with
  | None -> fail "expected next interval due"
  | Some due_at -> check (float 0.001) "next due" 260.0 due_at
;;

let test_daily_recurrence_next_due_uses_fixed_offset_alias () =
  let req =
    request ~risk_class:Read_only
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
    request ~risk_class:Read_only
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
      ~payload:(payload_json ()) ~risk_class:Read_only
      ~approval_required:false ~source:Operator_request
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
    request ~risk_class:Read_only
      ~recurrence:(Cron { expression = "0 9 * * 1-5"; timezone = "UTC" })
      ()
  in
  check bool "is recurring" true (is_recurring req.recurrence);
  match next_due_after ~now:32400.0 req with
  | None -> fail "expected next cron due"
  | Some due_at -> check (float 0.001) "next weekday 09:00" 118800.0 due_at
;;

let test_cron_recurrence_supports_steps_ranges_and_sunday_alias () =
  let req =
    request ~risk_class:Read_only
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
      ~payload:(payload_json ()) ~risk_class:Read_only
      ~approval_required:false ~source:Operator_request
      ~recurrence:(Cron { expression = "*/0 9 * * 1-5"; timezone = "UTC" })
      ()
  with
  | Ok _ -> fail "expected invalid cron rejection"
  | Error msg ->
    check string "cron error" "recurrence.cron.minute step must be positive" msg
;;

let test_schedule_roundtrip () =
  let req =
    request ~risk_class:Cost_bearing ~approval_required:true
      ~recurrence:(Interval { interval_sec = 300 })
      ()
  in
  match schedule_request_to_yojson req |> schedule_request_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "schedule_id" req.schedule_id decoded.schedule_id;
    check_status "status" req.status decoded.status;
    check string "recurrence" "interval"
      (recurrence_kind_to_string decoded.recurrence);
    check string "payload digest" (payload_digest req.payload)
      (payload_digest decoded.payload)
;;

let test_cron_schedule_roundtrip () =
  let req =
    request ~risk_class:Read_only
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

let test_missing_recurrence_defaults_one_shot () =
  let req = request ~risk_class:Read_only () in
  let json =
    match schedule_request_to_yojson req with
    | `Assoc fields -> `Assoc (List.remove_assoc "recurrence" fields)
    | other -> other
  in
  match schedule_request_of_yojson json with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "recurrence" "one_shot"
      (recurrence_kind_to_string decoded.recurrence)
;;

let test_grant_roundtrip () =
  let req = request () in
  let grant = grant req in
  match execution_grant_to_yojson grant |> execution_grant_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "grant_id" grant.grant_id decoded.grant_id;
    check string "schedule_id" grant.schedule_id decoded.schedule_id;
    check string "payload digest" grant.evidence.payload_digest
      decoded.evidence.payload_digest
;;

let test_grant_scope_codec () =
  let req = request () in
  (match
     grant ~scope:Grant_standing req
     |> execution_grant_to_yojson
     |> execution_grant_of_yojson
   with
   | Error msg -> fail msg
   | Ok decoded ->
     check string "standing scope roundtrip" "standing"
       (grant_scope_to_string decoded.scope));
  (* Grants persisted before the scope field existed were all bound to the
     single due_at in their evidence: absent must decode as occurrence. *)
  (match grant ~scope:Grant_occurrence req |> execution_grant_to_yojson with
   | `Assoc fields ->
     let without_scope =
       `Assoc
         (List.filter
            (fun (key, _) -> key <> "scope" && key <> "revocation")
            fields)
     in
     (match execution_grant_of_yojson without_scope with
      | Error msg -> fail msg
      | Ok decoded ->
        check string "absent scope decodes as occurrence" "occurrence"
          (grant_scope_to_string decoded.scope);
        check bool "absent revocation decodes as active" true
          (Option.is_none decoded.revocation))
   | _ -> fail "grant json is not an object");
  (* A present-but-unknown scope is an explicit decode error, never a
     silent default. *)
  match grant req |> execution_grant_to_yojson with
  | `Assoc fields ->
    let bad_scope =
      `Assoc
        (List.map
           (fun (key, value) ->
             if key = "scope" then key, `String "forever" else key, value)
           fields)
    in
    (match execution_grant_of_yojson bad_scope with
     | Ok _ -> fail "unknown scope must not decode"
     | Error msg ->
       check bool "unknown scope is an explicit error" true
         (String.length msg > 0))
  | _ -> fail "grant json is not an object"
;;

let test_grant_revocation_roundtrip () =
  let req = request ~recurrence:(Interval { interval_sec = 60 }) () in
  let revoked_by = human "revoker" in
  let original =
    { (grant ~scope:Grant_standing req) with
      revocation =
        Some
          { revoked_by
          ; revoked_at = 175.0
          ; reason = Operator_revoked
          }
    }
  in
  match execution_grant_to_yojson original |> execution_grant_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    (match decoded.revocation with
     | None -> fail "revocation disappeared during roundtrip"
     | Some revocation ->
       check string "revoker" revoked_by.id revocation.revoked_by.id;
       check (float 0.001) "revoked_at" 175.0 revocation.revoked_at;
       check string "reason" "operator_revoked"
         (grant_revocation_reason_to_string revocation.reason))
;;

let test_execution_record_roundtrip () =
  let req = request ~risk_class:Read_only () in
  let execution =
    { execution_id = "exec-1"
    ; schedule_id = req.schedule_id
    ; started_at = 201.0
    ; finished_at = Some 202.0
    ; due_at = req.due_at
    ; payload_digest = payload_digest req.payload
    ; status = Execution_succeeded
    ; detail = Some (`Assoc [ "kind", `String "test.done" ])
    ; error = None
    }
  in
  match execution_record_to_yojson execution |> execution_record_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "execution_id" execution.execution_id decoded.execution_id;
    check string "status" "succeeded"
      (execution_status_to_string decoded.status);
    check (option (float 0.001)) "finished_at" execution.finished_at
      decoded.finished_at;
    check string "payload digest" execution.payload_digest
      decoded.payload_digest
;;

let () =
  run "Schedule_domain"
    [
      ( "request",
        [
          test_case "side-effecting starts pending" `Quick
            test_side_effecting_starts_pending;
          test_case "read-only can start scheduled" `Quick
            test_read_only_can_start_scheduled;
          test_case "payload requires object envelope" `Quick
            test_payload_requires_object_envelope;
          test_case "payload requires envelope fields" `Quick
            test_payload_requires_known_envelope_fields;
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
        ] );
      ( "grant",
        [
          test_case "separate human approval accepts" `Quick
            test_separate_human_approval_accepts;
          test_case "reject grant marks rejected" `Quick test_reject_grant_marks_rejected;
          test_case "due grant keeps request due" `Quick
            test_due_grant_keeps_request_due;
          test_case "expired schedule blocks grant" `Quick
            test_expired_schedule_blocks_grant;
          test_case "requester cannot approve" `Quick test_requester_cannot_approve;
          test_case "scheduler cannot approve" `Quick test_scheduler_cannot_approve;
          test_case "automated actor cannot approve side-effecting" `Quick
            test_automated_actor_cannot_approve_side_effecting;
          test_case "evidence mismatch rejected" `Quick test_evidence_mismatch_rejected;
          test_case "terminal schedule blocks grant" `Quick
            test_terminal_schedule_blocks_grant;
          test_case "standing scope requires recurring schedule" `Quick
            test_standing_scope_requires_recurring_schedule;
        ] );
      ( "codec",
        [
          test_case "schedule roundtrip" `Quick test_schedule_roundtrip;
          test_case "cron schedule roundtrip" `Quick test_cron_schedule_roundtrip;
          test_case "recurrence summary" `Quick test_recurrence_summary;
          test_case "missing recurrence defaults one-shot" `Quick
            test_missing_recurrence_defaults_one_shot;
          test_case "grant roundtrip" `Quick test_grant_roundtrip;
          test_case "grant scope codec: roundtrip, absent, unknown" `Quick
            test_grant_scope_codec;
          test_case "grant revocation roundtrip" `Quick
            test_grant_revocation_roundtrip;
          test_case "execution record roundtrip" `Quick
            test_execution_record_roundtrip;
        ] );
    ]
;;
