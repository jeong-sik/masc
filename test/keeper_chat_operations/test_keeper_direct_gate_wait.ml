open Alcotest
module Store = Keeper_chat_operation_store
module Operation = Keeper_chat_operation
module Semantic = Keeper_semantic_execution
let ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let require = function Ok value -> value | Error _ -> fail "invalid fixture"
let rejected = function Error _ -> () | Ok _ -> fail "invalid transition accepted"
let id value = Operation.Operation_id.of_string value |> require
let original = id "original-gate-operation"
let other = id "independent-operation"
let input = Operation.canonical_json (`Assoc ["message", `String "complete original task";
  "attachments", `List [`String "original-evidence"]; "channel", `String "original-channel";
  "task", `String "original-task"]) |> require
let source = `Assoc ["kind", `String "dashboard"]
let canonical_bytes marker =
  Agent_core.Checkpoint.to_string Agent_core.Checkpoint.{
    version=checkpoint_version;session_id="original-trace";agent_name="gate-fixture";model="fixture";
    system_prompt=None;messages=[Agent_core.Types.user_msg marker];usage=Agent_core.Types.empty_usage;
    turn_count=3;created_at=1000.;tools=[];tool_choice=None;disable_parallel_tool_use=false;
    temperature=None;top_p=None;top_k=None;min_p=None;enable_thinking=None;preserve_thinking=None;
    response_format=Agent_core.Types.Off;reasoning_effort=None;cache_system_prompt=false;
    context=Agent_core.Context.create_sync ();mcp_sessions=[];working_context=None}
let checkpoint bytes = Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string "original-trace" |> require)
    ~turn_count:3 ~canonical_checkpoint_bytes:(canonical_bytes bytes) |> require
let obligation = Semantic.gate_obligation ~approval_id:"approval-original"
    ~tool_name:"tool_execute" ~input_hash:(Digestif.SHA256.(digest_string "original tool input" |> to_hex)) |> require
let channel_scope = Semantic.session_scope ["channels"; "original-channel"] |> require
let waiting = Semantic.gate_wait ~session_scope:channel_scope ~checkpoint:(checkpoint "input and effect references") ~obligations:[obligation] |> require
let preparation_source = function
  | Semantic.Agent_core reference -> Semantic.Prepared_agent_core {reference;canonical_checkpoint_bytes=canonical_bytes "input and effect references"}
  | Semantic.Official_client checkpoint -> Semantic.Prepared_official_client checkpoint
let preparation : Semantic.gate_preparation = {session_scope=channel_scope;source=preparation_source waiting.checkpoint}
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR; _} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path
let with_path f =
  let root = Filename.temp_dir "gate-wait-" "" in
  Fun.protect ~finally:(fun () -> Store.For_testing.clear_commit_fault (); remove root)
    (fun () -> f (Filename.concat root Store.database_file))
let with_store path f =
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> Store.close store |> ok) (fun () -> f store)
let claim store = Store.claim_next store ~now:2. |> ok
let admit store =
  Store.submit store ~now:1. ~operation_id:original ~source ~input |> ok |> ignore;
  match claim store with Some value -> value | None -> fail "original input not claimed"
let suspend store operation = Store.defer_direct_gate store ~now:3. ~operation_id:original
    ~execution_digest:operation.Operation.execution_digest ~waiting |> ok
let get store = match Store.get store original |> ok with Some value -> value | None -> fail "original operation lost"

