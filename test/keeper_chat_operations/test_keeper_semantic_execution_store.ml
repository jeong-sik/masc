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
let observations (execution : Execution.t) =
  Frame.observations execution.frame ~scope:(Execution.scope execution) |> frame_ok
let assert_count label expected execution = check int label expected (List.length (observations execution))
let created = function
  | Store.Semantic_created execution -> execution
  | Semantic_existing _ -> fail "new identity unexpectedly replayed"
let fixture_input = `Assoc ["kind", `String "test_turn"; "message", `String "continue the admitted task"]
let prepare store n sources =
  Store.semantic_prepare ~input:fixture_input store ~id:(scope_id n) ~sources ~now:10. |> execution_ok |> created
let get store id = match Store.semantic_get store id |> execution_ok with
  | Some execution -> execution | None -> fail "durable execution disappeared"
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
let operation_id name = Chat.Operation_id.of_string name |> string_ok
let submit store ~now name input =
  ignore (Store.submit store ~now ~operation_id:(operation_id name)
    ~source:(`Assoc ["kind", `String "direct"]) ~input |> store_ok)
let claim store ~now = match Store.claim_next store ~now |> store_ok with
  | Some operation -> operation | None -> fail "no direct operation was claimable"
let defer_checkpoint store ~now (operation : Chat.t) reference =
  Store.defer_direct_checkpoint store ~now ~operation_id:operation.operation_id
    ~execution_digest:operation.execution_digest ~checkpoint:(Execution.Agent_core reference) |> store_ok
let resume_checkpoint store ~now (operation : Chat.t) reference =
  Store.resume_direct_checkpoint store ~now ~operation_id:operation.operation_id
    ~observed:(Execution.Agent_core reference) |> store_ok
let direct_scope (operation : Chat.t) = Scope.direct_operation operation.operation_id

let test_identity_frame_and_membership_commit_together () =
  with_store (fun path store ->
    let first = prepare store 1 [source 1; source 2] in
    check string "admission starts preparing" "preparing" (Execution.phase_name first.phase);
    assert_count "admission has no invented observations" 0 first;
    check bool "empty frame already names this identity" true
      (Frame.active first.frame = Some (Execution.scope first));
    (match Store.semantic_prepare ~input:fixture_input store ~id:(scope_id 3) ~sources:[source 2] ~now:11. with
     | Error (Store.Sources_owned [owner]) -> check bool "an outstanding admission keeps its sources" true (Scope.equal owner first.id)
     | Error error -> fail (Store.semantic_error_to_string error)
     | Ok _ -> fail "a source was admitted under two executions");
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let restored = get reopened first.id in
      check bool "identity and membership survive reopen" true
        (Execution.to_json first = Execution.to_json restored);
      match Store.semantic_prepare ~input:fixture_input reopened ~id:first.id ~sources:first.sources ~now:99. |> execution_ok with
      | Semantic_existing replay ->
        check bool "re-admission does not create a new lifetime" true (Execution.to_json restored = Execution.to_json replay)
      | Semantic_created _ -> fail "reopen created a replacement execution"))

let test_admission_commit_faults () =
  List.iter (fun fault -> with_store (fun path store ->
    Store.For_testing.fail_next_commit fault;
    assert_execution_error (Store.semantic_prepare ~input:fixture_input store ~id:(scope_id 1) ~sources:[source 1] ~now:10.);
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      match fault, Store.semantic_get reopened (scope_id 1) |> execution_ok with
      | Store.For_testing.Fail_before_commit, None ->
        let fresh = prepare reopened 1 [source 1] in
        assert_count "rolled-back admission starts empty exactly once" 0 fresh
      | Fail_after_commit, Some committed ->
        assert_count "uncertain commit kept initialized frame" 0 committed;
        (match Store.semantic_prepare ~input:fixture_input reopened ~id:(scope_id 1) ~sources:[source 1] ~now:99. |> execution_ok with
         | Semantic_existing replay -> check bool "uncertain admission uses same ID" true (Scope.equal replay.id committed.id)
         | Semantic_created _ -> fail "uncertain admission was duplicated")
      | _ -> fail "commit fault produced a partial or missing admission")))
    Store.For_testing.[Fail_before_commit; Fail_after_commit]

let test_restart_interrupted_execution_releases_the_running_slot () =
  with_store (fun path store ->
    let input = `Assoc ["message", `String "resume the checkpointed work"] in
    let cp = checkpoint () in
    submit store ~now:1. "interrupted" input;
    let a = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. a cp);
    let a = claim store ~now:4. in
    resume_checkpoint store ~now:5. a cp;
    let running = get store (direct_scope a) in
    check string "resumed continuation holds the running slot" "running" (Execution.phase_name running.phase);
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let _failed = Store.settle_running_after_restart reopened ~now:30. |> store_ok in
      let recovered = get reopened running.id in
      (match recovered.phase with
       | Execution.Recovering {origin = Execution.Interrupted_execution; _} -> ()
       | _ -> fail "interrupted Running was not marked Recovering");
      check bool "restart preserved execution identity" true (Scope.equal (Execution.scope running) (Execution.scope recovered));
      submit reopened ~now:31. "after-restart" input;
      let b = claim reopened ~now:32. in
      ignore (defer_checkpoint reopened ~now:33. b cp);
      let b = claim reopened ~now:34. in
      resume_checkpoint reopened ~now:35. b cp;
      check string "unrelated work runs after restart" "running"
        (Execution.phase_name (get reopened (direct_scope b)).phase)))

let test_terminal_record_is_immutable () =
  with_store (fun path store ->
    submit store ~now:1. "terminal" (`Assoc ["message", `String "finish later"]);
    let claimed = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. claimed (checkpoint ()));
    let _cancelled = Store.cancel_queued store ~now:4. ~operation_id:claimed.operation_id |> store_ok in
    let terminal = get store (direct_scope claimed) in
    check bool "cancellation settled the continuation" true (Execution.is_terminal terminal);
    with_db path (fun db ->
      List.iter (fun query ->
        check bool "SQLite terminal guard rejects mutation" false (Sqlite3.exec db query = Sqlite3.Rc.OK))
        [ "UPDATE semantic_executions SET revision=99 WHERE phase='settled'";
          "DELETE FROM semantic_executions WHERE phase='settled'" ]);
    check bool "terminal record remains readable" true
      (Execution.to_json terminal = Execution.to_json (get store terminal.id)))

(* The Gate wait and binding records no longer carry a session scope: the
   encoder writes none, and a record that still names one is refused whole. *)
let test_gate_record_with_a_session_scope_is_refused () =
  with_store (fun _path store ->
    submit store ~now:1. "gated" (`Assoc ["message", `String "direct work"]);
    let gated = claim store ~now:2. in
    let obligation = Execution.gate_obligation ~approval_id:"approval" ~tool_name:"tool_execute"
      ~input_hash:(hash "tool input") |> string_ok in
    let waiting = Execution.gate_wait ~checkpoint:(checkpoint ()) ~obligations:[obligation] |> string_ok in
    ignore (Store.defer_direct_gate store ~now:3. ~operation_id:gated.operation_id
      ~execution_digest:gated.execution_digest ~waiting |> store_ok);
    let json = Execution.to_json (get store (direct_scope gated)) in
    let names_scope json =
      let text = Yojson.Safe.to_string json and needle = "session_scope" in
      let rec at i = i + String.length needle <= String.length text
        && (String.sub text i (String.length needle) = needle || at (i + 1)) in
      at 0 in
    check bool "the written record names no session scope" false (names_scope json);
    (match Execution.of_json json with
     | Ok _ -> ()
     | Error error -> fail (Execution.error_to_string error));
    let rec with_scope = function
      | `Assoc fields when List.mem_assoc "obligations" fields ->
        `Assoc (("session_scope", `List []) :: List.map (fun (key, value) -> key, with_scope value) fields)
      | `Assoc fields -> `Assoc (List.map (fun (key, value) -> key, with_scope value) fields)
      | `List items -> `List (List.map with_scope items)
      | other -> other in
    let old_shape = with_scope json in
    check bool "the fixture really names a session scope" true (names_scope old_shape);
    check bool "a record that names a session scope is refused" true
      (Result.is_error (Execution.of_json old_shape)))

let test_readonly_inventory_includes_every_unsettled_phase () =
  with_store (fun path store ->
    let input = `Assoc ["message", `String "direct work"] in
    List.iter (fun name -> submit store ~now:1. name input) ["gated"; "cooling"; "first"; "second"];
    let gated = claim store ~now:2. in
    let obligation = Execution.gate_obligation ~approval_id:"approval" ~tool_name:"tool_execute"
      ~input_hash:(hash "tool input") |> string_ok in
    let waiting = Execution.gate_wait ~checkpoint:(checkpoint ()) ~obligations:[obligation] |> string_ok in
    ignore (Store.defer_direct_gate store ~now:3. ~operation_id:gated.operation_id
      ~execution_digest:gated.execution_digest ~waiting |> store_ok);
    let cooling = claim store ~now:4. in
    let retry = Execution.runtime_retry ~not_before:(Some 1_000.) ~checkpoint:(checkpoint ())
      ~assignment_id:"assignment" ~failed_runtime_id:"failed" ~next_runtime_id:"next"
      ~later_runtime_ids:[] |> string_ok in
    ignore (Store.defer_direct_runtime_retry store ~now:5. ~operation_id:cooling.operation_id
      ~execution_digest:cooling.execution_digest ~continuation:retry |> store_ok);
    let first = claim store ~now:6. in
    ignore (defer_checkpoint store ~now:7. first (checkpoint ()));
    let second = claim store ~now:8. in
    ignore (defer_checkpoint store ~now:9. second (checkpoint ()));
    let first = claim store ~now:10. in
    resume_checkpoint store ~now:11. first (checkpoint ());
    let prepared = prepare store 5 [source 5] in
    let phases = List.map (fun id -> Execution.phase_name (get store id).phase)
      [direct_scope gated; direct_scope cooling; direct_scope first; direct_scope second; prepared.id] in
    check (list string) "fixture covers every phase production leaves unsettled"
      ["recovering"; "recovering"; "running"; "suspended"; "preparing"] phases;
    submit store ~now:12. "queued-chat" (`Assoc ["message", `String "ordinary work"]);
    Store.close store |> store_ok;
    let before = raw_file path in
    (match Store.inspect_outstanding ~path |> store_ok with
     | Missing_store -> fail "durable journal looked absent"
     | Stored_operations {chat_operations; semantic_executions; input_checkpoints = _; input_history = _} ->
       check int "every unfinished direct chat remains visible" 5 (List.length chat_operations);
       check (list string) "all semantic nonterminal phases are visible"
         (List.sort String.compare (List.map (fun id -> Yojson.Safe.to_string (Scope.to_json id))
            [direct_scope gated; direct_scope cooling; direct_scope first; direct_scope second; prepared.id]))
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

let convert_fixture_to_exact_v2 path = with_db path (fun db ->
  let sequence = scalar db "SELECT next_sequence FROM metadata WHERE singleton=1" in
  sql db "BEGIN IMMEDIATE";
  sql db "DROP TABLE input_checkpoints";
  sql db "DROP TABLE input_history";
  sql db "DROP TABLE metadata";
  sql db "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v2'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT";
  sql db ("INSERT INTO metadata VALUES (1, 'masc.keeper_chat_operations.v2', " ^ sequence ^ ")");
  sql db "PRAGMA user_version=2";
  sql db "COMMIT")

let test_offline_copy_preserves_evidence_and_prior_uncertainty () = with_path (fun source_path ->
  with_open source_path (fun store ->
    let input = `Assoc ["message",`String "original input"] in
    submit store ~now:1. "success" input;
    let success = claim store ~now:2. in
    ignore (Store.succeed_running store ~now:3. ~operation_id:success.operation_id ~outcome_ref:"original-receipt" |> store_ok);
    submit store ~now:4. "failure" input;
    let failure = claim store ~now:5. in
    ignore (Store.fail_running store ~now:6. ~operation_id:failure.operation_id
      ~kind:Chat.Interrupted_by_restart ~detail:"original failure" ~outcome_ref:None |> store_ok);
    submit store ~now:7. "cancelled" input;
    ignore (Store.cancel_queued store ~now:8. ~operation_id:(operation_id "cancelled") |> store_ok);
    submit store ~now:9. "batch-a" input;
    submit store ~now:9. "batch-b" input;
    let batch _ _ = Ok (Some {Store.members=[operation_id "batch-a";operation_id "batch-b"];
      input=(`Assoc ["message",`String "frozen combined input"])}) in
    ignore (Store.claim_next ~batch store ~now:10. |> store_ok);
    submit store ~now:11. "queued" input;
    ignore (prepare store 900 [source 900]));
  convert_fixture_to_exact_v2 source_path;
  let before = raw_file source_path in
  let destination_path = Filename.concat (Filename.dirname source_path) "prepared-copy.sqlite3" in
  let source_db = Sqlite3.db_open ~mode:`READONLY source_path in
  Fun.protect ~finally:(fun () -> check bool "source closed" true (Sqlite3.db_close source_db)) @@ fun () ->
  with_db destination_path (fun destination ->
    let copied = Store.Offline.prepare_v2_copy ~source:source_db ~destination |> store_ok in
    check int "every operation copied without restart settlement" 6 copied.operation_count;
    check int "semantic original copied" 1 copied.semantic_count;
    check int "frozen batch membership copied" 2 copied.batch_member_count;
    List.iter (fun query -> check bool "original cells unchanged" true
      (rows source_db query = rows destination query))
      ["SELECT * FROM operations ORDER BY sequence";
       "SELECT * FROM semantic_executions ORDER BY scope_key";
       "SELECT * FROM operation_batch_members ORDER BY operation_id";
       "SELECT next_sequence FROM metadata"];
    check string "destination preserves unknown prior input" "prior_unavailable"
      (scalar destination "SELECT basis FROM input_history");
    check string "source stays v2" "masc.keeper_chat_operations.v2"
      (scalar source_db "SELECT schema FROM metadata"));
  check string "read-only source retains exact bytes" before (raw_file source_path);
  let destination = Store.open_existing ~path:destination_path |> store_ok in
  Fun.protect ~finally:(fun () -> Store.close destination |> store_ok) @@ fun () ->
  let omitted = Keeper_id.Trace_id.of_string "trace-missing-from-old-rows" |> string_ok in
  check bool "omitted trace did not become unobserved" true
    ((Store.input_checkpoint destination ~trace_id:omitted |> store_ok) = Store.Prior_input_unavailable))

let test_offline_copy_refuses_nonempty_destination_and_corrupt_source () = with_path (fun source_path ->
  with_open source_path (fun store -> submit store ~now:1. "original" (`Assoc []));
  convert_fixture_to_exact_v2 source_path;
  let before = raw_file source_path in
  with_db source_path (fun source_db ->
    let destination = Sqlite3.db_open ":memory:" in
    Fun.protect ~finally:(fun () -> check bool "destination closed" true (Sqlite3.db_close destination)) @@ fun () ->
    sql destination "CREATE TABLE original_evidence(value TEXT)";
    sql destination "INSERT INTO original_evidence VALUES ('keep')";
    assert_execution_error (Store.Offline.prepare_v2_copy ~source:source_db ~destination);
    check string "occupied destination not overwritten" "keep" (scalar destination "SELECT value FROM original_evidence"));
  check string "nonempty destination refusal preserves source" before (raw_file source_path);
  with_db source_path (fun db -> sql db "UPDATE operations SET input_json='{' WHERE state='queued'");
  let corrupt_before = raw_file source_path in
  with_db source_path (fun source_db ->
    let destination = Sqlite3.db_open ":memory:" in
    Fun.protect ~finally:(fun () -> check bool "destination closed" true (Sqlite3.db_close destination)) @@ fun () ->
    assert_execution_error (Store.Offline.prepare_v2_copy ~source:source_db ~destination);
    check string "no destination schema created for corrupt input" "0"
      (scalar destination "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"));
  check string "corrupt source is preserved" corrupt_before (raw_file source_path))

