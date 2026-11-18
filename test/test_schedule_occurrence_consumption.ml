(* #36054: the reading masc_schedule_get and the dashboard both take from a
   Keeper's reaction ledger, decided from the typed receipt and the typed
   ledger evidence. *)

open Alcotest
open Masc
module C = Schedule_occurrence_consumption
module R = Schedule_dispatch_receipt

let evidence
  ?(stimulus_seen = true)
  ?(turn_started_seen = false)
  ?turn_finished
  ?(event_queue_ack_seen = false)
  ?(event_queue_cancelled_seen = false)
  ()
  : Keeper_reaction_ledger.event_queue_reaction_evidence
  =
  { keeper_name = "keeper-a"
  ; stimulus_id = "stimulus-1"
  ; stimulus_seen
  ; turn_started_seen
  ; turn_finished
  ; event_queue_ack_seen
  ; event_queue_cancelled_seen
  ; stimulus_recorded_at = None
  ; turn_started_recorded_at = None
  ; turn_finished_recorded_at = None
  ; event_queue_ack_recorded_at = None
  ; event_queue_cancelled_recorded_at = None
  ; latest_recorded_at = None
  ; matched_record_count = 1
  ; quarantined_record_count = 0
  }
;;

let reading =
  testable
    (fun fmt value -> Format.pp_print_string fmt (C.reaction_reading_to_string value))
    ( = )
;;

let keeper_wake_receipt ?(stimulus_id = Some "stimulus-1") () =
  R.dispatch_receipt_to_yojson
    (R.Keeper_wake_enqueued
       { keeper_name = "keeper-a"
       ; schedule_instance_id = "instance-1"
       ; schedule_id = "sched-1"
       ; urgency = "normal"
       ; post_id = "stimulus-1"
       ; queue = R.keeper_event_queue_label
       ; stimulus = "schedule_due"
       ; stimulus_id
       ; reaction_ledger_status = Some R.Keeper_wake_reaction_ledger_recorded
       ; result_delivery_policy = R.Keeper_wake_result_delivery_none
       ; occurrence_status = R.Keeper_wake_awaiting_ack
       ; activation_outcome = R.Keeper_wake_activation_signaled
       })
;;

let wake detail : Schedule_domain.wake_record =
  { schedule_instance_id = "instance-1"
  ; schedule_id = "sched-1"
  ; attempt_identity = Schedule_domain.Unidentified
  ; settlement_kind = Some Schedule_domain.Accepted
  ; started_at = 201.0
  ; finished_at = Some 201.5
  ; due_at = 200.0
  ; payload_digest = "digest"
  ; status = Schedule_domain.Wake_succeeded
  ; detail
  ; error = None
  }
;;

let unread ~keeper_name:_ ~stimulus_id:_ = fail "the ledger must not be read"

let test_reading_order () =
  let case label expected value =
    check reading label expected (C.reaction_reading_of_evidence value)
  in
  case "ACK and cancellation conflict" C.Conflicting_terminal_evidence
    (evidence ~event_queue_ack_seen:true ~event_queue_cancelled_seen:true ());
  case "cancellation" C.Terminal_cancelled
    (evidence ~turn_finished:Keeper_reaction_ledger.Turn_disposition.Completed ~event_queue_cancelled_seen:true ());
  case "ACK outranks the turn rows" C.Consumed_ack
    (evidence ~turn_started_seen:true ~turn_finished:Keeper_reaction_ledger.Turn_disposition.Completed
       ~event_queue_ack_seen:true ());
  case "finished outranks started" C.Turn_finished
    (evidence ~turn_started_seen:true ~turn_finished:Keeper_reaction_ledger.Turn_disposition.Completed ());
  case "started" C.Turn_started (evidence ~turn_started_seen:true ());
  case "stimulus only" C.Stimulus_seen (evidence ());
  case "nothing recorded" C.No_reaction_recorded (evidence ~stimulus_seen:false ())