let test_wait_restart_resolution decision () = with_path (fun path ->
  with_store path (fun store ->
    let operation = admit store in
    Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
    suspend store operation |> ignore;
    let before_priority = get store in
    (match Store.move_queued_to_front store ~now:4. ~operation_id:original with
     | Error (Store.Invalid_input _) -> ()
     | _ -> fail "priority bypassed an unresolved approval");
    check bool "priority refusal preserves the original approval and input" true (get store = before_priority);
    check bool "unresolved wait is not claimable" false (Store.has_claimable_queued store ~now:4. |> ok);
    check bool "no repeated waiting child" true (claim store = None);
    Store.submit store ~now:4. ~operation_id:other ~source ~input:(`String "independent work") |> ok |> ignore;
    let independent = match claim store with Some value -> value | None -> fail "independent work was blocked" in
    check bool "later independent input claims" true (Operation.Operation_id.equal other independent.operation_id);
    Store.succeed_running store ~now:5. ~operation_id:other ~outcome_ref:"independent-result" |> ok |> ignore);
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:6. |> ok |> ignore;
    check bool "complete original input survives owner restart" true ((get store).input = Some input);
    let restored = Store.direct_gate_state store ~operation_id:original |> ok in
    check bool "actual channel scope survives SQLite restart" true
      (match restored with Some state -> state.waiting.session_scope = channel_scope | None -> false);
    let wrong = Semantic.gate_obligation ~approval_id:"unrelated-approval" ~tool_name:obligation.tool_name
      ~input_hash:obligation.input_hash |> require in
    rejected (Store.resolve_direct_gate store ~now:7. ~operation_id:original
      ~resolution:{Semantic.obligation=wrong; decision});
    check bool "unrelated resolution cannot schedule original request" true (claim store = None);
    let resolution = {Semantic.obligation; decision} in
    Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
    Store.resolve_direct_gate store ~now:8. ~operation_id:original ~resolution |> ok |> ignore;
    let operation = match claim store with Some value -> value | None -> fail "exact resolution did not requeue original input" in
    check bool "same original request resumes" true (Operation.Operation_id.equal original operation.operation_id);
    let wrong_scope = Semantic.gate_wait ~session_scope:(Semantic.session_scope [] |> require)
      ~checkpoint:(match waiting.checkpoint with Semantic.Agent_core value -> value | Semantic.Official_client _ -> fail "expected Agent Core") ~obligations:[obligation] |> require in
    rejected (Store.resume_direct_gate store ~now:9. ~operation_id:original ~waiting:wrong_scope ~resolution);
    let changed = Semantic.gate_wait ~session_scope:(Semantic.session_scope [] |> Result.get_ok) ~checkpoint:(checkpoint "another invocation") ~obligations:[obligation] |> require in
    rejected (Store.resume_direct_gate store ~now:9. ~operation_id:original ~waiting:changed ~resolution);
    Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
    Store.resume_direct_gate store ~now:9. ~operation_id:original ~waiting ~resolution |> ok;
    rejected (Store.succeed_running store ~now:10. ~operation_id:original ~outcome_ref:"premature-success");
    Store.discharge_direct_gate store ~now:11. ~operation_id:original ~obligation |> ok;
    Store.succeed_running store ~now:12. ~operation_id:original ~outcome_ref:"actual-original-result" |> ok |> ignore))

let test_runtime_failure_retains_gate_obligations () = with_path (fun path -> with_store path (fun store ->
  let operation = admit store in
  suspend store operation |> ignore;
  let resolution = {Semantic.obligation; decision=Semantic.Gate_approved} in
  Store.resolve_direct_gate store ~now:4. ~operation_id:original ~resolution |> ok |> ignore;
  let operation = match claim store with Some value -> value | None -> fail "resolved original missing" in
  Store.resume_direct_gate store ~now:5. ~operation_id:original ~waiting ~resolution |> ok;
  let continuation = Semantic.runtime_retry ~not_before:None ~checkpoint:(checkpoint "replay and failed provider")
      ~assignment_id:"frozen" ~failed_runtime_id:"first" ~next_runtime_id:"alternate" ~later_runtime_ids:[] |> require in
  Store.defer_direct_runtime_retry store ~now:6. ~operation_id:original
    ~execution_digest:operation.execution_digest ~continuation |> ok |> ignore;
  check bool "runtime fallback retains exact Gate effect identity" true
    ((Store.direct_gate_obligations store ~operation_id:original |> ok) = [obligation]);
  check bool "runtime fallback retains original request" true ((get store).input = Some input)))

let test_unconfirmed_checkpoint_survives_restart () = with_path (fun path ->
  with_store path (fun store ->
    let operation = admit store in
    Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
    Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
      ~execution_digest:operation.execution_digest
      ~binding:(Semantic.gate_binding ~preparation ~approval_ids:[obligation.approval_id] ~obligations:[obligation]
        ~runtime_suffix:None |> require)
      ~diagnostic:"retained checkpoint could not be installed" |> ok |> ignore;
    check bool "checkpoint-less request is nonclaimable" true (claim store = None));
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:6. |> ok |> ignore;
    check bool "full original input survives restart" true ((get store).input = Some input);
    check bool "exact effect identity survives restart" true
      ((Store.direct_gate_obligations store ~operation_id:original |> ok) = [obligation]);
    rejected (Store.resolve_direct_gate store ~now:7. ~operation_id:original
      ~resolution:{Semantic.obligation; decision=Semantic.Gate_approved});
    check bool "approval alone cannot manufacture a checkpoint" true (claim store = None);
    Store.submit store ~now:8. ~operation_id:other ~source ~input:(`String "independent work") |> ok |> ignore;
    check bool "independent work remains claimable" true
      (match claim store with Some operation -> Operation.Operation_id.equal other operation.operation_id | None -> false)))