let test_offline_copy_refuses_reused_sequence () =
  List.iter (fun next_sequence -> with_path (fun source_path ->
    with_open source_path (fun store ->
      submit store ~now:1. "first" (`Assoc []);
      submit store ~now:2. "second" (`Assoc []));
    convert_fixture_to_exact_v2 source_path;
    with_db source_path (fun db -> sql db
      (Printf.sprintf "UPDATE metadata SET next_sequence=%d" next_sequence));
    let before = raw_file source_path in
    with_db source_path (fun source_db ->
      let destination = Sqlite3.db_open ":memory:" in
      Fun.protect ~finally:(fun () -> check bool "destination closed" true (Sqlite3.db_close destination)) @@ fun () ->
      (match Store.Offline.prepare_v2_copy ~source:source_db ~destination with
       | Error (Store.Integrity_error _) -> ()
       | Error error -> fail (Store.error_to_string error)
       | Ok _ -> fail "a reused operation sequence was prepared for admission");
      check string "invalid sequence is refused before copying" "0"
        (scalar destination "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"));
    check string "sequence corruption remains original evidence" before (raw_file source_path))) [0;1]

let test_offline_copy_commit_uncertainty_does_not_confirm_preparation () =
  List.iter (fun fault -> with_path (fun source_path ->
    with_open source_path (fun store -> submit store ~now:1. "original" (`Assoc []));
    convert_fixture_to_exact_v2 source_path;
    let before = raw_file source_path in
    with_db source_path (fun source_db ->
      (* The production copy requires DELETE journaling; an in-memory database
         refuses that mode before reaching either injected commit fault. *)
      let destination = Sqlite3.db_open (Filename.concat (Filename.dirname source_path) "uncertain-copy.sqlite3") in
      Fun.protect ~finally:(fun () -> check bool "destination closed" true (Sqlite3.db_close destination)) @@ fun () ->
      Store.For_testing.fail_next_commit fault;
      assert_execution_error (Store.Offline.prepare_v2_copy ~source:source_db ~destination);
      check string "failed preparation preserves original operation" "1"
        (scalar destination "SELECT COUNT(*) FROM operations");
      check string "private destination state is not a success receipt"
        (match fault with Store.For_testing.Fail_before_commit -> "2" | Fail_after_commit -> "3")
        (scalar destination "PRAGMA user_version"));
    check string "failed preparation never alters source" before (raw_file source_path)))
    Store.For_testing.[Fail_before_commit;Fail_after_commit]

let with_adoption_source f = with_path (fun original_path ->
  with_open original_path (fun store ->
    submit store ~now:1. "retained-original" (`Assoc ["message",`String "preserve the original input"]);
    let running = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. running (checkpoint ()));
    submit store ~now:4. "queued-original" (`Assoc []);
    ignore (prepare store 901 [source 901]));
  convert_fixture_to_exact_v2 original_path;
  let prepared_path = Filename.concat (Filename.dirname original_path) "unresolved-original.sqlite3" in
  with_db original_path (fun source -> with_db prepared_path (fun destination ->
    ignore (Store.Offline.prepare_v2_copy ~source ~destination |> store_ok)));
  let original_before = raw_file original_path and prepared_before = raw_file prepared_path in
  let source = Sqlite3.db_open ~mode:`READONLY prepared_path in
  Fun.protect ~finally:(fun () -> check bool "unresolved source closed" true (Sqlite3.db_close source)) (fun () ->
    f ~prepared_path ~source;
    check string "published unresolved source is never rewritten" prepared_before (raw_file prepared_path);
    check string "original v2 evidence is never rewritten" original_before (raw_file original_path)))

let adoption_reference name bytes =
  let trace_id = Keeper_id.Trace_id.of_string name |> string_ok in
  Keeper_checkpoint_ref.create ~trace_id ~turn_count:3 ~canonical_checkpoint_bytes:bytes
  |> (function Ok reference -> reference | Error _ -> fail "adoption reference refused")
let adopt reference = Store.Offline.Operator_adopts_checkpoint reference
let derivative_path source_path name = Filename.concat (Filename.dirname source_path) name

let test_explicit_input_adoption_preserves_unknown_traces_and_execution_cells () =
  with_adoption_source (fun ~prepared_path ~source ->
    let first = adoption_reference "adopted-a" "first exact payload" in
    let second = adoption_reference "adopted-b" "second exact payload" in
    let adoptions = [adopt second;adopt first] in
    let path = derivative_path prepared_path "adopted.sqlite3" in
    with_db path (fun destination ->
      let receipt = Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions |> store_ok in
      check bool "receipt names exactly the selected trace identities" true
        (List.equal Keeper_checkpoint_ref.equal receipt.adopted_checkpoints [first;second]);
      check int "operation cells preserved" 2 receipt.original_records.operation_count;
      List.iter (fun query -> check bool "adoption preserves original journal cells" true
        (rows source query = rows destination query))
        ["SELECT * FROM operations ORDER BY sequence";
         "SELECT * FROM semantic_executions ORDER BY scope_key";
         "SELECT * FROM operation_batch_members ORDER BY operation_id";
         "SELECT * FROM metadata";"SELECT * FROM input_history"];
      let verified = Store.Offline.verify_input_adoption_copy ~source ~destination ~adoptions |> store_ok in
      check bool "read-only verification retains exact selection" true
        (List.equal Keeper_checkpoint_ref.equal verified.adopted_checkpoints [first;second]));
    let before = raw_file path in
    with_db path (fun destination ->
      ignore (Store.Offline.verify_input_adoption_copy ~source ~destination ~adoptions |> store_ok));
    check string "verification never rewrites derivative" before (raw_file path);
    let derivative = Store.open_existing ~path |> store_ok in
    Fun.protect ~finally:(fun () -> Store.close derivative |> store_ok) (fun () ->
      List.iter (fun reference -> check bool "selected trace has observed ownership" true
        ((Store.input_checkpoint derivative ~trace_id:reference.Keeper_checkpoint_ref.trace_id |> store_ok)
          = Store.Input_observed reference)) [first;second];
      let omitted = Keeper_id.Trace_id.of_string "omitted-historical-trace" |> string_ok in
      check bool "unselected history never becomes fresh" true
        ((Store.input_checkpoint derivative ~trace_id:omitted |> store_ok) = Store.Prior_input_unavailable)))

let test_input_adoption_requires_explicit_unique_selection_and_empty_destination () =
  with_adoption_source (fun ~prepared_path ~source ->
    let reference = checkpoint () in
    List.iteri (fun index adoptions ->
      with_db (derivative_path prepared_path (Printf.sprintf "refused-selection-%d.sqlite3" index))
        (fun destination ->
          assert_execution_error (Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions);
          check string "invalid selection does not create a schema" "0"
            (scalar destination "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")))
      [[];[adopt reference;adopt reference];
       [adopt reference;adopt (adoption_reference "semantic-test-trace" "conflicting exact bytes")]];
    with_db (derivative_path prepared_path "occupied-adoption.sqlite3") (fun destination ->
      sql destination "CREATE TABLE original_evidence(value TEXT)";
      sql destination "INSERT INTO original_evidence VALUES ('preserve')";
      assert_execution_error (Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions:[adopt reference]);
      check string "occupied destination stays untouched" "preserve"
        (scalar destination "SELECT value FROM original_evidence")))

let test_input_adoption_never_replaces_existing_rows_or_fresh_history () =
  with_path (fun source_path ->
    with_open source_path (fun _ -> ());
    with_db source_path (fun source ->
      List.iteri (fun index setup ->
        setup ();
        let before = raw_file source_path in
        with_db (derivative_path source_path (Printf.sprintf "rejected-source-%d.sqlite3" index)) (fun destination ->
          assert_execution_error (Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions:[adopt (checkpoint ())]);
          check string "source rejection occurs before copying" "0"
            (scalar destination "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"));
        check string "rejected source bytes stay intact" before (raw_file source_path))
        [(fun () -> ());
         (fun () -> sql source "UPDATE input_history SET basis='prior_unavailable'";
           sql source (Printf.sprintf "INSERT INTO input_checkpoints VALUES ('semantic-test-trace', 3, '%s')" (checkpoint ()).sha256))]))

let test_input_adoption_verification_rejects_changed_rows_and_original_cells () =
  with_adoption_source (fun ~prepared_path ~source ->
    List.iteri (fun index mutate ->
      with_db (derivative_path prepared_path (Printf.sprintf "tampered-adoption-%d.sqlite3" index)) (fun destination ->
        let adoptions = [adopt (checkpoint ())] in
        ignore (Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions |> store_ok);
        mutate destination;
        assert_execution_error (Store.Offline.verify_input_adoption_copy ~source ~destination ~adoptions)))
      [(fun db -> sql db "UPDATE metadata SET next_sequence=next_sequence+1");
       (fun db -> sql db "UPDATE input_checkpoints SET turn_count=turn_count+1");
       (fun db -> sql db "DELETE FROM input_checkpoints");
       (fun db -> sql db (Printf.sprintf "INSERT INTO input_checkpoints VALUES ('unselected', 3, '%s')" (checkpoint ()).sha256));
       (fun db -> sql db "UPDATE input_history SET basis='fresh'")])

let test_input_adoption_commit_uncertainty_requires_readback () =
  List.iter (fun fault -> with_adoption_source (fun ~prepared_path ~source ->
    with_db (derivative_path prepared_path "uncertain-adoption.sqlite3") (fun destination ->
      let adoptions = [adopt (checkpoint ())] in
      Store.For_testing.fail_next_commit fault;
      assert_execution_error (Store.Offline.prepare_input_adoption_copy ~source ~destination ~adoptions);
      check string "unknown commit is not an adoption receipt"
        (match fault with Store.For_testing.Fail_before_commit -> "0" | Fail_after_commit -> "1")
        (scalar destination "SELECT COUNT(*) FROM input_checkpoints");
      match fault with
      | Store.For_testing.Fail_before_commit ->
        assert_execution_error (Store.Offline.verify_input_adoption_copy ~source ~destination ~adoptions)
      | Fail_after_commit ->
        ignore (Store.Offline.verify_input_adoption_copy ~source ~destination ~adoptions |> store_ok))))
    Store.For_testing.[Fail_before_commit;Fail_after_commit]

let test_prior_generation_is_preserved () =
  with_path (fun path ->
    with_open path (fun store -> submit store ~now:5. "prior-journal" (`Assoc []));
    with_db path (fun db ->
      let next = scalar db "SELECT next_sequence FROM metadata WHERE singleton=1" in
      sql db "BEGIN IMMEDIATE";
      sql db "DROP TABLE input_checkpoints";
      sql db "DROP TABLE metadata";
      sql db "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v2'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT";
      sql db ("INSERT INTO metadata VALUES (1, 'masc.keeper_chat_operations.v2', " ^ next ^ ")");
      sql db "PRAGMA user_version=2";
      sql db "COMMIT");
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with Error _ -> () | Ok _ -> fail "prior generation was admitted");
    (match Store.open_or_create ~path with
     | Error _ -> ()
     | Ok store -> Store.close store |> store_ok; fail "ordinary open changed a prior generation");
    check string "prior generation and original rows retain exact bytes" before (raw_file path))

