module Operation = Keeper_compaction_operation
module Projection = Keeper_compaction_operation_projection
module Record = Keeper_operation_record
module Selector = Keeper_compaction_operation_action_selector
module Store = Keeper_compaction_operation_store
let ok = function Ok value -> value | Error _ -> Alcotest.fail "fixture failed"
let keeper_name = ok (Keeper_id.Keeper_name.of_string "store-keeper")
let trace_id = ok (Keeper_id.Trace_id.of_string "store-trace")
let cause = ok (Operation.Cause.of_string "manual compaction")
let source =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id
       ~generation:1
       ~turn_count:3
       ~canonical_checkpoint_bytes:"source")
;;
let id value = ok (Operation.Operation_id.of_string value)
let op1 = id "00000000-0000-4000-8000-000000000001"
let op2 = id "00000000-0000-4000-8000-000000000002"
let attempt = ok (Operation.Attempt_id.of_string "00000000-0000-4000-8000-000000000011")
let preserved =
  ok
    (Keeper_compaction_evidence.preserved
       ~selected_runtime_id:"compact-runtime"
       ~checkpoint_bytes:6
       ~message_count:1
       ~tool_use_count:0
       ~tool_result_count:0)
;;
let request ?producer operation_id =
  Operation.requested ~operation_id ~keeper_name ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual ~cause ~producer_invocation:producer
;;
let rec remove path =
  if Sys.file_exists path then if Sys.is_directory path
    then (Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
          Unix.rmdir path)
    else Unix.unlink path
;;
let with_base f =
  let base = Filename.temp_dir "operation_store_" "" in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)
;;
let append base time event =
  match Store.append ~base_path:base ~keeper_name ~recorded_at:time event with
  | Ok row -> row
  | Error _ -> Alcotest.fail "valid append failed"
;;
let cursor value = ok (Record.Cursor.of_int value)
let row start_cursor end_cursor recorded_at event : Operation.event Record.row =
  { recorded_at
  ; start_cursor = cursor start_cursor
  ; end_cursor = cursor end_cursor
  ; event
  }
;;
let test_incremental_projection_matches_replay () =
  let rows =
    [ row 0 10 1.0 (request op2)
    ; row 10 20 2.0 (request op1)
    ; row 20 30 3.0 (Operation.attempt_started ~operation_id:op2 ~attempt_id:attempt)
    ]
  in
  let replayed = ok (Projection.replay ~keeper_name rows) in
  let incremented =
    List.fold_left
      (fun state entry -> ok (Projection.apply state entry))
      (Projection.empty ~keeper_name)
      rows
  in
  Alcotest.(check bool) "same ordered entries" true
    (Projection.operations replayed = Projection.operations incremented);
  Alcotest.(check int) "same end cursor" 30
    (Record.Cursor.to_int (Projection.end_cursor incremented));
  match Projection.apply incremented (List.hd rows) with
  | Error (Projection.Cursor_mismatch { expected; actual }) ->
    Alcotest.(check int) "expected current end" 30 (Record.Cursor.to_int expected);
    Alcotest.(check int) "stale row start" 0 (Record.Cursor.to_int actual)
  | _ -> Alcotest.fail "stale row was not rejected explicitly"
;;
let test_append_replay_and_slice () =
  with_base @@ fun base ->
  let first = append base 1.0 (request op2) in
  let second = append base 2.0 (request op1) in
  let last = append base 3.0 (Operation.attempt_started ~operation_id:op2 ~attempt_id:attempt) in
  (match Store.replay ~base_path:base ~keeper_name with
   | Ok { operations = [ a; b ]; _ } ->
     Alcotest.(check bool) "request-cursor FIFO" true
       (Operation.Operation_id.equal a.snapshot.operation_id op2
        && Operation.Operation_id.equal b.snapshot.operation_id op1
        && a.snapshot.phase = Keeper_compaction_operation_reducer.Attempt_in_progress
        && Store.Cursor.to_int a.request_cursor = Store.Cursor.to_int first.end_cursor)
   | _ -> Alcotest.fail "valid history did not replay");
  match Store.read_slice ~base_path:base ~keeper_name ~from:second.end_cursor with
  | Ok { rows = [ row ]; end_cursor } ->
    Alcotest.(check int) "exact suffix end"
      (Store.Cursor.to_int last.end_cursor) (Store.Cursor.to_int end_cursor);
    Alcotest.(check (float 0.0)) "last timestamp" 3.0 row.recorded_at
  | _ -> Alcotest.fail "cursor slice was not exact"