let test_session_scope_validation () =
  List.iter (fun components -> rejected (Semantic.session_scope components))
    [[".."]; ["channels"; "../other"]; [""]; ["."]; ["/absolute"]; ["nul\000byte"]; ["a\\b"]]

let test_fresh_gate_and_runtime_retry_restart () = with_path (fun path ->
  let reference = checkpoint "same original input completed effects and frozen runtime suffix" in
  let retry = Semantic.runtime_retry ~not_before:None ~checkpoint:reference ~assignment_id:"original-runtime-assignment"
    ~failed_runtime_id:"primary" ~next_runtime_id:"alternate" ~later_runtime_ids:["last"] |> require in
  let waiting = Semantic.gate_wait_with_runtime_retry ~checkpoint:reference ~session_scope:(Semantic.session_scope [] |> require) ~obligations:[obligation]
    ~runtime_retry:retry |> require in
  rejected (Semantic.gate_wait_with_runtime_retry ~checkpoint:(checkpoint "different input") ~session_scope:(Semantic.session_scope [] |> require)
    ~obligations:[obligation] ~runtime_retry:retry);
  with_store path (fun store ->
    let operation = admit store in
    Store.defer_direct_gate store ~now:3. ~operation_id:original ~execution_digest:operation.execution_digest
      ~waiting |> ok |> ignore;
    check bool "runtime retry cannot bypass pending Gate" true (claim store = None));
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:4. |> ok |> ignore;
    let observed = match Store.direct_gate_state store ~operation_id:original |> ok with
      | Some state -> state | None -> fail "simultaneous obligations lost on restart" in
    check bool "frozen checkpoint and runtime assignment survive restart" true
      (Semantic.equal_gate_wait waiting observed.waiting);
    check bool "original input retained" true ((get store).input=Some input);
    check bool "restart does not bypass Gate" true (claim store = None);
    let resolution = {Semantic.obligation; decision=Semantic.Gate_approved} in
    Store.resolve_direct_gate store ~now:5. ~operation_id:original ~resolution |> ok |> ignore;
    ignore (claim store);
    Store.resume_direct_gate store ~now:6. ~operation_id:original ~waiting ~resolution |> ok;
    check bool "Gate effect identity survives runtime admission" true
      ((Store.direct_gate_obligations store ~operation_id:original |> ok) = [obligation])))