;;

let test_awaiting_ack_receipt_reads_the_ack () =
  let asked = ref [] in
  let read_evidence ~keeper_name ~stimulus_id =
    asked := (keeper_name, stimulus_id) :: !asked;
    Ok
      (Keeper_reaction_ledger.Evidence_complete
         (evidence ~turn_finished:Keeper_reaction_ledger.Turn_disposition.Completed ~event_queue_ack_seen:true ()))
  in
  (match C.of_receipt ~read_evidence (wake (Some (keeper_wake_receipt ()))) with
   | C.Reaction_observed { occurrence; reading = got; _ } ->
     check reading "the ledger ACK, not the receipt's awaiting_ack" C.Consumed_ack got;
     check string "occurrence keeper" "keeper-a" occurrence.keeper_name;
     check string "occurrence stimulus" "stimulus-1" occurrence.stimulus_id
   | C.No_dispatch_receipt | C.Unrecognized_receipt _ | C.Receipt_is_the_record
   | C.Missing_stimulus_id _ | C.Reaction_read_failed _ | C.Reaction_quarantined _ ->
     fail "a decoded keeper wake receipt must read its ledger");
  check (list (pair string string)) "one exact read" [ "keeper-a", "stimulus-1" ] !asked
;;

let test_receipts_without_a_ledger_reading () =
  let check_case label expected detail =
    check bool label true (C.of_receipt ~read_evidence:unread (wake detail) = expected)
  in
  check_case "no receipt" C.No_dispatch_receipt None;
  check_case "lane action receipt is its own record" C.Receipt_is_the_record
    (Some
       (R.dispatch_receipt_to_yojson
          (R.Lane_act_handed_over
             { installation_id = "install-1"
             ; instance_id = "lane-1"
             ; request_id = "request-1"
             ; schedule_instance_id = "instance-1"
             ; schedule_id = "sched-1"
             })));
  check_case "no stimulus identity"
    (C.Missing_stimulus_id { keeper_name = "keeper-a" })
    (Some (keeper_wake_receipt ~stimulus_id:None ()));
  match C.of_receipt ~read_evidence:unread (wake (Some (`String "not a receipt"))) with
  | C.Unrecognized_receipt _ -> ()
  | C.No_dispatch_receipt | C.Receipt_is_the_record | C.Missing_stimulus_id _
  | C.Reaction_read_failed _ | C.Reaction_observed _ | C.Reaction_quarantined _ ->
    fail "a malformed receipt must stay unrecognized"
;;

let test_read_failure_is_not_a_reading () =
  let read_evidence ~keeper_name:_ ~stimulus_id:_ =
    Error Keeper_reaction_ledger.Evidence_invalid_stimulus_id
  in
  match C.of_receipt ~read_evidence (wake (Some (keeper_wake_receipt ()))) with
  | C.Reaction_read_failed { error = Keeper_reaction_ledger.Evidence_invalid_stimulus_id; _ }
    -> ()
  | C.Reaction_read_failed { error = Keeper_reaction_ledger.Evidence_read_error _; _ }
  | C.No_dispatch_receipt | C.Unrecognized_receipt _ | C.Receipt_is_the_record
  | C.Missing_stimulus_id _ | C.Reaction_observed _ | C.Reaction_quarantined _ ->
    fail "the ledger error must stay the reading"
;;

let () =
  run "schedule_occurrence_consumption"
    [ ( "reading"
      , [ test_case "ledger evidence order" `Quick test_reading_order
        ; test_case "an awaiting_ack receipt reads the later ACK" `Quick
            test_awaiting_ack_receipt_reads_the_ack
        ; test_case "receipts with no ledger reading" `Quick
            test_receipts_without_a_ledger_reading
        ; test_case "a ledger read failure stays an error" `Quick
            test_read_failure_is_not_a_reading
        ] )
    ]
;;
