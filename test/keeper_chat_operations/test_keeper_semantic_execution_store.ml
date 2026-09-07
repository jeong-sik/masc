open Alcotest
module Store = Keeper_chat_operation_store
module Execution = Keeper_semantic_execution
module Frame = Keeper_repetition_snapshot
module Scope = Keeper_execution_scope_id
module Chat = Keeper_chat_operation

let store_ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let execution_ok = function Ok value -> value | Error error -> fail (Store.semantic_error_to_string error)
let frame_ok = function Ok value -> value | Error error -> fail (Frame.error_to_string error)
let string_ok = function Ok value -> value | Error detail -> fail detail
let uuid n =
  match Uuidm.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n) with
  | Some id -> id | None -> fail "invalid fixture UUID"
let scope_id n = Scope.autonomous_admission (uuid n)
let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let source ?(retentions = 0) n =
  Execution.source_member ~post_id:(Printf.sprintf "source-%d" n)
    ~admitted_revision:(Int64.of_int n) ~checkpoint_retentions:retentions
    ~source_sha256:(hash (string_of_int n)) |> string_ok
let observation =
  Frame.observation ~tool_name:"Execute"
    ~input_fingerprint:(Some (hash "input")) ~output_fingerprint:(Some (hash "output"))
  |> frame_ok
let observations (execution : Execution.t) =
  Frame.observations execution.frame ~scope:(Execution.scope execution) |> frame_ok
let assert_count label expected execution = check int label expected (List.length (observations execution))
let apply store execution action = Store.semantic_apply store ~expected:execution ~now:20. action |> execution_ok
let created = function
  | Store.Semantic_created execution -> execution
  | Semantic_existing _ -> fail "new identity unexpectedly replayed"
let prepare store n sources =
  Store.semantic_prepare store ~id:(scope_id n) ~sources ~now:10. |> execution_ok |> created
let get store id = match Store.semantic_get store id |> execution_ok with
  | Some execution -> execution | None -> fail "durable execution disappeared"
let running store n sources =
  let prepared = prepare store n sources in
  let ready = apply store prepared Execution.Confirm_sources in
  apply store ready Execution.Begin_execution
let checkpoint () =
  let trace_id = Keeper_id.Trace_id.of_string "semantic-test-trace" |> string_ok in
  match Keeper_checkpoint_ref.create ~trace_id ~turn_count:3 ~canonical_checkpoint_bytes:"checkpoint bytes" with
  | Ok reference -> reference | Error _ -> fail "checkpoint fixture rejected"
let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let with_path f =
  let directory = Filename.temp_dir "keeper-semantic-store-" "" in
  Fun.protect
    ~finally:(fun () -> Store.For_testing.clear_commit_fault (); remove_tree directory)
    (fun () -> f (Filename.concat directory Store.database_file))
let with_open path f =
  let store = Store.open_or_create ~path |> store_ok in
  Fun.protect ~finally:(fun () -> Store.close store |> store_ok) (fun () -> f store)
let with_store f = with_path (fun path -> with_open path (fun store -> f path store))
let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect ~finally:(fun () -> check bool "SQLite connection closed" true (Sqlite3.db_close db))
    (fun () -> f db)
let sql db statement =
  let rc = Sqlite3.exec db statement in
  if rc <> Sqlite3.Rc.OK then fail (Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db)
let rows db query =
  let result = ref [] in
  let rc = Sqlite3.exec db ~cb:(fun values _ -> result := Array.to_list values :: !result) query in
  if rc <> Sqlite3.Rc.OK then fail (Sqlite3.Rc.to_string rc ^ ": " ^ Sqlite3.errmsg db);
  List.rev !result
let scalar db query = match rows db query with
  | [[Some value]] -> value | _ -> fail "expected one SQLite scalar"
let raw_file path = In_channel.with_open_bin path In_channel.input_all
let assert_execution_error = function Error _ -> () | Ok _ -> fail "invalid operation unexpectedly committed"

let test_identity_frame_and_membership_commit_together () =
  with_store (fun path store ->
    let first = prepare store 1 [source 1; source 2] in
    check string "admission starts preparing" "preparing" (Execution.phase_name first.phase);
    assert_count "admission has no invented observations" 0 first;
    check bool "empty frame already names this identity" true
      (Frame.active first.frame = Some (Execution.scope first));
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let restored = get reopened first.id in
      check bool "identity and membership survive reopen" true
        (Execution.to_json first = Execution.to_json restored);
      match Store.semantic_prepare reopened ~id:first.id ~sources:first.sources ~now:99. |> execution_ok with
      | Semantic_existing replay ->
        check bool "re-admission does not create a new lifetime" true (Execution.to_json restored = Execution.to_json replay)
      | Semantic_created _ -> fail "reopen created a replacement execution"))

