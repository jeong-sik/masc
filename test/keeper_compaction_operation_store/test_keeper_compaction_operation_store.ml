module Operation = Keeper_compaction_operation
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
  let producer =
    Operation.provider_overflow_producer_ref
      ~source_checkpoint
      ~source_delivery_identity:"same-delivery"
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
  | Ok { operations = [ _; _ ]; _ } -> ()
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
let write_meta config name =
  let meta =
    ok
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc
           [ "name", `String name
           ; "agent_name", `String (name ^ "-agent")
           ; "trace_id", `String (name ^ "-trace")
           ; "allowed_paths", `List [ `String "*" ]
           ]))
  in
  ok (Masc.Keeper_meta_store.write_meta config meta);
  meta
;;
let save_checkpoint config meta =
  let session_id =
    Keeper_id.Trace_id.to_string
      meta.Masc.Keeper_meta_contract.runtime.trace_id
  in
  let session =
    Masc.Keeper_context_runtime.create_session
      ~session_id
      ~base_dir:(Masc.Keeper_types_profile.session_base_dir config)
  in
  let working =
    Masc.Keeper_context_core.create
      ~eio:false
      ~system_prompt:"test"
      ~max_tokens:1
  in
  let context = Masc.Keeper_context_core.oas_context_of_context working in
  Agent_sdk.Context.set_scoped context Agent_sdk.Context.Session
    "keeper_generation" (`Int meta.runtime.generation);
  let checkpoint =
    Masc.Keeper_context_core.checkpoint_of_context working
    |> fun checkpoint ->
    { checkpoint with
      session_id
    ; agent_name = meta.agent_name
    ; model = "test"
    ; turn_count = 1
    }
  in
  ignore
    (ok
       (Masc.Keeper_checkpoint_store.save_oas_classified
          ~session_dir:session.session_dir
          checkpoint));
  let snapshot =
    ok
      (Masc.Keeper_checkpoint_store.load_oas_exact_snapshot
         ~session_dir:session.session_dir
         ~session_id)
  in
  session.session_dir, session_id, snapshot
;;
let test_manual_request_persists_source_before_journal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base ->
  let config = Masc.Workspace.default_config base in
  ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
  let meta = write_meta config "manual-request" in
  let keeper = ok (Keeper_id.Keeper_name.of_string meta.name) in
  let session_dir, session_id, source = save_checkpoint config meta in
  let source_ref =
    Masc.Keeper_checkpoint_store.exact_snapshot_reference source
  in
  let producer = producer () in
  let created =
    ok
      (Masc.Keeper_compaction_manual_request.request
         ~config
         ~keeper_name:keeper
         ~cause
         ~producer:(Some producer))
  in
  Alcotest.(check bool) "created" true
    (created.status = Masc.Keeper_compaction_manual_request.Created);
  Alcotest.(check bool) "exact source" true
    (Keeper_checkpoint_ref.equal source_ref created.source_checkpoint);
  let journal =
    Store.journal_path ~base_path:config.base_path ~keeper_name:keeper
  in
  let before_retry = Fs_compat.load_file journal in
  Unix.unlink
    (Masc.Keeper_checkpoint_store.oas_checkpoint_path
       ~session_dir
       ~session_id);
  let existing =
    ok
      (Masc.Keeper_compaction_manual_request.request
         ~config
         ~keeper_name:keeper
         ~cause
         ~producer:(Some producer))
  in
  Alcotest.(check bool) "existing" true
    (existing.status = Masc.Keeper_compaction_manual_request.Existing);
  Alcotest.(check bool) "same operation" true
    (Operation.Operation_id.equal created.operation_id existing.operation_id);
  Alcotest.(check string) "retry wrote no bytes" before_retry
    (Fs_compat.load_file journal)
;;
let test_source_failures () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_base @@ fun base ->
  let config = Masc.Workspace.default_config base in
  ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
  let missing = write_meta config "manual-missing" in
  let missing_keeper = ok (Keeper_id.Keeper_name.of_string missing.name) in
  (match
     Masc.Keeper_compaction_manual_request.request
       ~config
       ~keeper_name:missing_keeper
       ~cause
       ~producer:None
   with
   | Error (Masc.Keeper_compaction_manual_request.Source_checkpoint_unavailable _) -> ()
   | _ -> Alcotest.fail "missing checkpoint did not fail explicitly");
  Alcotest.(check bool) "missing checkpoint wrote no journal" false
    (Sys.file_exists
       (Store.journal_path
          ~base_path:config.base_path
          ~keeper_name:missing_keeper));
  let meta = write_meta config "manual-object-failure" in
  let keeper = ok (Keeper_id.Keeper_name.of_string meta.name) in
  let _, _, source = save_checkpoint config meta in
  let reference =
    Masc.Keeper_checkpoint_store.exact_snapshot_reference source
  in
  let object_path =
    Masc.Keeper_compaction_object_store.object_path
      ~base_path:config.base_path
      ~keeper_name:keeper
      ~reference
  in
  Fs_compat.mkdir_p (Filename.dirname object_path);
  Fs_compat.save_file object_path "corrupt\n";
  (match
     Masc.Keeper_compaction_manual_request.request
       ~config
       ~keeper_name:keeper
       ~cause
       ~producer:None
   with
   | Error (Masc.Keeper_compaction_manual_request.Source_object_persist_failed _) -> ()
   | _ -> Alcotest.fail "invalid source object did not fail explicitly");
  Alcotest.(check bool) "object failure wrote no journal" false
    (Sys.file_exists
       (Store.journal_path ~base_path:config.base_path ~keeper_name:keeper))
;;
let () =
  Alcotest.run "keeper compaction operation store"
    [ "journal",
      [ Alcotest.test_case "append replay slice" `Quick test_append_replay_and_slice
      ; Alcotest.test_case "rejections no write" `Quick test_rejections_do_not_write
      ; Alcotest.test_case
          "provider binding includes exact source"
          `Quick
          test_provider_binding_includes_exact_source
      ; Alcotest.test_case "malformed history" `Quick test_malformed_history_fails_loud
      ; Alcotest.test_case "manual source durability" `Quick
          test_manual_request_persists_source_before_journal
      ; Alcotest.test_case "source failures" `Quick test_source_failures
      ] ]
;;
