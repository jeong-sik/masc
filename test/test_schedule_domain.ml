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
  ()
  =
  match
    create_request ~schedule_id:"sched-1" ~requested_by ~scheduled_by
      ~requested_at:100.0 ~due_at:200.0
      ~payload:(payload_json ()) ~risk_class ~approval_required
      ~source:Operator_request ()
  with
  | Ok request -> request
  | Error msg -> fail msg
;;

let grant ?decision ?approved_by request =
  let decision = Option.value ~default:Approve decision in
  let approved_by = Option.value ~default:(human "approver") approved_by in
  create_execution_grant ~grant_id:"grant-1" ~approved_by ~approved_at:150.0
    ~decision request
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

let test_mark_due_only_scheduled () =
  let scheduled = request ~risk_class:Read_only () in
  let due = mark_due ~now:201.0 scheduled in
  check_status "scheduled becomes due" Due due.status;
  let pending = request () in
  let unchanged = mark_due ~now:201.0 pending in
  check_status "pending unchanged" Pending_approval unchanged.status
;;

let test_schedule_roundtrip () =
  let req = request ~risk_class:Cost_bearing ~approval_required:true () in
  match schedule_request_to_yojson req |> schedule_request_of_yojson with
  | Error msg -> fail msg
  | Ok decoded ->
    check string "schedule_id" req.schedule_id decoded.schedule_id;
    check_status "status" req.status decoded.status;
    check string "payload digest" (payload_digest req.payload)
      (payload_digest decoded.payload)
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
          test_case "mark due only affects scheduled" `Quick
            test_mark_due_only_scheduled;
        ] );
      ( "grant",
        [
          test_case "separate human approval accepts" `Quick
            test_separate_human_approval_accepts;
          test_case "reject grant marks rejected" `Quick test_reject_grant_marks_rejected;
          test_case "requester cannot approve" `Quick test_requester_cannot_approve;
          test_case "scheduler cannot approve" `Quick test_scheduler_cannot_approve;
          test_case "automated actor cannot approve side-effecting" `Quick
            test_automated_actor_cannot_approve_side_effecting;
          test_case "evidence mismatch rejected" `Quick test_evidence_mismatch_rejected;
          test_case "terminal schedule blocks grant" `Quick
            test_terminal_schedule_blocks_grant;
        ] );
      ( "codec",
        [
          test_case "schedule roundtrip" `Quick test_schedule_roundtrip;
          test_case "grant roundtrip" `Quick test_grant_roundtrip;
        ] );
    ]
;;
