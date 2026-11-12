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
let hash text = Agent_core_sha256.(digest_string text |> to_hex)
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
  match Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:3 ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes "checkpoint bytes") with
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
    ~finally:(fun () ->
      Store.For_testing.clear_commit_fault ();
      Store.For_testing.clear_preparation_retry_read_fault ();
      remove_tree directory)
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

(* Nothing creates a receipt obligation yet, so these tests read one in from a
   record they patched. *)
let pending_obligation request_id =
  `Assoc ["request_id", `String request_id; "state", `Assoc ["kind", `String "pending"]]
let arrived_obligation request_id resolution =
  `Assoc ["request_id", `String request_id;
          "state", `Assoc ["kind", `String "arrived"; "resolution", `String resolution]]
let with_receipt_obligations obligations (execution : Execution.t) =
  match Execution.to_json execution with
  | `Assoc fields ->
    `Assoc (("receipt_obligations", `List obligations) :: List.remove_assoc "receipt_obligations" fields)
  | _ -> fail "execution JSON is not an object"
(* The store refuses a record whose text is not the canonical encoding. *)
let canonical json =
  match Chat.canonical_json_string json with
  | Ok text -> text
  | Error detail -> fail detail
let exec_ok = function Ok value -> value | Error error -> fail (Execution.error_to_string error)
let decoded json = Execution.of_json json |> exec_ok
let request_ids (execution : Execution.t) =
  List.map (fun (obligation : Execution.receipt_obligation) -> obligation.request_id)
    execution.receipt_obligations
let running_with obligations =
  let created = Execution.create ~id:(scope_id 301) ~input:fixture_input ~sources:[] ~now:1. |> exec_ok in
  let running = Execution.apply ~now:2. Execution.Confirm_sources created |> exec_ok
    |> Execution.apply ~now:3. Execution.Begin_execution |> exec_ok in
  decoded (with_receipt_obligations obligations running)
let set_receipt_obligations path (id : Scope.t) obligations =
  with_db path (fun db ->
    let found = List.find_map (function
      | [Some key; Some text] ->
        (match Execution.of_json (Yojson.Safe.from_string text) with
         | Ok record when Scope.equal record.id id -> Some (key, record)
         | Ok _ | Error _ -> None)
      | _ -> None) (rows db "SELECT scope_key, record_json FROM semantic_executions") in
    match found with
    | None -> fail "execution row not found"
    | Some (key, record) ->
      let stmt = Sqlite3.prepare db "UPDATE semantic_executions SET record_json=? WHERE scope_key=?" in
      Fun.protect ~finally:(fun () -> check bool "statement finalized" true (Sqlite3.finalize stmt = Sqlite3.Rc.OK))
        (fun () ->
          check bool "record bound" true
            (Sqlite3.bind_text stmt 1 (canonical (with_receipt_obligations obligations record)) = Sqlite3.Rc.OK);
          check bool "key bound" true (Sqlite3.bind_text stmt 2 key = Sqlite3.Rc.OK);
          check bool "record stored" true (Sqlite3.step stmt = Sqlite3.Rc.DONE)))

let test_settle_and_interruption_release_receipt_obligations () =
  let running = running_with [pending_obligation "request-a"; arrived_obligation "request-b" "receipt_in_outbox"] in
  check (list string) "the record carries both requests" ["request-a"; "request-b"] (request_ids running);
  List.iter (fun terminal ->
    let settled = Execution.apply ~now:4. (Execution.Settle terminal) running |> exec_ok in
    check (list string) "settling releases every request" [] (request_ids settled);
    check int64 "in the settling transition" (Int64.succ running.revision) settled.revision)
    [Execution.Completed; Execution.Cancelled; Execution.Failed "operation failed"];
  let interrupted = Execution.apply ~now:4.
    (Execution.Require_reconciliation "process restarted during semantic execution") running |> exec_ok in
  (match interrupted.phase with
   | Execution.Recovering {origin = Execution.Interrupted_execution; _} -> ()
   | _ -> fail "a running execution did not become interrupted");
  check (list string) "an interrupted execution releases every request" [] (request_ids interrupted);
  let suspended = Execution.apply ~now:4. (Execution.Suspend (checkpoint ())) running |> exec_ok in
  check (list string) "ending the turn keeps ownership" ["request-a"; "request-b"] (request_ids suspended);
  let recovering = Execution.apply ~now:5. (Execution.Require_reconciliation "reconcile") suspended |> exec_ok in
  check (list string) "a resumable recovery keeps ownership" ["request-a"; "request-b"] (request_ids recovering);
  let resumed = Execution.apply ~now:5. (Execution.Resume_checkpoint (checkpoint ())) suspended |> exec_ok in
  check (list string) "resuming keeps ownership" ["request-a"; "request-b"] (request_ids resumed)