let test_admission_commit_faults () =
  List.iter (fun fault -> with_store (fun path store ->
    Store.For_testing.fail_next_commit fault;
    assert_execution_error (Store.semantic_prepare store ~id:(scope_id 1) ~sources:[source 1] ~now:10.);
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      match fault, Store.semantic_get reopened (scope_id 1) |> execution_ok with
      | Store.For_testing.Fail_before_commit, None ->
        let fresh = prepare reopened 1 [source 1] in
        assert_count "rolled-back admission starts empty exactly once" 0 fresh
      | Fail_after_commit, Some committed ->
        assert_count "uncertain commit kept initialized frame" 0 committed;
        (match Store.semantic_prepare reopened ~id:(scope_id 1) ~sources:[source 1] ~now:99. |> execution_ok with
         | Semantic_existing replay -> check bool "uncertain admission uses same ID" true (Scope.equal replay.id committed.id)
         | Semantic_created _ -> fail "uncertain admission was duplicated")
      | _ -> fail "commit fault produced a partial or missing admission")))
    Store.For_testing.[Fail_before_commit; Fail_after_commit]

let test_observation_fault_reload_and_stale_cas () =
  List.iter (fun fault -> with_store (fun path store ->
    let before = running store 1 [source 1] in
    Store.For_testing.fail_next_commit fault;
    assert_execution_error (Store.semantic_apply store ~expected:before ~now:21. (Execution.Record_observation observation));
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let restored = get reopened before.id in
      (match fault with
       | Store.For_testing.Fail_before_commit ->
         assert_count "failed commit did not record an observation" 0 restored;
         let committed = apply reopened before (Execution.Record_observation observation) in
         assert_count "retry records one observation" 1 committed
       | Fail_after_commit ->
         assert_count "uncertain write kept the observation" 1 restored;
         (match Store.semantic_apply reopened ~expected:before ~now:22. (Execution.Record_observation observation) with
          | Error (Store.Execution_changed current) -> assert_count "CAS returns already committed evidence" 1 current
          | Error error -> fail (Store.semantic_error_to_string error)
          | Ok _ -> fail "stale retry duplicated an observation"));
      let current = get reopened before.id in
      assert_count "one durable observation after recovery" 1 current;
      match Store.semantic_prepare reopened ~id:before.id ~sources:before.sources ~now:25. |> execution_ok with
      | Semantic_existing replay -> assert_count "same admission does not clear evidence" 1 replay
      | Semantic_created _ -> fail "observation recovery invented Fresh")))
    Store.For_testing.[Fail_before_commit; Fail_after_commit]

let test_suspended_or_recovering_owner_does_not_block_unrelated_work () =
  List.iter (fun suspend -> with_store (fun _path store ->
    let a = running store 1 [source 1] |> fun a -> apply store a (Execution.Record_observation observation) in
    let a = apply store a (if suspend then Execution.Suspend (checkpoint ()) else Execution.Require_reconciliation "waiting for source reconciliation") in
    let b = prepare store 2 [source 2] |> fun b -> apply store b Execution.Confirm_sources in
    let b = apply store b Execution.Begin_execution in
    check string "unrelated B may run while A waits" "running" (Execution.phase_name b.phase);
    assert_count "B does not inherit A repetition" 0 b;
    assert_count "waiting A retains evidence" 1 (get store a.id);
    (match Store.semantic_prepare store ~id:(scope_id 3) ~sources:[source ~retentions:7 1] ~now:22. with
     | Error (Store.Sources_owned [owner]) -> check bool "same source remains owned by A" true (Scope.equal a.id owner)
     | Error error -> fail (Store.semantic_error_to_string error)
     | Ok _ -> fail "waiting A lost source ownership"))) [true; false]

let test_unconfirmed_admission_can_reconcile_without_global_block () =
  with_store (fun _path store ->
    let a = prepare store 1 [source 1] in
    let b = running store 2 [source 2] in
    let a = apply store a (Execution.Require_reconciliation "queue binding did not commit") in
    let _cancelled = apply store a (Execution.Settle Execution.Cancelled) in
    let c = prepare store 3 [source 1] in
    check string "unrelated B never lost its running slot" "running" (Execution.phase_name (get store b.id).phase);
    assert_count "released unstarted source can receive a new admission" 0 c)