let test_missing_input_owner_table_is_not_reinitialized () =
  with_path (fun path ->
    with_open path (fun store -> submit store ~now:5. "owned-evidence" (`Assoc []));
    with_db path (fun db -> sql db "DROP TABLE input_checkpoints");
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with Error _ -> () | Ok _ -> fail "missing authority looked unobserved");
    (match Store.open_or_create ~path with
     | Error _ -> ()
     | Ok store -> Store.close store |> store_ok; fail "missing owner table was recreated");
    check string "missing owner evidence is preserved for recovery" before (raw_file path))

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
    assert_execution_error (Store.semantic_prepare ~input:fixture_input store ~id:(scope_id 92) ~sources:[source 91] ~now:30.);
    check string "incoherent record is retained without a replacement" before (raw_file path))

let direct_id value =
  Chat.Operation_id.of_string value |> string_ok |> Scope.direct_operation

let test_direct_and_auto_same_text_are_distinct_durable_scopes () =
  with_store (fun path store ->
    let text = Uuidm.to_string (uuid 91) in
    let direct = direct_id text and autonomous = scope_id 91 in
    let admit id = Store.semantic_prepare ~input:fixture_input store ~id ~sources:[] ~now:10. |> execution_ok |> created in
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

let test_input_survives_checkpoint_deferral_and_independent_work () =
  with_store (fun path store ->
    let operation_id = Chat.Operation_id.of_string "direct-input-lifetime" |> string_ok in
    let _submitted = Store.submit store ~now:1. ~operation_id
      ~source:(`Assoc ["kind", `String "direct"])
      ~input:(`Assoc ["message", `String "before queued edit"]) |> store_ok in
    let wanted = `Assoc ["message", `String "the actual edited request"; "continuation", `String "resume after approval"] in
    let _edited = Store.edit_queued store ~operation_id ~input:wanted |> store_ok in
    submit store ~now:2. "independent-work" (`Assoc ["message", `String "unrelated request"]);
    let claimed = claim store ~now:3. in
    let input = match claimed.input with Some input -> input | None -> fail "claimed input missing" in
    let id = Scope.direct_operation operation_id in
    let cp = checkpoint () in
    let deferred = defer_checkpoint store ~now:21. claimed cp in
    let waiting = get store id in
    check string "admission digest binds actual claimed input" claimed.execution_digest waiting.input_sha256;
    check bool "checkpoint keeps original request pending with admitted input" true
      (deferred.state = Chat.Queued && deferred.input = Some input);
    let b = claim store ~now:22. in
    check bool "independent work runs while A waits" true (not (Scope.equal (direct_scope b) id));
    let b = Store.succeed_running store ~now:23. ~operation_id:b.operation_id ~outcome_ref:"independent-response" |> store_ok in
    check bool "B completed and released its own input" true (Option.is_none b.input);
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let saved = get reopened id in
      check bool "A retains its own edited input after checkpoint deferral and B" true (saved.input = Some input);
      check string "A input identity survived reopen" waiting.input_sha256 saved.input_sha256;
      let reclaimed = Store.claim_next reopened ~now:25. |> store_ok in
      check bool "same request is reclaimed" true
        (Option.map (fun operation -> operation.Chat.operation_id) reclaimed = Some operation_id);
      Store.resume_direct_checkpoint reopened ~now:26. ~operation_id ~observed:(Execution.Agent_core cp) |> store_ok;
      check bool "A resumes with its own input" true ((get reopened id).input = Some input);
      let delivered = Store.succeed_running reopened ~now:27. ~operation_id ~outcome_ref:"actual-response" |> store_ok in
      check bool "actual delivery releases request input" true (Option.is_none delivered.input);
      let done_ = get reopened id in
      check bool "actual semantic completion releases payload" true (Option.is_none done_.input);
      check string "terminal admission retains digest" saved.input_sha256 done_.input_sha256;
      (match Store.semantic_prepare reopened ~id ~input ~sources:[] ~now:30. |> execution_ok with
       | Semantic_existing same ->
         check bool "terminal retry does not restore released input" true (Option.is_none same.input)
       | Semantic_created _ -> fail "terminal retry created another invocation");
      (match Store.semantic_prepare reopened ~id ~input:(`String "different request") ~sources:[] ~now:31. with
       | Error (Store.Admission_conflict actual) -> check bool "conflict names A" true (Scope.equal actual id)
       | _ -> fail "same ID accepted changed input after completion")))

let test_input_canonical_idempotency_and_conflict () =
  with_store (fun _path store ->
    let id = scope_id 201 in
    let first = `Assoc ["z", `Int 1; "a", `Assoc ["b", `String "B"; "a", `String "A"]] in
    let reordered = `Assoc ["a", `Assoc ["a", `String "A"; "b", `String "B"]; "z", `Int 1] in
    let a = Store.semantic_prepare store ~id ~input:first ~sources:[] ~now:1. |> execution_ok |> created in
    (match Store.semantic_prepare store ~id ~input:reordered ~sources:[] ~now:2. |> execution_ok with
     | Semantic_existing existing -> check string "canonical input is one admission" a.input_sha256 existing.input_sha256
     | Semantic_created _ -> fail "object order created another admission");
    (match Store.semantic_prepare store ~id ~input:(`Assoc ["z", `Int 2]) ~sources:[] ~now:3. with
     | Error (Store.Admission_conflict _) -> () | _ -> fail "changed input reused admitted identity");
    check bool "conflict leaves full admission unchanged" true (Execution.to_json a = Execution.to_json (get store id)))

let test_invalid_admitted_input_is_not_committed () =
  List.iter (fun input -> with_store (fun _path store ->
    let id = scope_id 203 in
    (match Store.semantic_prepare store ~id ~input ~sources:[] ~now:1. with
     | Error (Store.Invalid_execution (Execution.Invalid_record _)) -> ()
     | _ -> fail "invalid input was admitted");
    check bool "invalid input leaves no journal row" true
      ((Store.semantic_get store id |> execution_ok) = None)))
    [`Assoc ["duplicate", `Int 1; "duplicate", `Int 2]; `Float Float.nan; `Float Float.infinity]

let test_null_payload_is_distinct_from_released_input () =
  with_store (fun path store ->
    submit store ~now:1. "null-payload" `Null;
    let claimed = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. claimed (checkpoint ()));
    let id = direct_scope claimed in
    Store.close store |> store_ok;
    with_open path (fun reopened ->
      let a = get reopened id in
      check bool "opaque null input remains present" true (a.input = Some `Null);
      let _cancelled = Store.cancel_queued reopened ~now:4. ~operation_id:claimed.operation_id |> store_ok in
      let cancelled = get reopened id in
      check bool "cancellation settled the continuation" true (Execution.is_terminal cancelled);
      check bool "released input is absent" true (Option.is_none cancelled.input)))

let test_corrupt_input_cannot_become_fresh_or_repaired () =
  List.iter (fun replacement -> with_store (fun path store ->
    let a = prepare store 205 [] in
    let json = match Execution.to_json a with
      | `Assoc fields -> `Assoc (("input", replacement) :: List.remove_assoc "input" fields)
      | _ -> fail "expected object" in
    Store.close store |> store_ok;
    with_db path (fun db ->
      let stmt = Sqlite3.prepare db "UPDATE semantic_executions SET record_json=? WHERE phase='preparing'" in
      Fun.protect ~finally:(fun () -> check bool "statement finalized" true (Sqlite3.finalize stmt = Sqlite3.Rc.OK))
        (fun () ->
          check bool "replacement bound" true (Sqlite3.bind_text stmt 1 (Yojson.Safe.to_string json) = Sqlite3.Rc.OK);
          check bool "replacement stored" true (Sqlite3.step stmt = Sqlite3.Rc.DONE)));
    let before = raw_file path in
    (match Store.inspect_outstanding ~path with
     | Error (Store.Integrity_error _) -> ()
     | Error error -> fail (Store.error_to_string error)
     | Ok _ -> fail "corrupt admitted input was accepted as an empty/fresh operation");
    check string "corrupt payload evidence is retained" before (raw_file path)))
    [`Null; `Assoc ["payload", `String "different input with stale digest"]]

let () =
  run "keeper semantic execution store"
    [ "offline preparation", [
        test_case "copy preserves original rows and unknown input" `Quick test_offline_copy_preserves_evidence_and_prior_uncertainty;
        test_case "occupied destinations and corrupt source are refused" `Quick test_offline_copy_refuses_nonempty_destination_and_corrupt_source;
        test_case "reused sequence refuses preparation before copying" `Quick test_offline_copy_refuses_reused_sequence;
        test_case "uncertain commit never confirms preparation" `Quick test_offline_copy_commit_uncertainty_does_not_confirm_preparation ];
      "explicit prior input adoption", [
        test_case "selection preserves all original cells and omitted uncertainty" `Quick test_explicit_input_adoption_preserves_unknown_traces_and_execution_cells;
        test_case "empty, duplicate and occupied selections refuse writes" `Quick test_input_adoption_requires_explicit_unique_selection_and_empty_destination;
        test_case "fresh history and existing rows are never overwritten" `Quick test_input_adoption_never_replaces_existing_rows_or_fresh_history;
        test_case "readback rejects changed selection and original evidence" `Quick test_input_adoption_verification_rejects_changed_rows_and_original_cells;
        test_case "commit uncertainty requires actual relationship readback" `Quick test_input_adoption_commit_uncertainty_requires_readback ];
      "admitted input", [
        test_case "Direct input survives checkpoint deferral and independent work" `Quick test_input_survives_checkpoint_deferral_and_independent_work;
        test_case "canonical input identity rejects changed requests" `Quick test_input_canonical_idempotency_and_conflict;
        test_case "invalid input creates no partial admission" `Quick test_invalid_admitted_input_is_not_committed;
        test_case "null payload is not released input" `Quick test_null_payload_is_distinct_from_released_input;
        test_case "corrupt input never becomes fresh" `Quick test_corrupt_input_cannot_become_fresh_or_repaired ];
      "typed identity", [
        test_case "Direct and Auto identical text retain separate durable identities" `Quick test_direct_and_auto_same_text_are_distinct_durable_scopes ];
      "durability", [
        test_case "identity frame and sources commit together" `Quick test_identity_frame_and_membership_commit_together;
        test_case "admission failure and uncertain commit reopen by identity" `Quick test_admission_commit_faults;
        test_case "terminal record stays immutable" `Quick test_terminal_record_is_immutable ];
      "owner isolation", [
        test_case "startup marks an interrupted execution and releases the running slot" `Quick test_restart_interrupted_execution_releases_the_running_slot;
        test_case "readonly inventory includes every unsettled phase" `Quick test_readonly_inventory_includes_every_unsettled_phase;
        test_case "corrupt owned frame refuses unsafe inspection" `Quick test_corrupt_semantic_frame_refuses_unsafe_inspection;
        test_case "a Gate record that names a session scope is refused" `Quick test_gate_record_with_a_session_scope_is_refused;
        test_case "terminal index cannot conceal pending evidence" `Quick test_corrupt_terminal_index_cannot_hide_outstanding_execution ];
      "schema", [
        test_case "prior generation is refused without changing rows" `Quick test_prior_generation_is_preserved;
        test_case "missing input authority is never recreated" `Quick test_missing_input_owner_table_is_not_reinitialized;
        test_case "corrupt raw database remains intact" `Quick test_corrupt_database_bytes_are_not_reinitialized ] ]
