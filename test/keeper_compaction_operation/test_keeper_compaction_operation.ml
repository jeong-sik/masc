module Operation = Keeper_compaction_operation
module Operation_json = Keeper_compaction_operation_json
module Reducer = Keeper_compaction_operation_reducer

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

let request_event () =
  Operation.requested
    ~operation_id
    ~keeper_name
    ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual
    ~cause
    ~producer_invocation:(Some producer)
;;

let attempt_event () = Operation.attempt_started ~operation_id ~attempt_id

let candidate_event () =
  Operation.candidate_prepared
    ~operation_id
    ~attempt_id
    ~source_checkpoint:source
    ~candidate_checkpoint:candidate
    ~evidence
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

let test_reducer_happy_path () =
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let state =
    ok
      (Reducer.fold
         [ request_event ()
         ; attempt_event ()
         ; candidate_event ()
         ; Operation.compacted
             ~operation_id
             ~attempt_id
             ~source_checkpoint:source
             ~committed_checkpoint:candidate
             ~evidence
         ; Operation.reinjected
             ~operation_id
             ~adopted_checkpoint:candidate
             ~adopting_turn:turn
         ])
  in
  let snapshot = Reducer.snapshot state in
  Alcotest.(check bool) "adopted phase" true (snapshot.phase = Reducer.Adopted);
  Alcotest.(check bool)
    "adopted exact checkpoint"
    true
    (Option.exists
       (Keeper_checkpoint_ref.equal candidate)
       snapshot.adopted_checkpoint)
;;

let test_reducer_confirmed_failure () =
  let state = ok (Reducer.fold [ request_event (); attempt_event (); candidate_event () ]) in
  let wrong =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = candidate })
  in
  (match Reducer.apply (Some state) wrong with
   | Error Reducer.Source_mismatch -> ()
   | Ok _ | Error _ -> Alcotest.fail "third checkpoint was treated as not-installed");
  let confirmed =
    Operation.attempt_failed
      ~operation_id
      ~attempt_id
      ~failure:
        (Operation.Candidate_not_installed
           { cause; observed_checkpoint = source })
  in
  let state = ok (Reducer.apply (Some state) confirmed) in
  Alcotest.(check bool)
    "confirmed non-install returns pending"
    true
    (Reducer.phase state = Reducer.Request_pending);
  match Reducer.apply (Some state) (attempt_event ()) with
  | Error Reducer.Attempt_reused -> ()
  | Ok _ | Error _ -> Alcotest.fail "closed attempt id was reused"
;;

let test_reducer_reconciliation () =
  let state = ok (Reducer.fold [ request_event (); attempt_event (); candidate_event () ]) in
  let event =
    Operation.commit_reconciliation_required
      ~operation_id
      ~attempt_id
      ~source_checkpoint:source
      ~candidate_checkpoint:candidate
      ~evidence
      ~reason:Operation.Commit_durability_unknown
  in
  let state = ok (Reducer.apply (Some state) event) in
  let snapshot = Reducer.snapshot state in
  Alcotest.(check bool)
    "unknown outcome remains reconciliation"
    true
    (snapshot.reconciliation_reason = Some Operation.Commit_durability_unknown)
;;

let test_reducer_invalid_transition () =
  match Reducer.fold [ request_event (); candidate_event () ] with
  | Error (Reducer.Invalid_transition (Some Reducer.Request_pending)) -> ()
  | Ok _ | Error _ -> Alcotest.fail "candidate without attempt was accepted"
;;

let test_canonical_json_projection () =
  let turn = Ids.Turn_ref.make ~trace_id:"trace-a" ~absolute_turn:8 in
  let events =
    [ request_event ()
    ; attempt_event ()
    ; candidate_event ()
    ; Operation.attempt_failed
        ~operation_id
        ~attempt_id
        ~failure:(Operation.Pre_commit_failure cause)
    ; Operation.attempt_failed
        ~operation_id
        ~attempt_id
        ~failure:
          (Operation.Candidate_not_installed
             { cause; observed_checkpoint = source })
    ; Operation.commit_reconciliation_required
        ~operation_id
        ~attempt_id
        ~source_checkpoint:source
        ~candidate_checkpoint:candidate
        ~evidence
        ~reason:Operation.Commit_durability_unknown
    ; Operation.compacted
        ~operation_id
        ~attempt_id
        ~source_checkpoint:source
        ~committed_checkpoint:candidate
        ~evidence
    ; Operation.reinjected
        ~operation_id
        ~adopted_checkpoint:candidate
        ~adopting_turn:turn
    ]
  in
  let kinds =
    List.map
      (fun event ->
         Operation_json.to_json event
         |> Yojson.Safe.Util.member "kind"
         |> Yojson.Safe.Util.to_string)
      events
  in
  Alcotest.(check (list string))
    "closed event labels"
    [ "requested"
    ; "attempt_started"
    ; "candidate_prepared"
    ; "attempt_failed"
    ; "attempt_failed"
    ; "commit_reconciliation_required"
    ; "compacted"
    ; "reinjected"
    ]
    kinds;
  let requested = Operation_json.to_json (List.hd events) in
  Alcotest.(check string)
    "exact producer request id"
    "req-1"
    (requested
     |> Yojson.Safe.Util.member "payload"
     |> Yojson.Safe.Util.member "producer_invocation"
     |> Yojson.Safe.Util.member "request_id"
     |> Yojson.Safe.Util.to_string)
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
        ; Alcotest.test_case "reducer happy path" `Quick test_reducer_happy_path
        ; Alcotest.test_case
            "reducer confirmed failure"
            `Quick
            test_reducer_confirmed_failure
        ; Alcotest.test_case
            "reducer reconciliation"
            `Quick
            test_reducer_reconciliation
        ; Alcotest.test_case
            "reducer invalid transition"
            `Quick
            test_reducer_invalid_transition
        ; Alcotest.test_case
            "canonical JSON projection"
            `Quick
            test_canonical_json_projection
        ] )
    ]