let test_only_running_owns_the_slot () =
  with_store (fun _path store ->
    let a = running store 1 [source 1] in
    let b = prepare store 2 [source 2] |> fun b -> apply store b Execution.Confirm_sources in
    (match Store.semantic_apply store ~expected:b ~now:21. Execution.Begin_execution with
     | Error (Store.Execution_slot_busy owner) -> check bool "actual running owner returned" true (Scope.equal owner a.id)
     | Error error -> fail (Store.semantic_error_to_string error)
     | Ok _ -> fail "two executions entered Running");
    let _waiting = apply store a (Execution.Suspend (checkpoint ())) in
    let b = apply store b Execution.Begin_execution in
    check string "suspension releases only the running slot" "running" (Execution.phase_name b.phase))

let test_restart_recovery_preserves_scope_and_allows_other_work () =
  with_store (fun path store ->
    let a = running store 1 [source 1] |> fun a -> apply store a (Execution.Record_observation observation) in
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let _chat_reconciled = Store.settle_running_after_restart reopened ~now:30. |> store_ok in
      let recovered = get reopened a.id in
      (match recovered.phase with Execution.Recovering _ -> () | _ -> fail "interrupted Running was not marked Recovering");
      assert_count "restart preserved observations" 1 recovered;
      check bool "restart preserved execution identity" true (Scope.equal (Execution.scope a) (Execution.scope recovered));
      let b = running reopened 2 [source 2] in
      check string "unrelated work runs after restart" "running" (Execution.phase_name b.phase);
      (match Store.semantic_prepare reopened ~id:(scope_id 3) ~sources:[source 1] ~now:31. with
       | Error (Store.Sources_owned _) -> () | _ -> fail "restart freed A's unresolved source")))

let test_terminal_evidence_immutable_and_new_lifetime_is_fresh () =
  with_store (fun path store ->
    let a = running store 1 [source 1] |> fun a -> apply store a (Execution.Record_observation observation) in
    let terminal = apply store a (Execution.Settle Execution.Completed) in
    assert_execution_error (Store.semantic_apply store ~expected:terminal ~now:22. Execution.Begin_execution);
    let b = prepare store 2 [source 1] in
    assert_count "new lifetime does not inherit completed repetition" 0 b;
    check bool "new lifetime has a different scope" false (Scope.equal (Execution.scope terminal) (Execution.scope b));
    with_db path (fun db ->
      List.iter (fun query ->
        check bool "SQLite terminal guard rejects mutation" false (Sqlite3.exec db query = Sqlite3.Rc.OK))
        [ "UPDATE semantic_executions SET revision=99 WHERE phase='settled'";
          "DELETE FROM semantic_executions WHERE phase='settled'" ]);
    assert_count "terminal evidence remains readable" 1 (get store a.id))

let test_readonly_inventory_includes_every_unsettled_phase () =
  with_store (fun path store ->
    let a = running store 1 [source 1] |> fun a -> apply store a (Execution.Suspend (checkpoint ())) in
    let b = prepare store 2 [source 2] |> fun b -> apply store b (Execution.Require_reconciliation "source uncertain") in
    let c = prepare store 3 [source 3] |> fun c -> apply store c Execution.Confirm_sources in
    let d = running store 4 [source 4] in
    let e = prepare store 5 [source 5] in
    let chat_id = Chat.Operation_id.of_string "queued-chat" |> string_ok in
    let _chat = Store.submit store ~now:5. ~operation_id:chat_id ~source:(`Assoc ["kind", `String "fixture"])
      ~input:(`Assoc ["message", `String "ordinary work"]) |> store_ok in
    Store.close store |> store_ok;
    let before = raw_file path in
    (match Store.inspect_outstanding ~path |> store_ok with
     | Missing_store -> fail "durable journal looked absent"
     | Stored_operations {chat_operations; semantic_executions} ->
       check int "pending direct chat remains visible" 1 (List.length chat_operations);
       check (list string) "all semantic nonterminal phases are visible"
         (List.sort String.compare (List.map (fun (e : Execution.t) -> Yojson.Safe.to_string (Scope.to_json e.id)) [a;b;c;d;e]))
         (List.sort String.compare (List.map (fun (e : Execution.t) -> Yojson.Safe.to_string (Scope.to_json e.id)) semantic_executions)));
    check string "read-only inspection preserves database bytes" before (raw_file path))