let test_unbound_gate_and_runtime_survive_restart () = with_path (fun path ->
  let runtime_suffix = Semantic.runtime_suffix ~assignment_id:"frozen-original" ~failed_runtime_id:"first"
    ~next_runtime_id:"next" ~later_runtime_ids:["last"] |> require in
  let binding = Semantic.gate_binding ~preparation ~approval_ids:["producer-created-approval"] ~obligations:[]
    ~runtime_suffix:(Some runtime_suffix) |> require in
  with_store path (fun store ->
    let operation = admit store in
    Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
      ~execution_digest:operation.execution_digest ~binding ~diagnostic:"Gate authority unavailable" |> ok |> ignore);
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:4. |> ok |> ignore;
    check bool "unbound Gate and frozen suffix survive restart" true
      ((Store.direct_gate_binding store ~operation_id:original |> ok) = Some binding);
    check bool "original task attachments and channel retained" true ((get store).input=Some input);
    check bool "no model claim without binding authority" true (claim store = None)))

(* The binding, its obligations and its diagnostic come from the caller, and the
   transition rule refuses a blank diagnostic. That refusal has to read as bad
   input: [Integrity_error] is how this store says its own record is broken, and
   an owner that sees it stops trusting the database rather than the request. *)
let test_refused_binding_reads_as_input_not_corruption () = with_path (fun path ->
  let binding = Semantic.gate_binding ~preparation ~approval_ids:[obligation.approval_id]
    ~obligations:[obligation] ~runtime_suffix:None |> require in
  with_store path (fun store ->
    let operation = admit store in
    (match Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
             ~execution_digest:operation.Operation.execution_digest ~binding ~diagnostic:"" with
     | Error (Store.Invalid_input _) -> ()
     | Error error -> fail ("a refused binding reported " ^ Store.error_to_string error)
     | Ok _ -> fail "a blank diagnostic was accepted");
    check bool "the claimed operation survives a refused binding" true ((get store) = operation)))