;;
let producer () =
  let request_id = ok (Mcp_transport_protocol.request_id_of_yojson (`Int 7)) in
  ok (Tool_invocation_ref.external_mcp ~request_id ~session_id:"store-session")
;;
let test_rejections_do_not_write () =
  with_base @@ fun base ->
  let producer = producer () in
  ignore (append base 1.0 (request ~producer op1));
  let path = Store.journal_path ~base_path:base ~keeper_name in
  let before = Fs_compat.load_file path in
  (match Store.append ~base_path:base ~keeper_name ~recorded_at:2.0 (request ~producer op2) with
   | Error (Store.Event_rejected (Store.Producer_already_bound { existing_operation_id; _ }))
     when Operation.Operation_id.equal existing_operation_id op1 -> ()
   | _ -> Alcotest.fail "producer retry was not bound to its original operation");
  (match Store.append ~base_path:base ~keeper_name ~recorded_at:3.0 (request ~producer op1) with
   | Error (Store.Event_rejected (Store.Transition_rejected _)) -> ()
   | _ -> Alcotest.fail "invalid transition was not rejected");
  let other = ok (Keeper_id.Keeper_name.of_string "other-keeper") in
  let wrong =
    Operation.requested ~operation_id:op2 ~keeper_name:other ~source_checkpoint:source
      ~trigger:Compaction_trigger.Manual ~cause ~producer_invocation:None
  in
  (match Store.append ~base_path:base ~keeper_name ~recorded_at:4.0 wrong with
   | Error (Store.Event_rejected (Store.Keeper_mismatch _)) -> ()
   | _ -> Alcotest.fail "cross-Keeper request was not rejected");
  Alcotest.(check string) "rejections wrote no bytes" before (Fs_compat.load_file path)
;;
let test_no_compaction_decision_is_durable () =
  with_base @@ fun base ->
  ignore (append base 1.0 (request op1));
  ignore (append base 2.0 (Operation.attempt_started ~operation_id:op1 ~attempt_id:attempt));
  let path = Store.journal_path ~base_path:base ~keeper_name in
  let before = Fs_compat.load_file path in
  let decision source_checkpoint =
    Operation.no_compaction
      ~operation_id:op1
      ~attempt_id:attempt
      ~source_checkpoint
      ~evidence:preserved
  in
  (match Store.append ~base_path:base ~keeper_name ~recorded_at:3.0 (decision next_source) with
   | Error
       (Store.Event_rejected
          (Store.Transition_rejected Keeper_compaction_operation_reducer.Source_mismatch))
     -> ()
   | _ -> Alcotest.fail "different source decision was accepted");
  Alcotest.(check string) "rejected decision wrote no bytes" before (Fs_compat.load_file path);
  ignore (append base 4.0 (decision source));
  match Store.replay ~base_path:base ~keeper_name with
  | Ok ({ operations = [ entry ]; _ } as replay)
    when entry.snapshot.phase
         = Keeper_compaction_operation_reducer.No_compaction_decided
         && entry.snapshot.preserved_evidence = Some preserved ->
    (match Selector.select ~mode:Selector.Startup_recovery replay with
     | Ok Selector.Idle -> ()
     | Ok _ | Error _ -> Alcotest.fail "durable decision restarted LLM work")
  | Ok _ | Error _ -> Alcotest.fail "durable decision did not replay exactly"
;;
let test_malformed_history_fails_loud () =
  with_base @@ fun base ->
  let path = Store.journal_path ~base_path:base ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun output -> output_string output "not-json\n");
  (match Store.replay ~base_path:base ~keeper_name with
   | Error (Store.Invalid_history (Store.Invalid_record _)) -> ()
   | _ -> Alcotest.fail "malformed history did not fail replay");
  match Store.append ~base_path:base ~keeper_name ~recorded_at:1.0 (request op1) with
  | Error (Store.Existing_history_invalid _) ->
    Alcotest.(check string) "malformed bytes unchanged" "not-json\n" (Fs_compat.load_file path)
  | _ -> Alcotest.fail "append accepted malformed history"
;;
let () =
  Alcotest.run "keeper compaction operation store"
    [ "journal",
      [ Alcotest.test_case
          "pure incremental replay"
          `Quick
          test_incremental_projection_matches_replay
      ; Alcotest.test_case "append replay slice" `Quick test_append_replay_and_slice
      ; Alcotest.test_case "rejections no write" `Quick test_rejections_do_not_write
      ; Alcotest.test_case
          "no-compaction decision is durable"
          `Quick
          test_no_compaction_decision_is_durable
      ; Alcotest.test_case "malformed history" `Quick test_malformed_history_fails_loud
      ] ]
;;