let test_corrupt_semantic_frame_refuses_unsafe_inspection () =
  with_store (fun path store ->
    let _a = prepare store 1 [source 1] in
    Store.close store |> store_ok;
    with_db path (fun db -> sql db "UPDATE semantic_executions SET record_json='{' WHERE phase='preparing'");
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with
     | Error _ -> () | Ok _ -> fail "corrupt owned execution was treated as absent");
    check string "corrupt execution evidence is retained" before (raw_file path))

(* Construct an exact v1 journal from the unchanged chat schema, keeping real
   submitted rows/digests. Only v2's added objects and metadata are removed. *)
let make_v1 path =
  let first_id = Chat.Operation_id.of_string "v1-first" |> string_ok in
  let second_id = Chat.Operation_id.of_string "v1-second" |> string_ok in
  with_open path (fun store ->
    List.iter (fun id ->
      let _admitted = Store.submit store ~now:5. ~operation_id:id
        ~source:(`Assoc ["kind", `String "fixture"])
        ~input:(`Assoc ["message", `String "preserve me"]) |> store_ok in ()) [first_id; second_id];
    let _cancelled = Store.cancel_queued store ~now:6. ~operation_id:first_id |> store_ok in
    (* A valid queued edit changes execution_digest but intentionally retains
       admission_digest from the original submission. Migration must accept it. *)
    let _edited = Store.edit_queued store ~operation_id:second_id
      ~input:(`Assoc ["message", `String "legitimate queued edit"]) |> store_ok in ());
  with_db path (fun db ->
    let sequence = scalar db "SELECT next_sequence FROM metadata WHERE singleton=1" in
    sql db "BEGIN IMMEDIATE";
    List.iter (sql db)
      [ "DROP TRIGGER semantic_terminal_update_immutable";
        "DROP TRIGGER semantic_terminal_delete_immutable";
        "DROP INDEX semantic_single_running";
        "DROP TABLE semantic_executions";
        "DROP TABLE metadata";
        "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v1'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT" ];
    sql db ("INSERT INTO metadata VALUES (1, 'masc.keeper_chat_operations.v1', " ^ sequence ^ ")");
    sql db "PRAGMA user_version=1";
    sql db "COMMIT");
  first_id, second_id
let chat_snapshot path = with_db path (fun db -> rows db "SELECT * FROM operations ORDER BY sequence")
let version path = with_db path (fun db -> scalar db "PRAGMA user_version")
let sequence path = with_db path (fun db -> scalar db "SELECT next_sequence FROM metadata WHERE singleton=1")
let semantic_table_count path = with_db path (fun db -> scalar db "SELECT count(*) FROM sqlite_master WHERE name='semantic_executions'")

let test_readonly_v1_does_not_require_migration () =
  with_path (fun path ->
    let _terminal, pending = make_v1 path in
    let before = raw_file path in
    (match Store.inspect_outstanding ~path |> store_ok with
     | Stored_operations {chat_operations=[chat]; semantic_executions=[]} ->
       check string "v1 pending owner is visible" (Chat.Operation_id.to_string pending) (Chat.Operation_id.to_string chat.operation_id)
     | _ -> fail "validated v1 journal was not inspected without migration");
    check string "read-only v1 inspection is byte preserving" before (raw_file path);
    check string "reader leaves version alone" "1" (version path);
    check string "reader creates no semantic table" "0" (semantic_table_count path))

let test_v1_upgrade_preserves_chat_rows_and_sequence () =
  with_path (fun path ->
    let first, second = make_v1 path in
    let before_rows = chat_snapshot path and before_sequence = sequence path in
    with_open path (fun store ->
      check string "upgrade writes current schema version" "2" (version path);
      check bool "all chat row values survive migration" true (before_rows = chat_snapshot path);
      check string "next chat sequence is preserved" before_sequence (sequence path);
      List.iter (fun id -> check bool "old identity remains queryable" true (Option.is_some (Store.get store id |> store_ok))) [first;second];
      let new_id = Chat.Operation_id.of_string "after-upgrade" |> string_ok in
      let admitted = Store.submit store ~now:7. ~operation_id:new_id ~source:(`Assoc []) ~input:(`Assoc []) |> store_ok in
      let operation = match admitted with Accepted op -> op | Existing _ -> fail "new chat unexpectedly existed" in
      check int64 "next chat submission preserves sequence allocation" (Int64.of_string before_sequence) operation.sequence;
      let _semantic = prepare store 1 [source 1] in ()))

