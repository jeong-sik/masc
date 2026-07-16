module Operation = Keeper_compaction_operation
module Reducer = Keeper_compaction_operation_reducer
module Selector = Keeper_compaction_operation_action_selector
module Store = Keeper_compaction_operation_store

open Selector
let ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture failed"
let operation value = ok (Operation.Operation_id.of_string value)
let op1 = operation "00000000-0000-4000-8000-000000000001"
let op2 = operation "00000000-0000-4000-8000-000000000002"
let op3 = operation "00000000-0000-4000-8000-000000000003"
let attempt =
  ok
    (Operation.Attempt_id.of_string
       "00000000-0000-4000-8000-000000000011")

let keeper = ok (Keeper_id.Keeper_name.of_string "selector-keeper")
let trace = ok (Keeper_id.Trace_id.of_string "selector-trace")
let checkpoint bytes =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id:trace
       ~generation:1
       ~turn_count:4
       ~canonical_checkpoint_bytes:bytes)

let source = checkpoint "source"
let target = checkpoint "candidate"
let cause = ok (Operation.Cause.of_string "explicit request")
let evidence : Keeper_compaction_evidence.t =
  { selected_runtime_id = Some "runtime-a"
  ; before_checkpoint_bytes = 120
  ; after_checkpoint_bytes = 60
  ; before_message_count = 12
  ; after_message_count = 5
  ; summarized_message_count = 7
  ; dropped_message_count = 0
  ; before_tool_use_count = 2
  ; after_tool_use_count = 1
  ; before_tool_result_count = 2
  ; after_tool_result_count = 1
  }

let requested operation_id =
  Operation.requested
    ~operation_id
    ~keeper_name:keeper
    ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual
    ~cause
    ~producer_invocation:None

let prepared operation_id =
  [ Operation.attempt_started ~operation_id ~attempt_id:attempt
  ; Operation.candidate_prepared
      ~operation_id
      ~attempt_id:attempt
      ~source_checkpoint:source
      ~candidate_checkpoint:target
      ~evidence
  ]

let snapshot operation_id events =
  ok (Reducer.fold (requested operation_id :: events)) |> Reducer.snapshot

let entry cursor snapshot : Store.operation_entry =
  { snapshot
  ; requested_at = float_of_int cursor
  ; request_cursor = ok (Store.Cursor.of_int cursor)
  }

let replay operations : Store.replay =
  { operations; end_cursor = ok (Store.Cursor.of_int 1000) }

let select mode operations = Selector.select ~mode (replay operations)
let same_operation expected actual =
  Operation.Operation_id.equal expected actual.operation_id

let same_candidate expected (actual : candidate_context) =
  same_operation expected actual.operation
  && Operation.Attempt_id.equal attempt actual.candidate.attempt_id
  && Keeper_checkpoint_ref.equal source actual.candidate.source_checkpoint
  && Keeper_checkpoint_ref.equal target actual.candidate.candidate_checkpoint
  && actual.candidate.evidence = evidence

let test_fifo_and_terminal_skip () =
  let pending = snapshot op3 [] in
  let operations =
    [ entry 1 { pending with phase = Reducer.Adopted }
    ; entry 2 { pending with phase = Reducer.Failed }
    ; entry 3 { pending with phase = Reducer.Superseded }
    ; entry 4 pending
    ; entry 5 (snapshot op2 [])
    ]
  in
  match select Steady_state operations with
  | Ok (Selected (Start_attempt selected)) ->
    Alcotest.(check bool) "first nonterminal" true
      (same_operation op3 selected);
    Alcotest.(check int) "exact cursor" 4
      (Store.Cursor.to_int selected.request_cursor)
  | Ok _ | Error _ -> Alcotest.fail "FIFO request was not selected"

let test_attempt_modes () =
  let running =
    entry 1
      (snapshot op1
         [ Operation.attempt_started ~operation_id:op1 ~attempt_id:attempt ])
  in
  let operations = [ running; entry 2 (snapshot op2 []) ] in
  (match select Startup_recovery operations with
   | Ok (Selected (Terminalize_interrupted_attempt selected)) ->
     Alcotest.(check bool) "startup operation" true
       (same_operation op1 selected.operation);
     Alcotest.(check bool) "attempt retained" true
       (Operation.Attempt_id.equal attempt selected.attempt_id)
   | Ok _ | Error _ -> Alcotest.fail "startup interruption not terminalized");
  match select Steady_state operations with
  | Ok (In_flight selected) ->
    Alcotest.(check bool) "steady operation" true
      (same_operation op1 selected.operation);
    Alcotest.(check bool) "request retained" true
      (Operation.Cause.equal cause selected.operation.request.cause)
  | Ok _ | Error _ -> Alcotest.fail "in-flight operation was bypassed"

let test_candidate_actions () =
  let prepared_snapshot = snapshot op1 (prepared op1) in
  let reconciliation =
    snapshot op2
      (prepared op2
       @ [ Operation.commit_reconciliation_required
             ~operation_id:op2
             ~attempt_id:attempt
             ~source_checkpoint:source
             ~candidate_checkpoint:target
             ~evidence
             ~reason:Operation.Transaction_outcome_unknown
         ])
  in
  let committed =
    snapshot op3
      (prepared op3
       @ [ Operation.compacted
             ~operation_id:op3
             ~attempt_id:attempt
             ~source_checkpoint:source
             ~committed_checkpoint:target
             ~evidence
         ])
  in
  (match select Steady_state [ entry 1 prepared_snapshot ] with
   | Ok (Selected (Resume_candidate_commit selected)) ->
     Alcotest.(check bool) "prepared exact" true
       (same_candidate op1 selected)
   | Ok _ | Error _ -> Alcotest.fail "prepared action missing");
  (match select Steady_state [ entry 1 reconciliation ] with
   | Ok
       (Selected
          (Reconcile_commit (selected, Operation.Transaction_outcome_unknown)))
     ->
     Alcotest.(check bool) "reconcile exact" true
       (same_candidate op2 selected)
   | Ok _ | Error _ -> Alcotest.fail "reconcile action missing");
  match select Steady_state [ entry 1 committed ] with
  | Ok (Selected (Wake_for_reinjection selected)) ->
    Alcotest.(check bool) "committed exact" true
      (same_candidate op3 selected)
  | Ok _ | Error _ -> Alcotest.fail "reinjection action missing"

let () =
  Alcotest.run "keeper compaction operation action selector"
    [ ( "selection"
      , [ Alcotest.test_case "FIFO and terminal skip" `Quick
            test_fifo_and_terminal_skip
        ; Alcotest.test_case "attempt modes" `Quick test_attempt_modes
        ; Alcotest.test_case "candidate actions" `Quick test_candidate_actions
        ] )
    ]
