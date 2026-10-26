module Observation = Tui_schedule_observation

let replace key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> invalid_arg "fixture must be an object"

let nested key edit row =
  let value = Yojson.Safe.Util.member key row in
  replace key (edit value) row

let identity =
  [ "schedule_instance_id", `String "instance-1"
  ; "schedule_id", `String "review"
  ; "keeper_name", `String "reviewer"
  ; "post_id", `String "occurrence-1"
  ]

let pending () =
  `Assoc
    [ "schedule_instance_id", `String "instance-1"
    ; "schedule_id", `String "review"
    ; "status", `String "succeeded"
    ; "payload_keeper_name", `String "reviewer"
    ; "payload_target", `String "keeper:reviewer"
    ; "last_wake", `Assoc
        [ "schedule_instance_id", `String "instance-1"
        ; "schedule_id", `String "review"
        ; "status", `String "succeeded"
        ; "due_at", `Float 1793002425.
        ; "payload_digest", `String "payload-1"
        ; "detail", `Assoc
            (("kind", `String "masc.keeper_wake.enqueued")
             :: ("stimulus_id", `String "occurrence-1") :: identity)
        ]
    ; "keeper_queue_evidence", `Assoc
        (("projection_status", `String "matched_pending")
         :: ("wake_due_at", `Float 1793002425.)
         :: ("wake_due_at_iso", `String "2026-10-26T08:13:45Z")
         :: ("wake_payload_digest", `String "payload-1")
         :: ("resolved_owner", `String "reviewer")
         :: ("pending_count", `Int 4) :: identity)
    ; "keeper_reaction_evidence", `Assoc
        (("projection_status", `String "matched_stimulus")
         :: ("stimulus_id", `String "occurrence-1")
         :: ("reaction_kind", `String "turn_started")
         :: ("stimulus_seen", `Bool true)
         :: ("turn_started_seen", `Bool false)
         :: ("turn_finished_seen", `Bool false)
         :: ("event_queue_ack_seen", `Bool false)
         :: ("event_queue_cancelled_seen", `Bool false) :: identity)
    ]

let decoded row = match Observation.decode row with
  | Ok value -> value
  | Error why -> Alcotest.fail why

let stage expected row =
  Alcotest.(check bool) "evidence stage" true ((decoded row).stage = expected)

let refused row = match Observation.decode row with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "evidence with another identity was admitted"

let terminal outcome row =
  nested "keeper_queue_evidence"
    (fun queue -> queue
      |> replace "projection_status" (`String ("matched_terminal_" ^ outcome))
      |> replace "terminal_outcome" (`String outcome)
      |> replace "terminal_reason" (`String "producer evidence")) row