let test_v1_upgrade_faults_are_atomic () =
  List.iter (fun fault -> with_path (fun path ->
    let _ids = make_v1 path in
    let before = chat_snapshot path and next = sequence path in
    Store.For_testing.fail_next_commit fault;
    (match Store.open_or_create ~path with
     | Error _ -> ()
     | Ok store -> Store.close store |> store_ok; fail "injected migration failure was hidden");
    check bool "migration failure never loses chat rows" true (before = chat_snapshot path);
    check string "migration failure preserves sequence" next (sequence path);
    (match fault with
     | Store.For_testing.Fail_before_commit ->
       check string "failed migration keeps old version" "1" (version path);
       check string "failed migration leaves no partial new table" "0" (semantic_table_count path)
     | Fail_after_commit ->
       check string "uncertain migration may be durably current" "2" (version path);
       check string "uncertain migration committed complete schema" "1" (semantic_table_count path));
    with_open path (fun _store -> check bool "reopen still retains exact chat rows" true (before = chat_snapshot path))))
    Store.For_testing.[Fail_before_commit; Fail_after_commit]

let test_bad_v1_rows_or_unknown_schema_are_preserved () =
  List.iter (fun mutation -> with_path (fun path ->
    let _ids = make_v1 path in
    with_db path (fun db -> sql db mutation);
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with Error _ -> () | Ok _ -> fail "invalid journal passed readonly inspection");
    (match Store.open_or_create ~path with
     | Error _ -> () | Ok store -> Store.close store |> store_ok; fail "invalid journal was migrated");
    check string "refused journal retains exact bytes" before (raw_file path);
    check string "refusal creates no semantic table" "0" (semantic_table_count path)))
    [ "UPDATE operations SET input_json='{' WHERE state='queued'";
      "UPDATE operations SET input_json='{\"message\":\"tampered valid JSON\"}' WHERE state='queued'";
      "UPDATE operations SET state='running', started_at=-1 WHERE state='queued'";
      "UPDATE operations SET state='failed', started_at=1, completed_at=-1, input_json=NULL, failure_kind='Turn_exception', failure_detail='fixture' WHERE state='queued'";
      "PRAGMA user_version=99" ]

let test_corrupt_database_bytes_are_not_reinitialized () =
  with_path (fun path ->
    let bytes = "not SQLite: preserve this failed evidence\000\255" in
    Out_channel.with_open_bin path (fun out -> output_string out bytes);
    (match Store.open_or_create ~path with
     | Error _ -> () | Ok store -> Store.close store |> store_ok; fail "corrupt file was initialized");
    (match Store.inspect_outstanding ~path with Error _ -> () | Ok _ -> fail "corrupt file looked empty");
    check string "corrupt raw evidence remains intact" bytes (raw_file path))

let test_corrupt_terminal_index_cannot_hide_outstanding_execution () =
  with_store (fun path store ->
    let _pending = prepare store 91 [source 91] in
    with_db path (fun db -> sql db "UPDATE semantic_executions SET phase='settled'");
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with
     | Error (Store.Integrity_error _) -> ()
     | _ -> fail "terminal index hid a pending execution from absence checks");
    (match Store.semantic_outstanding store with
     | Error (Store.Semantic_store_error (Store.Integrity_error _)) -> ()
     | _ -> fail "terminal index hid a pending execution from ownership checks");
    assert_execution_error (Store.semantic_prepare store ~id:(scope_id 92) ~sources:[source 91] ~now:30.);
    check string "incoherent record is retained without a replacement" before (raw_file path))

let project execution observed =
  List.map2 (fun original observed ->
    Execution.source_projection ~original ~observed ~bound_scope:(Execution.scope execution) |> string_ok)
    execution.Execution.sources observed

let reprioritized (original : Execution.source_member) =
  Execution.source_member ~post_id:original.post_id
    ~admitted_revision:(Int64.add original.admitted_revision 10L)
    ~checkpoint_retentions:(original.checkpoint_retentions + 1)
    ~source_sha256:(hash (original.source_sha256 ^ " reprioritized")) |> string_ok