let test_exact_source_reconciliation_after_restart () = with_path (fun path ->
  let unrecorded = Semantic.gate_binding ~preparation ~approval_ids:[obligation.approval_id]
    ~obligations:[] ~runtime_suffix:None |> require in
  let binding = Semantic.gate_binding_with_wait ~binding:unrecorded ~waiting |> require in
  with_store path (fun store ->
    let operation = admit store in
    let wrong_frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
      (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation other)) |> require in
    let native_wait = Semantic.official_client_gate_wait ~session_scope:channel_scope ~obligations:[obligation]
      ~checkpoint:{Semantic.client_kind=Semantic.Codex; runtime_id="native.fixture"; session_id="native-session";
        turn_id="native-turn"; tool_surface_sha256=String.make 64 'a'; frame=wrong_frame} |> require in
    let wrong_binding = Semantic.gate_binding
      ~preparation:{Semantic.session_scope=channel_scope;source=preparation_source native_wait.checkpoint}
      ~approval_ids:[obligation.approval_id] ~obligations:[] ~runtime_suffix:None |> require in
    let wrong_binding = Semantic.gate_binding_with_wait ~binding:wrong_binding ~waiting:native_wait |> require in
    (match Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
       ~execution_digest:operation.execution_digest ~binding:wrong_binding ~diagnostic:"wrong native scope" with
     | Error (Store.Invalid_input _) -> ()
     | Error error -> fail ("wrong scope poisoned store: " ^ Store.error_to_string error)
     | Ok _ -> fail "another operation's native scope was persisted");
    check bool "rejected binding preserves the original running operation" true
      ((get store) = operation);
    Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
      ~execution_digest:operation.execution_digest ~binding ~diagnostic:"retention fsync was not confirmed" |> ok |> ignore);
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:4. |> ok |> ignore;
    let observed = Store.direct_gate_binding store ~operation_id:original |> ok |> Option.get in
    check bool "exact source and original channel survive SQLite restart" true
      (Option.fold ~none:false ~some:(Semantic.equal_gate_wait waiting) observed.unconfirmed_wait);
    rejected (Store.reconcile_direct_gate_binding store ~now:5. ~operation_id:original
      ~binding:unrecorded ~waiting);
    let other_wait = Semantic.gate_wait ~checkpoint:(checkpoint "different bytes") ~session_scope:channel_scope
      ~obligations:[obligation] |> require in
    rejected (Store.reconcile_direct_gate_binding store ~now:5. ~operation_id:original ~binding ~waiting:other_wait);
    check bool "unproven source cannot make the original claimable" true (claim store = None);
    Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
    Store.reconcile_direct_gate_binding store ~now:6. ~operation_id:original ~binding ~waiting |> ok;
    check bool "confirmed retention alone does not bypass approval" true (claim store = None);
    Store.submit store ~now:7. ~operation_id:other ~source ~input:(`String "independent peer request") |> ok |> ignore;
    let peer = claim store |> Option.get in
    check bool "independent peer progresses during approval wait" true (Operation.Operation_id.equal peer.operation_id other);
    Store.succeed_running store ~now:8. ~operation_id:other ~outcome_ref:"peer-effect-receipt" |> ok |> ignore;
    let resolution = {Semantic.obligation; decision=Semantic.Gate_approved} in
    Store.resolve_direct_gate store ~now:9. ~operation_id:original ~resolution |> ok |> ignore;
    let resumed = claim store |> Option.get in
    check bool "same original input is resumed" true (resumed.input = Some input);
    Store.resume_direct_gate store ~now:10. ~operation_id:original ~waiting ~resolution |> ok;
    Store.discharge_direct_gate store ~now:11. ~operation_id:original ~obligation |> ok;
    Store.succeed_running store ~now:12. ~operation_id:original ~outcome_ref:"original-exact-resume" |> ok |> ignore))

let test_unprepared_source_reconciliation_after_restart () = with_path (fun path ->
  let preparation : Semantic.gate_preparation =
    {session_scope=channel_scope;source=preparation_source waiting.checkpoint} in
  let binding = Semantic.gate_binding ~preparation ~approval_ids:[obligation.approval_id]
    ~obligations:[] ~runtime_suffix:None |> require in
  with_store path (fun store ->
    let operation = admit store in
    Store.defer_direct_gate_reconciliation store ~now:3. ~operation_id:original
      ~execution_digest:operation.execution_digest ~binding ~diagnostic:"authority unavailable before source preparation"
      |> ok |> ignore);
  with_store path (fun store ->
    Store.settle_running_after_restart store ~now:4. |> ok |> ignore;
    let observed = Store.direct_gate_binding store ~operation_id:original |> ok |> Option.get in
    check bool "original preparation survives SQLite restart without a wait" true
      (observed.preparation = preparation && observed.unconfirmed_wait = None);
    let wrong_scope = Semantic.gate_wait ~session_scope:(Semantic.session_scope [] |> require)
      ~checkpoint:(checkpoint "input and effect references") ~obligations:[obligation] |> require in
    rejected (Store.reconcile_direct_gate_binding store ~now:5. ~operation_id:original ~binding:observed ~waiting:wrong_scope);
    let wrong_reference = Keeper_checkpoint_ref.create
      ~trace_id:(Keeper_id.Trace_id.of_string "another-session" |> require)
      ~turn_count:3 ~canonical_checkpoint_bytes:"input and effect references" |> require in
    let wrong_session = Semantic.gate_wait ~session_scope:channel_scope ~checkpoint:wrong_reference
      ~obligations:[obligation] |> require in
    rejected (Store.reconcile_direct_gate_binding store ~now:5. ~operation_id:original ~binding:observed ~waiting:wrong_session);
    check bool "wrong original identity cannot schedule replay" true (claim store = None);
    Store.reconcile_direct_gate_binding store ~now:6. ~operation_id:original ~binding:observed ~waiting |> ok;
    check bool "repaired source still requires approval" true (claim store = None);
    Store.resolve_direct_gate store ~now:7. ~operation_id:original
      ~resolution:{Semantic.obligation;decision=Semantic.Gate_approved} |> ok |> ignore;
    let resumed = claim store |> Option.get in
    check bool "repaired source schedules the same complete original input" true
      (Operation.Operation_id.equal original resumed.operation_id && resumed.input = Some input)))

let test_changed_preparation_bytes () =
  let source = Semantic.Prepared_agent_core {reference=checkpoint "original exact bytes";
    canonical_checkpoint_bytes="substituted bytes"} in
  rejected (Semantic.gate_binding ~preparation:{Semantic.session_scope=channel_scope;source}
    ~approval_ids:[obligation.approval_id] ~obligations:[] ~runtime_suffix:None)

let test_invalid_preparation_checkpoint () =
  List.iter (fun bytes ->
    let reference = Keeper_checkpoint_ref.create ~trace_id:(Keeper_id.Trace_id.of_string "original-trace" |> require)
      ~turn_count:3 ~canonical_checkpoint_bytes:bytes |> require in
    rejected (Semantic.gate_binding ~preparation:{Semantic.session_scope=channel_scope;
      source=Semantic.Prepared_agent_core {reference;canonical_checkpoint_bytes=bytes}}
      ~approval_ids:[obligation.approval_id] ~obligations:[] ~runtime_suffix:None))
    ["not JSON";"{}";
     (let checkpoint = Agent_core.Checkpoint.of_string (canonical_bytes "valid") |> require in
      Agent_core.Checkpoint.to_string {checkpoint with session_id="another-session"});
     (let checkpoint = Agent_core.Checkpoint.of_string (canonical_bytes "valid") |> require in
      Agent_core.Checkpoint.to_string {checkpoint with turn_count=4})]

let test_invalid_native_preparation () =
  let frame = Keeper_repetition_snapshot.admit Keeper_repetition_snapshot.empty
    (Keeper_repetition_snapshot.Fresh (Keeper_execution_scope_id.direct_operation original)) |> require in
  let valid : Semantic.official_client_checkpoint =
    {client_kind=Semantic.Codex;runtime_id="native.fixture";session_id="original-session";
     turn_id="original-turn";tool_surface_sha256=String.make 64 'a';frame} in
  List.iter (fun checkpoint ->
    rejected (Semantic.gate_binding ~preparation:{Semantic.session_scope=channel_scope;source=Semantic.Prepared_official_client checkpoint}
      ~approval_ids:[obligation.approval_id] ~obligations:[] ~runtime_suffix:None))
    [{valid with runtime_id=""};{valid with session_id=" "};{valid with turn_id=""};
     {valid with tool_surface_sha256="invalid"};{valid with frame=Keeper_repetition_snapshot.empty}]

let () = run "direct Gate waiting" ["journal", [
  test_case "hash-valid pending payload must decode with its original identity" `Quick test_invalid_preparation_checkpoint;
  test_case "pending checkpoint bytes must match their exact reference" `Quick test_changed_preparation_bytes;
  test_case "native preparation rejects incomplete original identity" `Quick test_invalid_native_preparation;
  test_case "unprepared source recovers after restart with original session authority" `Quick test_unprepared_source_reconciliation_after_restart;
  test_case "a refused Gate binding is bad input, not a broken store" `Quick test_refused_binding_reads_as_input_not_corruption;
  test_case "exact unconfirmed source is reconciled by CAS after restart" `Quick test_exact_source_reconciliation_after_restart;
  test_case "unbound Gate identity and runtime suffix survive restart" `Quick test_unbound_gate_and_runtime_survive_restart;
  test_case "session scope rejects traversal and ambiguous components" `Quick test_session_scope_validation;
  test_case "fresh Gate and frozen runtime retry survive restart together" `Quick test_fresh_gate_and_runtime_retry_restart;
  test_case "unconfirmed checkpoint preserves input and effects across restart" `Quick test_unconfirmed_checkpoint_survives_restart;
  test_case "approval resumes same request after independent work and restart" `Quick (test_wait_restart_resolution Semantic.Gate_approved);
  test_case "denial remains explicit and cannot imply task success" `Quick (test_wait_restart_resolution (Semantic.Gate_denied "operator declined"));
  test_case "runtime fallback retains Gate effect references" `Quick test_runtime_failure_retains_gate_obligations]]