let test_dispatch_is_not_execution () =
  let row = pending () in
  stage Observation.Queued row;
  Alcotest.(check (option string)) "previous occurrence clock"
    (Some "2026-10-26T08:13:45Z") (decoded row).due_at_iso;
  (* Changing the declaration to a future interval does not change the
     delivered occurrence, and the total queue count is not its stage. *)
  stage Observation.Queued
    (row |> replace "status" (`String "scheduled")
         |> replace "next_due_at_iso" (`String "2026-10-26T09:00:00Z")
         |> nested "keeper_queue_evidence" (replace "pending_count" (`Int 99)))

let test_turn_boundary_is_not_completion () =
  let started = pending () |> nested "keeper_reaction_evidence"
      (replace "turn_started_seen" (`Bool true)) in
  stage Observation.Turn_started started;
  let ended = started |> nested "keeper_reaction_evidence"
      (replace "turn_finished_seen" (`Bool true)) in
  stage Observation.Turn_ended ended;
  let consumed = ended
    |> nested "keeper_queue_evidence" (replace "projection_status" (`String "not_found"))
    |> nested "keeper_reaction_evidence" (replace "event_queue_ack_seen" (`Bool true)) in
  stage Observation.Consumed consumed;
  stage Observation.Completed (terminal "completed" consumed)

let test_durable_results_and_projection () =
  stage (Observation.Failed (Some "producer evidence")) (terminal "failed" (pending ()));
  stage (Observation.Cancelled (Some "producer evidence")) (terminal "cancelled" (pending ()));
  stage Observation.Settling
    (pending () |> terminal "completed" |> nested "keeper_queue_evidence"
       (replace "projection_status" (`String "terminal_projection_pending")));
  stage Observation.Transferring
    (pending () |> nested "keeper_queue_evidence"
       (replace "projection_status" (`String "transfer_projection_pending")))

let test_another_occurrence_cannot_supply_progress () =
  let row = pending () |> terminal "completed" in
  refused (row |> replace "schedule_instance_id" (`String "instance-2"));
  List.iter (fun status ->
    refused (row |> replace "schedule_instance_id" (`String "instance-2")
      |> nested "last_wake" (replace "status" (`String status)))) ["running"; "failed"];
  refused (row |> replace "payload_keeper_name" (`String "another-keeper"));
  refused (row |> replace "payload_target" (`String "keeper:another-keeper"));
  refused (row |> nested "keeper_queue_evidence" (replace "post_id" (`String "occurrence-2")));
  refused (row |> nested "keeper_queue_evidence" (replace "wake_due_at" (`Float 1793002725.)));
  refused (row |> nested "keeper_queue_evidence" (replace "wake_payload_digest" (`String "payload-2")));
  refused (row |> nested "keeper_reaction_evidence" (replace "stimulus_id" (`String "occurrence-2")));
  refused (row |> nested "keeper_queue_evidence" (replace "terminal_outcome" (`String "failed")))

let test_unavailable_is_not_a_negative () =
  let unknown row = match (decoded row).stage with
    | Observation.Unknown _ -> ()
    | Observation.No_occurrence | Dispatching | Dispatch_failed _ | Queued
    | Queued_at _ | Missing | Turn_started | Turn_ended | Consumed | Completed | Failed _ | Cancelled _
    | Settling | Transferring -> Alcotest.fail "unavailable evidence became confirmed progress" in
  unknown (pending () |> nested "keeper_queue_evidence" (replace "projection_status" (`String "read_error")));
  unknown (pending () |> nested "keeper_reaction_evidence" (replace "projection_status" (`String "quarantined")));
  unknown (pending () |> nested "keeper_queue_evidence" (replace "projection_status" (`String "future_value")));
  unknown (pending () |> nested "keeper_reaction_evidence" (replace "event_queue_ack_seen" (`Bool true)));
  stage Observation.Queued (pending () |> replace "keeper_reaction_evidence" `Null)

let test_terminal_contradiction_cannot_become_completed () =
  let row = pending () |> terminal "completed"
    |> nested "keeper_reaction_evidence"
         (replace "projection_status" (`String "conflicting_terminal_evidence")) in
  let result = (decoded row).stage in
  Alcotest.(check bool) "contradiction is unconfirmed" true
    (match result with
     | Observation.Unknown _ -> true
     | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
     | Turn_started | Turn_ended | Consumed | Completed | Failed _ | Cancelled _
     | Settling | Transferring -> false)

let test_cross_source_terminal_disagreement () =
  let cancelled_reaction = pending () |> nested "keeper_reaction_evidence"
    (fun reaction -> reaction
      |> replace "projection_status" (`String "matched_terminal_cancelled")
      |> replace "event_queue_cancelled_seen" (`Bool true)) in
  List.iter (fun outcome ->
    let result = decoded (terminal outcome cancelled_reaction) in
    Alcotest.(check bool) "terminal disagreement stays unconfirmed" true
      (match result.stage with
       | Observation.Unknown _ -> true
       | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing | Turn_started
       | Turn_ended | Consumed | Completed | Failed _ | Cancelled _ | Settling | Transferring -> false))
    ["completed"; "failed"];
  let consumed = pending () |> nested "keeper_reaction_evidence"
    (replace "event_queue_ack_seen" (`Bool true)) in
  Alcotest.(check bool) "ack does not hide cancellation conflict" false
    ((decoded (terminal "cancelled" consumed)).stage = Observation.Cancelled (Some "producer evidence"));
  stage (Observation.Failed (Some "producer evidence")) (terminal "failed" consumed)

let test_queue_absence_is_not_pending_delivery () =
  let row = pending () |> nested "keeper_queue_evidence"
      (replace "projection_status" (`String "not_found")) in
  stage Observation.Missing row

let test_transferred_owner_ack_is_not_recipient_completion () =
  let transferred = pending ()
    |> nested "keeper_queue_evidence" (replace "resolved_owner" (`String "recipient"))
    |> nested "keeper_reaction_evidence"
      (fun reaction -> reaction
        |> replace "projection_status" (`String "matched_consumed_ack")
        |> replace "event_queue_ack_seen" (`Bool true)) in
  stage (Observation.Queued_at "recipient") transferred;
  stage (Observation.Cancelled (Some "producer evidence")) (terminal "cancelled" transferred)

let test_cancelled_declaration_does_not_settle_retained_work () =
  let retained = pending ()
    |> replace "status" (`String "cancelled")
    |> nested "keeper_queue_evidence"
      (replace "projection_status" (`String "retained_terminal_wake")) in
  stage Observation.Queued retained;
  let transferred = retained
    |> nested "keeper_queue_evidence" (replace "resolved_owner" (`String "recipient"))
    |> nested "keeper_reaction_evidence"
      (replace "event_queue_ack_seen" (`Bool true)) in
  stage (Observation.Queued_at "recipient") transferred;
  Alcotest.(check bool) "retained work still needs observation" true
    (Observation.needs_attention (decoded transferred).stage)

let test_missing_stimulus_receipt_is_unconfirmed () =
  let unrecognized value = pending ()
    |> nested "last_wake" (nested "detail" (replace "stimulus_id" value))
    |> nested "keeper_queue_evidence"
      (replace "projection_status" (`String "unrecognized_receipt"))
    |> replace "keeper_reaction_evidence"
      (`Assoc (("projection_status", `String "missing_stimulus_id") :: identity)) in
  let row = unrecognized `Null in
  let unknown row = match (decoded row).stage with
    | Observation.Unknown _ -> ()
    | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
    | Turn_started | Turn_ended | Consumed | Completed | Failed _ | Cancelled _
    | Settling | Transferring -> Alcotest.fail "missing identity became confirmed progress" in
  unknown row;
  unknown (row |> nested "last_wake" (nested "detail"
    (function `Assoc fields -> `Assoc (List.remove_assoc "stimulus_id" fields)
     | _ -> assert false)));
  refused (row |> replace "payload_target" (`String "keeper:another"));
  refused (row |> replace "schedule_instance_id" (`String "another-instance"));
  refused (row |> nested "keeper_queue_evidence"
    (replace "projection_status" (`String "matched_pending")));
  refused (row |> nested "keeper_reaction_evidence"
    (replace "turn_started_seen" (`Bool true)));
  refused (row |> nested "keeper_reaction_evidence"
    (replace "stimulus_id" (`String "other-stimulus")));
  refused (row |> nested "keeper_reaction_evidence"
    (replace "post_id" (`String "other-occurrence")));
  refused (unrecognized (`Int 1))

let test_dispatch_failure_retains_reason () =
  stage (Observation.Dispatch_failed (Some "queue write failed"))
    (pending () |> nested "last_wake"
       (fun wake -> wake |> replace "status" (`String "failed")
         |> replace "error" (`String "queue write failed")));
  stage Observation.No_occurrence (pending () |> replace "last_wake" `Null)

let test_malformed_evidence_is_refused () =
  refused (pending () |> nested "last_wake" (replace "due_at" `Null)
    |> nested "keeper_queue_evidence" (replace "wake_due_at" `Null));
  refused (pending () |> nested "keeper_queue_evidence" (replace "wake_due_at" (`Float nan)));
  stage Observation.Queued
    (pending () |> nested "keeper_queue_evidence" (replace "wake_due_at" (`Int 1793002425)));
  refused (pending () |> nested "keeper_reaction_evidence" (replace "turn_started_seen" (`String "true")));
  refused (pending () |> nested "keeper_queue_evidence"
    (function `Assoc fields -> `Assoc (("post_id", `String "occurrence-1") :: fields) | _ -> assert false))

let () = Alcotest.run "schedule occurrence observation"
  [ "delivery and execution",
      [ Alcotest.test_case "one-shot delivery and interval clocks" `Quick test_dispatch_is_not_execution
      ; Alcotest.test_case "turn boundaries require durable result" `Quick test_turn_boundary_is_not_completion
      ; Alcotest.test_case "durable outcomes and unsettled projection" `Quick test_durable_results_and_projection
      ; Alcotest.test_case "exact occurrence isolation" `Quick test_another_occurrence_cannot_supply_progress
      ; Alcotest.test_case "unavailable and contradictory observations" `Quick test_unavailable_is_not_a_negative
      ; Alcotest.test_case "terminal contradiction remains unconfirmed" `Quick test_terminal_contradiction_cannot_become_completed
      ; Alcotest.test_case "cross-source terminal disagreement" `Quick test_cross_source_terminal_disagreement
      ; Alcotest.test_case "exact queue absence is not pending" `Quick test_queue_absence_is_not_pending_delivery
      ; Alcotest.test_case "transfer ACK belongs to previous owner" `Quick test_transferred_owner_ack_is_not_recipient_completion
      ; Alcotest.test_case "cancelled definition retains pending work" `Quick test_cancelled_declaration_does_not_settle_retained_work
      ; Alcotest.test_case "missing stimulus remains unconfirmed" `Quick test_missing_stimulus_receipt_is_unconfirmed
      ; Alcotest.test_case "dispatch failure and absent occurrence" `Quick test_dispatch_failure_retains_reason
      ; Alcotest.test_case "malformed wire evidence" `Quick test_malformed_evidence_is_refused
      ] ]