let test_undispatched_recheck_survives_reopen_and_queue_generation () =
  List.iter (fun confirmed -> with_store (fun path store ->
    let original = prepare store 51 [source 51] in
    let original = if confirmed then apply store original Execution.Confirm_sources else original in
    let recovery = apply store original (Execution.Require_reconciliation "queue projection uncertain") in
    let repeat = apply store recovery (Execution.Require_reconciliation "queue projection uncertain") in
    check bool "same failed recheck is an exact no-op" true (Execution.to_json recovery = Execution.to_json repeat);
    let updated = List.map reprioritized original.sources in
    let repaired = apply store repeat (Execution.Recheck_sources (project repeat updated)) in
    check string "recheck restores exact undispatched phase"
      (if confirmed then "ready" else "preparing") (Execution.phase_name repaired.phase);
    check bool "initial membership is retained" true (repaired.sources = original.sources);
    check bool "current membership follows verified queue generation" true (repaired.current_sources = updated);
    check bool "recovery advanced beyond initial revision" true (repaired.revision > original.revision);
    List.iter (fun reserved ->
      (match Store.semantic_prepare store ~id:(scope_id 52) ~sources:reserved ~now:22. with
       | Error (Store.Sources_owned [owner]) -> check bool "both source incarnations remain reserved" true (Scope.equal owner original.id)
       | _ -> fail "rechecked source was admitted under another execution")) [original.sources; updated];
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let restored = get reopened repaired.id in
      check bool "recovered noninitial revision remains readable" true (Execution.to_json repaired = Execution.to_json restored);
      let ready = if confirmed then restored else apply reopened restored Execution.Confirm_sources in
      let executed = apply reopened ready Execution.Begin_execution in
      check bool "undispatched recovery retained scope" true (Scope.equal (Execution.scope original) (Execution.scope executed));
      assert_count "projection recheck does not invent prior effects" 0 executed))) [false; true]

let test_recheck_rejects_foreign_binding_and_original_mutation () =
  with_store (fun _path store ->
    let original = prepare store 61 [source 61] in
    let waiting = apply store original (Execution.Require_reconciliation "source projection failed") in
    let observed = reprioritized (source 61) in
    let wrong_scope = Scope.autonomous_admission (uuid 62) in
    let foreign = Execution.source_projection ~original:(source 61) ~observed ~bound_scope:wrong_scope |> string_ok in
    assert_execution_error (Store.semantic_apply store ~expected:waiting ~now:22. (Execution.Recheck_sources [foreign]));
    let changed_original = Execution.source_projection ~original:observed ~observed ~bound_scope:(Execution.scope waiting) |> string_ok in
    assert_execution_error (Store.semantic_apply store ~expected:waiting ~now:22. (Execution.Recheck_sources [changed_original]));
    assert_execution_error (Store.semantic_apply store ~expected:waiting ~now:22. (Execution.Recheck_sources []));
    check bool "failed recheck preserves recoverable evidence" true
      (Execution.to_json waiting = Execution.to_json (get store waiting.id)))

let test_checkpoint_wait_b_completes_a_resumes_without_pending_sources () =
  with_store (fun path store ->
    let checkpoint = checkpoint () in
    let a = running store 71 [source 71] |> fun a -> apply store a (Execution.Record_observation observation) in
    let a = apply store a (Execution.Suspend checkpoint) in
    let a = apply store a (Execution.Require_reconciliation "checkpoint storage temporarily unreadable") in
    (match a.phase with
     | Execution.Recovering {origin = Execution.Checkpointed saved; _} ->
       check bool "recovery keeps exact checkpoint" true (Keeper_checkpoint_ref.equal saved checkpoint)
     | _ -> fail "checkpoint recovery lost its continuation origin");
    let b = running store 72 [source 72] in
    (match Store.semantic_apply store ~expected:a ~now:22. (Execution.Resume_checkpoint checkpoint) with
     | Error (Store.Execution_slot_busy owner) ->
       check bool "checkpoint resume reports the actual running owner" true (Scope.equal owner b.id)
     | Error error -> fail (Store.semantic_error_to_string error)
     | Ok _ -> fail "checkpoint resume entered another execution's running slot");
    let _completed_b = apply store b (Execution.Settle Execution.Completed) in
    let changed_checkpoint = match Keeper_checkpoint_ref.create ~trace_id:checkpoint.trace_id
      ~turn_count:checkpoint.turn_count ~canonical_checkpoint_bytes:"different bytes same turn" with
      | Ok reference -> reference | Error _ -> fail "changed checkpoint fixture" in
    assert_execution_error (Store.semantic_apply store ~expected:a ~now:23. (Execution.Resume_checkpoint changed_checkpoint));
    assert_execution_error (Store.semantic_apply store ~expected:a ~now:23. Execution.Begin_execution);
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let restored = get reopened a.id in
      (* No source projection is supplied: checkpoint attention may have
         already been ACKed. Only the accepted exact continuation authorizes A. *)
      let resumed = apply reopened restored (Execution.Resume_checkpoint checkpoint) in
      check bool "B completion then A resume keeps the exact scope" true
        (Scope.equal (Execution.scope a) (Execution.scope resumed));
      assert_count "A retains prior repetition across B" 1 resumed;
      let observed = apply reopened resumed (Execution.Record_observation observation) in
      assert_count "new A observation extends the original operation" 2 observed;
      assert_count "completed B retained its independent empty frame" 0 (get reopened b.id)))

