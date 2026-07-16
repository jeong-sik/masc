module Operation = Keeper_compaction_operation
module Projection = Keeper_compaction_operation_projection
module Record = Keeper_operation_record
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
let next_source =
  ok
    (Keeper_checkpoint_ref.create
       ~trace_id
       ~generation:1
       ~turn_count:4
       ~canonical_checkpoint_bytes:"next-source")
;;
let id value = ok (Operation.Operation_id.of_string value)
let op1 = id "00000000-0000-4000-8000-000000000001"
let op2 = id "00000000-0000-4000-8000-000000000002"
let attempt = ok (Operation.Attempt_id.of_string "00000000-0000-4000-8000-000000000011")
let request ?producer operation_id =
  Operation.requested ~operation_id ~keeper_name ~source_checkpoint:source
    ~trigger:Compaction_trigger.Manual ~cause ~producer
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
let row start_cursor end_cursor recorded_at event : Record.row =
  { recorded_at
  ; start_cursor = cursor start_cursor
  ; end_cursor = cursor end_cursor
  ; event = Keeper_operation_event.Compaction event
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
  |> Operation.tool_invocation_producer_ref
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
      ~trigger:Compaction_trigger.Manual ~cause ~producer:None
  in
  (match Store.append ~base_path:base ~keeper_name ~recorded_at:4.0 wrong with
   | Error (Store.Event_rejected (Store.Keeper_mismatch _)) -> ()
   | _ -> Alcotest.fail "cross-Keeper request was not rejected");
  Alcotest.(check string) "rejections wrote no bytes" before (Fs_compat.load_file path)
;;
let provider_request operation_id source_checkpoint =
  let source_delivery =
    ok (Operation.event_queue_lease_delivery_ref ~sequence:1L)
  in
  let producer =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint
      ~source_delivery
  in
  Operation.requested
    ~operation_id
    ~keeper_name
    ~source_checkpoint
    ~trigger:(Compaction_trigger.Provider_overflow { limit_tokens = None })
    ~cause
    ~producer:(Some producer)
;;
let test_provider_binding_includes_exact_source () =
  with_base @@ fun base ->
  ignore (append base 1.0 (provider_request op1 source));
  (match
     Store.append
       ~base_path:base
       ~keeper_name
       ~recorded_at:2.0
       (provider_request op2 source)
   with
   | Error
       (Store.Event_rejected
          (Store.Producer_already_bound { existing_operation_id; _ }))
     when Operation.Operation_id.equal existing_operation_id op1 -> ()
   | _ -> Alcotest.fail "same source delivery created a second operation");
  ignore (append base 3.0 (provider_request op2 next_source));
  match Store.replay ~base_path:base ~keeper_name with
  | Ok { operations = first :: [ _ ]; _ } ->
    (match first.snapshot.producer with
     | Some
         (Operation.Provider_overflow
            { source_delivery = Operation.Event_queue_lease 1L; _ }) -> ()
     | Some (Operation.Provider_overflow _)
     | Some (Operation.Tool_invocation _)
     | None ->
       Alcotest.fail "journal replay discarded the exact provider delivery")
  | _ -> Alcotest.fail "advanced source did not create a distinct operation"
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
          "provider binding includes exact source"
          `Quick
          test_provider_binding_includes_exact_source
      ; Alcotest.test_case "malformed history" `Quick test_malformed_history_fails_loud
      ] ]
;;