let test_receipt_obligations_are_exact_v3_fields () =
  let created = Execution.create ~id:(scope_id 301) ~input:fixture_input ~sources:[] ~now:1. |> exec_ok in
  let json = Execution.to_json created in
  check string "the record format is v3" "masc.keeper_semantic_execution.v3"
    Yojson.Safe.Util.(json |> member "schema" |> to_string);
  check bool "an empty list is written, not omitted" true
    (Yojson.Safe.Util.member "receipt_obligations" json = `List []);
  let owned = running_with
    [pending_obligation "p"; arrived_obligation "a" "receipt_in_outbox"; arrived_obligation "l" "source_lost"] in
  check bool "every state round-trips" true (Execution.to_json owned = Execution.to_json (decoded (Execution.to_json owned)));
  let replaced name value = match Execution.to_json owned with
    | `Assoc fields -> `Assoc ((name, value) :: List.remove_assoc name fields)
    | _ -> fail "execution JSON is not an object" in
  let without name = match Execution.to_json owned with
    | `Assoc fields -> `Assoc (List.remove_assoc name fields)
    | _ -> fail "execution JSON is not an object" in
  let settled = Execution.apply ~now:4. (Execution.Settle Execution.Cancelled) owned |> exec_ok in
  let interrupted = Execution.apply ~now:4. (Execution.Require_reconciliation "restart") owned |> exec_ok in
  List.iter (fun (label, json) -> match Execution.of_json json with
    | Error _ -> ()
    | Ok _ -> fail (label ^ " was accepted"))
    [ "the v2 format", replaced "schema" (`String "masc.keeper_semantic_execution.v2")
    ; "a record without the field", without "receipt_obligations"
    ; "a duplicate request", with_receipt_obligations [pending_obligation "x"; pending_obligation "x"] owned
    ; "a blank request", with_receipt_obligations [pending_obligation " "] owned
    ; "an unknown resolution", with_receipt_obligations [arrived_obligation "x" "unknown"] owned
    ; "a pending state with a resolution",
      with_receipt_obligations [`Assoc ["request_id", `String "x";
        "state", `Assoc ["kind", `String "pending"; "resolution", `String "source_lost"]]] owned
    ; "an arrived state without a resolution",
      with_receipt_obligations [`Assoc ["request_id", `String "x";
        "state", `Assoc ["kind", `String "arrived"]]] owned
    ; "a settled record that owns a request", with_receipt_obligations [pending_obligation "x"] settled
    ; "an interrupted record that owns a request", with_receipt_obligations [pending_obligation "x"] interrupted ]

let test_receipt_owners_are_read_without_the_owner_and_cancel_releases_them () =
  with_store (fun path store ->
    submit store ~now:1. "waits" fixture_input;
    let waiting = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. waiting (checkpoint ()));
    let id = direct_scope waiting in
    Store.close store |> store_ok;
    set_receipt_obligations path id [pending_obligation "request-a"; arrived_obligation "request-b" "source_lost"];
    let before = raw_file path in
    let owners = Store.inspect_receipt_owners ~path |> store_ok in
    let owner request_id = Store.receipt_owner owners ~request_id in
    check bool "a pending request is owned by its execution" true (Option.equal Scope.equal (owner "request-a") (Some id));
    check bool "an arrived request is owned by its execution" true (Option.equal Scope.equal (owner "request-b") (Some id));
    check bool "another request has no owner" true (Option.is_none (owner "request-c"));
    check string "reading the owners leaves the database bytes alone" before (raw_file path);
    with_open path (fun reopened ->
      check (list string) "the reopened store keeps the requests" ["request-a"; "request-b"] (request_ids (get reopened id));
      ignore (Store.cancel_queued reopened ~now:4. ~operation_id:waiting.operation_id |> store_ok);
      let cancelled = get reopened id in
      check bool "cancelling settled the execution" true (Execution.is_terminal cancelled);
      check (list string) "cancelling released the requests" [] (request_ids cancelled));
    let owners = Store.inspect_receipt_owners ~path |> store_ok in
    check bool "a settled execution owns nothing" true
      (Option.is_none (Store.receipt_owner owners ~request_id:"request-a")))

let obligation request_id state = Execution.receipt_obligation ~request_id ~state |> string_ok

let entry_states (execution : Execution.t) =
  List.map (fun (entry : Execution.receipt_obligation) -> entry.request_id, entry.state) execution.receipt_obligations

let test_await_and_resolve_receipt_actions () =
  let running = running_with [] in
  let awaiting = Execution.apply ~now:4. (Execution.Await_receipt (obligation "request-a" Execution.Pending)) running |> exec_ok in
  check (list string) "waiting adds the request" ["request-a"] (request_ids awaiting);
  check string "and leaves the phase to the suspend that follows" (Execution.phase_name running.phase) (Execution.phase_name awaiting.phase);
  let repeated = Execution.apply ~now:5.
    (Execution.Await_receipt (obligation "request-a" (Execution.Arrived Execution.Receipt_in_outbox))) awaiting |> exec_ok in
  check bool "a request the execution owns keeps its entry and state" true
    (entry_states repeated = ["request-a", Execution.Pending] && repeated.revision = awaiting.revision);
  let two = Execution.apply ~now:5. (Execution.Await_receipt (obligation "request-b" Execution.Pending)) awaiting |> exec_ok in
  check (list string) "another request is appended" ["request-a"; "request-b"] (request_ids two);
  let resolved = Execution.apply ~now:6.
    (Execution.Resolve_receipt {request_id = "request-a"; resolution = Execution.Source_lost}) two |> exec_ok in
  check bool "a pending entry arrives with the resolution it was given" true
    (entry_states resolved = ["request-a", Execution.Arrived Execution.Source_lost; "request-b", Execution.Pending]);
  let again = Execution.apply ~now:7.
    (Execution.Resolve_receipt {request_id = "request-a"; resolution = Execution.Receipt_in_outbox}) resolved |> exec_ok in
  check bool "an arrived entry is not resolved again" true
    (entry_states again = entry_states resolved && again.revision = resolved.revision);
  let missing = Execution.apply ~now:7.
    (Execution.Resolve_receipt {request_id = "request-z"; resolution = Execution.Receipt_in_outbox}) resolved |> exec_ok in
  check bool "a request with no entry changes nothing" true (missing.revision = resolved.revision);
  let settled = Execution.apply ~now:8. (Execution.Settle Execution.Completed) running |> exec_ok in
  let late = Execution.apply ~now:9.
    (Execution.Resolve_receipt {request_id = "request-a"; resolution = Execution.Receipt_in_outbox}) settled |> exec_ok in
  check bool "a notice after the execution settled changes nothing" true (late.revision = settled.revision)

let test_await_receipt_is_admitted_only_while_the_execution_holds_the_slot () =
  let running = running_with [] in
  let created = Execution.create ~id:(scope_id 302) ~input:fixture_input ~sources:[] ~now:1. |> exec_ok in
  let ready = Execution.apply ~now:2. Execution.Confirm_sources created |> exec_ok in
  let suspended = Execution.apply ~now:4. (Execution.Suspend (checkpoint ())) running |> exec_ok in
  let settled = Execution.apply ~now:4. (Execution.Settle Execution.Cancelled) running |> exec_ok in
  let wait = Execution.Await_receipt (obligation "request-a" Execution.Pending) in
  List.iter (fun (label, execution) ->
    check bool (label ^ " refuses a wait") true (Result.is_error (Execution.apply ~now:5. wait execution)))
    ["a prepared execution", created; "a ready execution", ready; "a suspended execution", suspended; "a settled execution", settled];
  check bool "a running execution admits it" true (Result.is_ok (Execution.apply ~now:5. wait running))

let test_receipt_owners_of_a_missing_store_is_empty_and_double_ownership_is_refused () =
  with_path (fun path ->
    let owners = Store.inspect_receipt_owners ~path |> store_ok in
    check bool "a journal that was never created owns nothing" true
      (Option.is_none (Store.receipt_owner owners ~request_id:"request-a")));
  with_store (fun path store ->
    submit store ~now:1. "first" fixture_input;
    let first = claim store ~now:2. in
    ignore (defer_checkpoint store ~now:3. first (checkpoint ()));
    let second = prepare store 7 [source 7] in
    Store.close store |> store_ok;
    set_receipt_obligations path (direct_scope first) [pending_obligation "request-x"];
    set_receipt_obligations path second.id [pending_obligation "request-x"];
    match Store.inspect_receipt_owners ~path with
    | Error (Store.Integrity_error _) -> ()
    | Error error -> fail (Store.error_to_string error)
    | Ok _ -> fail "a request listed by two executions had an owner")

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
      let _failed = Store.settle_running_without_executor ~cause:Store.After_process_restart reopened ~now:30. |> store_ok in
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
  Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:3 ~sha256:(Keeper_checkpoint_ref.sha256_of_canonical_bytes bytes)
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

let test_dispatch_admission_requires_semantic_checkpoint () =
  with_store (fun _path store ->
    submit store ~now:1. "no-preparation" fixture_input;
    let operation = claim store ~now:2. in
    let scope = direct_scope operation in
    let before = Chat.to_json operation in
    check bool "fresh claimed operation has no semantic preparation" true
      (Store.semantic_get store scope |> execution_ok = None);
    (match Store.enter_direct_preparation store ~now:3. ~operation_id:operation.operation_id
        ~execution_digest:operation.execution_digest with
     | Error (Store.Invalid_input _) -> ()
     | Error error -> fail (Store.error_to_string error)
     | Ok () -> fail "an operation without semantic preparation gained dispatch admission");
    let after = Store.get store operation.operation_id |> store_ok |> Option.get in
    check bool "refused admission preserves exact operation and input" true (Chat.to_json after = before);
    check bool "refused admission creates no semantic row" true
      (Store.semantic_get store scope |> execution_ok = None))

let test_preparation_wait_preserves_official_checkpoint ?(agent_core=false) ?retry_fault client_kind fault () =
  with_path (fun path ->
    let operation_id = operation_id "preparation-original" in
    let scope = Scope.direct_operation operation_id in
    let input = `Assoc ["instructions",`String "original authority";"message",`String "original input"] in
    let frame = Frame.admit Frame.empty (Frame.Fresh scope) |> frame_ok in
    let checkpoint = if agent_core then Execution.Agent_core (checkpoint ())
      else Execution.Official_client
        {client_kind;runtime_id="official.test";session_id="original-session";
         turn_id="original-turn";tool_surface_sha256=hash "original tools";frame} in
    let operation, waiting = with_open path (fun store ->
      submit store ~now:1. "preparation-original" input;
      let original = claim store ~now:2. in
      Store.defer_direct_checkpoint store ~now:3. ~operation_id
        ~execution_digest:original.execution_digest ~checkpoint |> store_ok |> ignore;
      let operation = claim store ~now:4. in
      if not agent_core then
        Store.resume_direct_checkpoint store ~now:5. ~operation_id ~observed:checkpoint |> store_ok;
      let before = Execution.to_json (get store scope) in
      let changed = match checkpoint with
        | Execution.Official_client original -> Execution.Official_client {original with turn_id="unrelated-turn"}
        | Agent_core reference ->
          let changed = Keeper_checkpoint_ref.of_persisted ~trace_id:reference.trace_id
              ~turn_count:(reference.turn_count + 1) ~sha256:(hash "unrelated checkpoint") in
          Execution.Agent_core (match changed with Ok value -> value | Error _ -> fail "changed checkpoint fixture") in
      assert_execution_error (Store.wait_direct_preparation store ~now:6. ~operation_id
        ~execution_digest:operation.execution_digest ~observed:changed ~detail:"missing managed guidance");
      check bool "stale checkpoint changes no authority" true (before = Execution.to_json (get store scope));
      Option.iter Store.For_testing.fail_next_commit fault;
      let result = Store.wait_direct_preparation store ~now:6. ~operation_id
        ~execution_digest:operation.execution_digest ~observed:checkpoint ~detail:"missing managed guidance" in
      (match fault,result with
       | Some Store.For_testing.Fail_before_commit, Error (Store.Store_unavailable _) ->
         check bool "rollback retains exact not-entered preparation" true
           (match (get store scope).phase with Execution.Preparing_checkpoint saved ->
             Execution.equal_gate_checkpoint checkpoint (Execution.Official_client saved) | _ -> false);
         Store.settle_running_without_executor ~cause:Store.After_process_restart store ~now:6. |> store_ok |> ignore
       | _,result -> result |> store_ok |> ignore);
      let waiting = Store.direct_preparation_wait store ~operation_id |> store_ok |> Option.get in
      check bool "ordinary drain cannot claim preparation wait" true
        (Option.is_none (Store.claim_next store ~now:7. |> store_ok));
      operation,waiting) in
    with_open path (fun store ->
      check int "restart settles no blocked operation" 0
        (List.length (Store.settle_running_without_executor ~cause:Store.After_process_restart store ~now:8. |> store_ok));
      let reread = Store.direct_preparation_wait store ~operation_id |> store_ok |> Option.get in
      check bool "exact wait survives reopening" true (reread = waiting);
      let retained = get store scope in
      check bool "original input remains independently owned" true (retained.input = Some input);
      check bool "original checkpoint remains exact" true
        (Execution.equal_gate_checkpoint checkpoint reread.waiting.checkpoint);
      (match checkpoint with
       | Execution.Agent_core reference ->
         check bool "preparation wait retains original checkpoint bytes" true
           (List.exists (Keeper_checkpoint_ref.equal reference) (Execution.checkpoint_references retained))
       | Official_client _ -> ());
      check bool "reopened wait does not spin" true
        (Option.is_none (Store.claim_next store ~now:9. |> store_ok));
      submit store ~now:10. "preparation-independent" (`String "new steering");
      let newer = claim store ~now:11. in
      check bool "independent work has its own identity" true
        (Chat.Operation_id.equal newer.operation_id (Chat.Operation_id.of_string "preparation-independent" |> string_ok));
      Store.succeed_running store ~now:12. ~operation_id:newer.operation_id ~outcome_ref:"newer-completed"
        |> store_ok |> ignore;
      assert_execution_error (Store.retry_direct_preparation store ~now:13. ~operation_id
        ~expected_revision:(Int64.pred waiting.revision) ~execution_digest:operation.execution_digest);
      assert_execution_error (Store.retry_direct_preparation store ~now:13. ~operation_id
        ~expected_revision:waiting.revision ~execution_digest:(hash "another input"));
      check bool "failed retry keeps exact blocked state" true
        (Store.direct_preparation_wait store ~operation_id |> store_ok = Some waiting);
      Option.iter Store.For_testing.fail_next_commit retry_fault;
      let retried = Store.retry_direct_preparation store ~now:14. ~operation_id
          ~expected_revision:waiting.revision ~execution_digest:operation.execution_digest in
      (match retry_fault,retried with
       | Some Store.For_testing.Fail_before_commit, Error (Store.Store_unavailable _) ->
         check bool "retry rollback keeps exact blocked state" true
           (Store.direct_preparation_wait store ~operation_id |> store_ok = Some waiting);
         check bool "retry rollback does not release ordinary drain" true
           (Option.is_none (Store.claim_next store ~now:14. |> store_ok));
         Store.retry_direct_preparation store ~now:14. ~operation_id
           ~expected_revision:waiting.revision ~execution_digest:operation.execution_digest |> store_ok |> ignore
       | _,result -> result |> store_ok |> ignore);
      check bool "confirmed retry advances the exact observed revision once" true
        (Int64.equal (get store scope).revision (Int64.succ waiting.revision));
      assert_execution_error (Store.retry_direct_preparation store ~now:14. ~operation_id
        ~expected_revision:waiting.revision ~execution_digest:operation.execution_digest);
      let resumed = claim store ~now:15. in
      check bool "retry selects original operation once" true
        (Chat.Operation_id.equal resumed.operation_id operation_id && resumed.input=Some input
         && resumed.execution_digest=operation.execution_digest);
      Store.resume_direct_checkpoint store ~now:16. ~operation_id ~observed:checkpoint |> store_ok;
      Store.enter_direct_preparation store ~now:16. ~operation_id ~execution_digest:operation.execution_digest |> store_ok;
      let entered = Execution.to_json (get store scope) in
      Store.enter_direct_preparation store ~now:16. ~operation_id ~execution_digest:operation.execution_digest |> store_ok;
      check bool "repeated callback preserves confirmed dispatch admission" true
        (Execution.to_json (get store scope) = entered);
      Store.succeed_running store ~now:17. ~operation_id ~outcome_ref:"original-completed" |> store_ok |> ignore;
      check bool "terminal acknowledgement releases original input" true
        (Option.is_none (get store scope).input);
      check bool "no duplicate invocation remains" true
        (Option.is_none (Store.claim_next store ~now:18. |> store_ok))))

let test_preparation_wait_rejects_consumed_core_checkpoint () =
  with_store (fun _ store ->
    submit store ~now:1. "entered-core-preparation" fixture_input;
    let original = claim store ~now:2. in
    let checkpoint = Execution.Agent_core (checkpoint ()) in
    Store.defer_direct_checkpoint store ~now:3. ~operation_id:original.operation_id
      ~execution_digest:original.execution_digest ~checkpoint |> store_ok |> ignore;
    ignore (claim store ~now:4.);
    Store.resume_direct_checkpoint store ~now:5. ~operation_id:original.operation_id ~observed:checkpoint |> store_ok;
    let before = Execution.to_json (get store (Scope.direct_operation original.operation_id)) in
    assert_execution_error (Store.wait_direct_preparation store ~now:6. ~operation_id:original.operation_id
      ~execution_digest:original.execution_digest ~observed:checkpoint ~detail:"late preparation failure");
    check bool "entered Core execution cannot regain a consumed checkpoint" true
      (before=Execution.to_json (get store (Scope.direct_operation original.operation_id))))

let test_uncertain_preparation_retry_reopens_by_original_identity () =
  with_path (fun path ->
    let operation_id = operation_id "uncertain-preparation-retry" in
    let scope = Scope.direct_operation operation_id in
    let frame = Frame.admit Frame.empty (Frame.Fresh scope) |> frame_ok in
    let checkpoint = Execution.Official_client
      {client_kind=Muse;runtime_id="official.uncertain";session_id="original-session";
       turn_id="original-turn";tool_surface_sha256=hash "original tools";frame} in
    let original, waiting = with_open path (fun store ->
      submit store ~now:1. "uncertain-preparation-retry" fixture_input;
      let original = claim store ~now:2. in
      Store.defer_direct_checkpoint store ~now:3. ~operation_id
        ~execution_digest:original.execution_digest ~checkpoint |> store_ok |> ignore;
      ignore (claim store ~now:4.);
      Store.resume_direct_checkpoint store ~now:5. ~operation_id ~observed:checkpoint |> store_ok;
      Store.wait_direct_preparation store ~now:6. ~operation_id
        ~execution_digest:original.execution_digest ~observed:checkpoint ~detail:"missing managed guidance"
        |> store_ok |> ignore;
      let waiting = Store.direct_preparation_wait store ~operation_id |> store_ok |> Option.get in
      Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
      Store.For_testing.fail_next_preparation_retry_read ();
      (match Store.retry_direct_preparation store ~now:7. ~operation_id
          ~expected_revision:waiting.revision ~execution_digest:waiting.execution_digest with
       | Error (Store.Store_unavailable _) -> ()
       | Ok _ | Error _ -> fail "failed retry confirmation was reported as a definite outcome");
      original, waiting) in
    with_open path (fun store ->
      let retained = get store scope in
      check bool "reopened uncertain retry keeps original input" true (retained.input=Some fixture_input);
      check bool "reopened retry advances its exact predecessor once" true
        (Int64.equal retained.revision (Int64.succ waiting.revision));
      check bool "committed explicit retry retains the exact authorized checkpoint" true
        (match retained.phase with
         | Execution.Recovering {origin=Official_checkpointed observed;_} ->
           Execution.equal_gate_checkpoint checkpoint (Execution.Official_client observed)
         | _ -> false);
      check bool "committed retry has no second preparation retry available" true
        (Option.is_none (Store.direct_preparation_wait store ~operation_id |> store_ok));
      assert_execution_error (Store.retry_direct_preparation store ~now:8. ~operation_id
        ~expected_revision:waiting.revision ~execution_digest:waiting.execution_digest);
      check bool "stale retry changes no admitted authority" true
        (Execution.to_json (get store scope)=Execution.to_json retained);
      check int "restart preserves the explicitly authorized retry" 0
        (List.length (Store.settle_running_without_executor ~cause:Store.After_process_restart store ~now:9. |> store_ok));
      let resumed = claim store ~now:10. in
      check bool "normal admission selects the same operation and input" true
        (Chat.Operation_id.equal resumed.operation_id original.operation_id
         && resumed.execution_digest=original.execution_digest && resumed.input=Some fixture_input);
      Store.resume_direct_checkpoint store ~now:11. ~operation_id ~observed:checkpoint |> store_ok;
      Store.enter_direct_preparation store ~now:12. ~operation_id
        ~execution_digest:original.execution_digest |> store_ok;
      Store.succeed_running store ~now:13. ~operation_id ~outcome_ref:"original completed"
        |> store_ok |> ignore;
      check bool "no fresh operation was authorized" true
        (Option.is_none (Store.claim_next store ~now:14. |> store_ok))))

let () =
  run "keeper semantic execution store"
    [ "preparation wait", [
        test_case "consumed Core checkpoint cannot regain preparation retry authority" `Quick
          test_preparation_wait_rejects_consumed_core_checkpoint;
        test_case "Agent Core preparation keeps original checkpoint through explicit retry" `Quick
          (test_preparation_wait_preserves_official_checkpoint ~agent_core:true Execution.Codex None);
        test_case "Agent Core uncertain wait retains its exact checkpoint" `Quick
          (test_preparation_wait_preserves_official_checkpoint ~agent_core:true Execution.Codex (Some Store.For_testing.Fail_after_commit));
        test_case "fresh claim without semantic checkpoint refuses dispatch admission" `Quick
          test_dispatch_admission_requires_semantic_checkpoint;
        test_case "Muse after consume retains original authority" `Quick
          (test_preparation_wait_preserves_official_checkpoint Execution.Muse None);
        test_case "Codex after consume retains original authority" `Quick
          (test_preparation_wait_preserves_official_checkpoint Execution.Codex None);
        test_case "Antigravity after consume retains original authority" `Quick
          (test_preparation_wait_preserves_official_checkpoint Execution.Antigravity None);
        test_case "rolled-back wait survives restart with original authority" `Quick
          (test_preparation_wait_preserves_official_checkpoint Execution.Muse (Some Store.For_testing.Fail_before_commit));
        test_case "committed uncertain wait is confirmed exactly" `Quick
          (test_preparation_wait_preserves_official_checkpoint Execution.Muse (Some Store.For_testing.Fail_after_commit));
        test_case "retry rollback keeps the exact wait blocked" `Quick
          (test_preparation_wait_preserves_official_checkpoint ~retry_fault:Store.For_testing.Fail_before_commit Execution.Muse None);
        test_case "retry acknowledgement loss confirms exact committed transition" `Quick
          (test_preparation_wait_preserves_official_checkpoint ~retry_fault:Store.For_testing.Fail_after_commit Execution.Muse None);
        test_case "lost retry acknowledgement and confirmation reopen the same authorization" `Quick
          test_uncertain_preparation_retry_reopens_by_original_identity ];
      "offline preparation", [
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
      "receipt ownership", [
        test_case "settling and an interrupting restart release the requests, other transitions keep them" `Quick test_settle_and_interruption_release_receipt_obligations;
        test_case "the record format is exact v3" `Quick test_receipt_obligations_are_exact_v3_fields;
        test_case "owners are read without the Owner and cancelling releases them" `Quick test_receipt_owners_are_read_without_the_owner_and_cancel_releases_them;
        test_case "a missing journal owns nothing and double ownership is refused" `Quick test_receipt_owners_of_a_missing_store_is_empty_and_double_ownership_is_refused;
        test_case "waiting adds a request and resolving moves a pending entry once" `Quick test_await_and_resolve_receipt_actions;
        test_case "waiting is admitted only while the execution holds the slot" `Quick test_await_receipt_is_admitted_only_while_the_execution_holds_the_slot ];
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