let test_interrupted_empty_frame_does_not_authorize_replay () =
  with_store (fun _path store ->
    let a = running store 81 [] in
    let _reconciled = Store.settle_running_after_restart store ~now:25. |> store_ok in
    let interrupted = get store a.id in
    assert_count "interrupted frame is empty but not proof of no effect" 0 interrupted;
    (match interrupted.phase with
     | Execution.Recovering {origin = Execution.Interrupted_execution; _} -> ()
     | _ -> fail "restart lost interrupted execution origin");
    List.iter (fun action -> assert_execution_error
      (Store.semantic_apply store ~expected:interrupted ~now:26. action))
      [ Execution.Begin_execution; Execution.Recheck_sources []; Execution.Resume_checkpoint (checkpoint ()) ];
    let b = running store 82 [] in
    check string "unrelated empty proactive operation can still run" "running" (Execution.phase_name b.phase);
    check bool "failed unsafe recovery leaves A unchanged" true
      (Execution.to_json interrupted = Execution.to_json (get store a.id)))

let direct_id value =
  Chat.Operation_id.of_string value |> string_ok |> Scope.direct_operation

let test_direct_and_auto_same_text_are_distinct_durable_scopes () =
  with_store (fun path store ->
    let text = Uuidm.to_string (uuid 91) in
    let direct = direct_id text and autonomous = scope_id 91 in
    let admit id = Store.semantic_prepare store ~id ~sources:[] ~now:10. |> execution_ok |> created in
    let a = admit direct and b = admit autonomous in
    check bool "producer origins distinguish identical text" false (Scope.equal a.id b.id);
    check bool "each empty frame has only its typed identity" true
      (Frame.scope_ids a.frame = [direct] && Frame.scope_ids b.frame = [autonomous]);
    with_db path (fun db ->
      check string "two distinct canonical scope keys" "2"
        (scalar db "SELECT COUNT(DISTINCT scope_key) FROM semantic_executions"));
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      List.iter (fun expected ->
        let restored = get reopened expected.Execution.id in
        check bool "typed identity and exact frame survive database reopen" true
          (Execution.to_json expected = Execution.to_json restored)) [a;b];
      let a = get reopened direct in
      let malformed = match Execution.to_json a with
        | `Assoc fields -> `Assoc (("id", Scope.to_json autonomous) :: List.remove_assoc "id" fields)
        | _ -> fail "execution JSON object expected" in
      (match Execution.of_json malformed with
       | Error (Execution.Invalid_record _) -> ()
       | _ -> fail "foreign scope frame accepted under same textual identity")))

let test_direct_wait_auto_completes_then_direct_resumes () =
  with_store (fun path store ->
    let original_id = direct_id "direct-parent-awaiting-child" in
    let a = Store.semantic_prepare store ~id:original_id ~sources:[] ~now:10. |> execution_ok |> created in
    let a = apply store a Execution.Confirm_sources |> fun a -> apply store a Execution.Begin_execution in
    let a = apply store a (Execution.Record_observation observation) in
    let checkpoint = checkpoint () in
    let a = apply store a (Execution.Suspend checkpoint) in
    let b = running store 92 [source 92] in
    assert_count "independent Auto starts with its own empty frame" 0 b;
    (match Store.semantic_apply store ~expected:a ~now:21. (Execution.Resume_checkpoint checkpoint) with
     | Error (Store.Execution_slot_busy owner) -> check bool "Direct resume reports running Auto owner" true (Scope.equal owner b.id)
     | _ -> fail "cross-origin running slot was not enforced");
    let _completed = apply store b (Execution.Settle Execution.Completed) in
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let saved = get reopened original_id in
      let resumed = apply reopened saved (Execution.Resume_checkpoint checkpoint) in
      check bool "Direct identity is preserved without a UUID alias" true (Scope.equal resumed.id original_id);
      assert_count "Direct retained its earlier observation across Auto" 1 resumed;
      let observed = apply reopened resumed (Execution.Record_observation observation) in
      assert_count "Direct extends the same frame after resume" 2 observed;
      assert_count "Auto frame was not merged into Direct" 0 (get reopened b.id);
      let next = Store.semantic_prepare reopened ~id:(direct_id "next-direct-request") ~sources:[] ~now:30.
        |> execution_ok |> created in
      assert_count "another Direct request has independent evidence" 0 next))

