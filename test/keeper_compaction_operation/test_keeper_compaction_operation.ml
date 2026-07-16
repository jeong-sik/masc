module Operation = Keeper_compaction_operation

let ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture rejected"
let operation_id = ok (Operation.Operation_id.of_string "123e4567-e89b-12d3-a456-426614174000")
let attempt_id = ok (Operation.Attempt_id.of_string "123e4567-e89b-12d3-a456-426614174001")
let keeper_name = ok (Keeper_id.Keeper_name.of_string "keeper-a")
let trace_id = ok (Keeper_id.Trace_id.of_string "trace-a")
let checkpoint bytes turn_count =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id
       ~generation:2
       ~turn_count
       ~canonical_checkpoint_bytes:bytes)
;;
let source = checkpoint "before" 7
let candidate = checkpoint "after" 7
let evidence : Keeper_compaction_evidence.t =
  { selected_runtime_id = Some "compact-runtime"
  ; before_checkpoint_bytes = 100
  ; after_checkpoint_bytes = 50
  ; before_message_count = 10
  ; after_message_count = 4
  ; summarized_message_count = 6
  ; dropped_message_count = 0
  ; before_tool_use_count = 2
  ; after_tool_use_count = 1
  ; before_tool_result_count = 2
  ; after_tool_result_count = 1
  }
;;
let cause = ok (Operation.Cause.of_string "operator request")
let producer =
  let request_id = ok (Mcp_transport_protocol.request_id_of_yojson (`String "req-1")) in
  ok (Tool_invocation_ref.external_mcp ~request_id ~session_id:"session-1")
;;

let test_requested_view () =
  let event =
    Operation.requested
      ~operation_id
      ~keeper_name
      ~source_checkpoint:source
      ~trigger:Compaction_trigger.Manual
      ~cause
      ~producer_invocation:(Some producer)
  in
  Alcotest.(check bool)
    "operation identity"
    true
    (Operation.Operation_id.equal operation_id (Operation.operation_id event));
  match Operation.view event with
  | Operation.Requested request ->
    Alcotest.(check bool)
      "keeper identity"
      true
      (Keeper_id.Keeper_name.equal keeper_name request.keeper_name);
    Alcotest.(check bool)
      "source identity"
      true
      (Keeper_checkpoint_ref.equal source request.source_checkpoint);
    Alcotest.(check bool)
      "producer identity"
      true
      (Option.exists (Tool_invocation_ref.equal producer) request.producer_invocation)
  | _ -> Alcotest.fail "requested event changed shape"
;;

let test_candidate_views () =
  let prepared =
    Operation.candidate_prepared
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
  in
  let reconciled =
    Operation.commit_reconciliation_required
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
      ~reason:Operation.Transaction_outcome_unknown
  in
  let check_candidate = function
    | Operation.Candidate_prepared value
    | Operation.Commit_reconciliation_required (value, _) ->
      Alcotest.(check bool)
        "candidate identity"
        true
        (Keeper_checkpoint_ref.equal candidate value.candidate_checkpoint)
    | _ -> Alcotest.fail "candidate event changed shape"
  in
  check_candidate (Operation.view prepared);
  check_candidate (Operation.view reconciled)
;;

let test_failure_and_reinjection_views () =
  let failure =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = source })
  in
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let reinjected =
    Operation.reinjected
      ~operation_id
      ~adopted_checkpoint:candidate
      ~adopting_turn:turn
  in
  (match Operation.view failure with
   | Operation.Attempt_failed
       (_, Operation.Candidate_not_installed { observed_checkpoint; _ }) ->
     Alcotest.(check bool)
       "observed canonical source"
       true
       (Keeper_checkpoint_ref.equal source observed_checkpoint)
   | _ -> Alcotest.fail "failure event changed shape");
  match Operation.view reinjected with
  | Operation.Reinjected (checkpoint, adopting_turn) ->
    Alcotest.(check bool)
      "adopted checkpoint"
      true
      (Keeper_checkpoint_ref.equal candidate checkpoint);
    Alcotest.(check string)
      "adopting turn"
      "trace-a#8"
      (Ids.Turn_ref.to_string adopting_turn)
  | _ -> Alcotest.fail "reinjected event changed shape"
;;

let () =
  Alcotest.run
    "keeper compaction operation events"
    [ ( "events"
      , [ Alcotest.test_case "requested typed view" `Quick test_requested_view
        ; Alcotest.test_case "candidate typed views" `Quick test_candidate_views
        ; Alcotest.test_case
            "failure and reinjection typed views"
            `Quick
            test_failure_and_reinjection_views
        ] )
    ]