let test_recheck_cannot_take_another_execution_source_incarnation () =
  with_store (fun _path store ->
    let initial = source 101 in
    let occupied = reprioritized initial in
    let disjoint = reprioritized occupied in
    let a = prepare store 101 [initial] in
    let b = prepare store 102 [occupied] in
    let a_before = Execution.to_json a and b_before = Execution.to_json b in
    (match Store.semantic_apply store ~expected:a ~now:22.
      (Execution.Recheck_sources (project a [occupied])) with
     | Error (Store.Sources_owned [owner]) ->
       check bool "recheck names the exact conflicting owner" true (Scope.equal owner b.id)
     | Error error -> fail (Store.semantic_error_to_string error)
     | Ok _ -> fail "source recheck took another execution's incarnation");
    check bool "conflict leaves A's exact record unchanged" true
      (a_before = Execution.to_json (get store a.id));
    check bool "conflict leaves B's exact record unchanged" true
      (b_before = Execution.to_json (get store b.id));
    let updated = apply store a (Execution.Recheck_sources (project a [disjoint])) in
    check bool "disjoint verified projection still succeeds" true (updated.current_sources = [disjoint]);
    check bool "disjoint update retains A's initial membership" true (updated.sources = [initial]);
    check bool "disjoint update leaves B's record unchanged" true
      (b_before = Execution.to_json (get store b.id)))

let () =
  run "keeper semantic execution store"
    [ "typed identity", [
        test_case "Direct and Auto identical text retain separate durable identities" `Quick test_direct_and_auto_same_text_are_distinct_durable_scopes;
        test_case "Direct waits Auto completes Direct resumes original frame" `Quick test_direct_wait_auto_completes_then_direct_resumes ];
      "durability", [
        test_case "identity frame and sources commit together" `Quick test_identity_frame_and_membership_commit_together;
        test_case "admission failure and uncertain commit reopen by identity" `Quick test_admission_commit_faults;
        test_case "observation recovery never duplicates or clears evidence" `Quick test_observation_fault_reload_and_stale_cas;
        test_case "terminal evidence stays immutable and new lifetime is fresh" `Quick test_terminal_evidence_immutable_and_new_lifetime_is_fresh ];
      "owner isolation", [
        test_case "suspended and recovering A allow unrelated B" `Quick test_suspended_or_recovering_owner_does_not_block_unrelated_work;
        test_case "unconfirmed admission reconciliation does not block B" `Quick test_unconfirmed_admission_can_reconcile_without_global_block;
        test_case "only Running owns the execution slot" `Quick test_only_running_owns_the_slot;
        test_case "startup retains A and releases the running slot" `Quick test_restart_recovery_preserves_scope_and_allows_other_work;
        test_case "readonly inventory includes every unsettled phase" `Quick test_readonly_inventory_includes_every_unsettled_phase;
        test_case "corrupt owned frame refuses unsafe inspection" `Quick test_corrupt_semantic_frame_refuses_unsafe_inspection;
        test_case "terminal index cannot conceal pending evidence" `Quick test_corrupt_terminal_index_cannot_hide_outstanding_execution ];
      "recovery", [
        test_case "source recheck cannot take another execution incarnation" `Quick test_recheck_cannot_take_another_execution_source_incarnation;
        test_case "undispatched recheck survives reopen and reprioritization" `Quick test_undispatched_recheck_survives_reopen_and_queue_generation;
        test_case "recheck rejects foreign scope and changed admission" `Quick test_recheck_rejects_foreign_binding_and_original_mutation;
        test_case "checkpoint A waits B completes then A resumes without queue rows" `Quick test_checkpoint_wait_b_completes_a_resumes_without_pending_sources;
        test_case "empty interrupted frame cannot authorize automatic replay" `Quick test_interrupted_empty_frame_does_not_authorize_replay ];
      "schema", [
        test_case "readonly exact v1 requires no migration" `Quick test_readonly_v1_does_not_require_migration;
        test_case "v1 migration preserves all chat rows and sequence" `Quick test_v1_upgrade_preserves_chat_rows_and_sequence;
        test_case "v1 migration commit faults are atomic" `Quick test_v1_upgrade_faults_are_atomic;
        test_case "bad v1 rows and unknown schemas remain intact" `Quick test_bad_v1_rows_or_unknown_schema_are_preserved;
        test_case "corrupt raw database remains intact" `Quick test_corrupt_database_bytes_are_not_reinitialized ] ]
