open Alcotest
module Store = Keeper_chat_operation_store
module Operation = Keeper_chat_operation
module Native = Keeper_native_call
module Agent = Agent_core.Agent
let ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let value = function Ok value -> value | Error detail -> fail detail
let rejected label = function Ok _ -> fail label | Error _ -> ()
let call_id = "019a0010-1000-7000-8000-000000000001"
let next_call_id = "019a0010-1000-7000-8000-000000000002"
let operation_id = Operation.Operation_id.of_string "native-owned-operation" |> value
let locator call_id = Agent.execution_locator_of_yojson
  (`Assoc ["version", `Int 1; "run_id", `String ("execution-run-" ^ call_id)]) |> value
let checkpoint turn_count =
  Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string "native-trace" |> value)
    ~turn_count ~canonical_checkpoint_bytes:(string_of_int turn_count)
  |> function Ok reference -> reference | Error _ -> fail "checkpoint fixture"
let make_call ?(id=call_id) operation = Native.create ~call_id:id ~runtime_id:"native.primary"
  ~operation_digest:operation.Operation.execution_digest
  ~api:(Native.New_input {seed_message_count=3}) ~seed_checkpoint:(checkpoint 1) ~locator:(locator id) |> value
let with_store f =
  let directory = Filename.temp_dir "native-call-owner" "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result)) (fun () ->
    ignore (Store.submit store ~now:1. ~operation_id
      ~source:(`Assoc ["kind", `String "fixture"])
      ~input:(`Assoc ["text", `String "original input"; "metadata", `Assoc ["speaker", `String "operator"]]) |> ok);
    let operation = match Store.claim_next store ~now:2. |> ok with
      | Some operation -> operation | None -> fail "no operation claimed" in
    f path store operation)
let mutate store operation change = Store.update_direct_native_call store ~now:3. ~operation_id
  ~execution_digest:operation.Operation.execution_digest change
let read store = Store.direct_native_call store ~operation_id |> ok
let bind store operation call = mutate store operation (Native.Bind {observed=Native.No_native_call; call}) |> ok
let with_reopened path store f =
  Store.close store |> ok;
  let reopened = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close reopened : (unit, Store.error) result)) (fun () -> f reopened)
let disposition recovery = {Agent.outcome=Agent.Terminal_failed; recovery}
let terminal store operation recovery =
  mutate store operation (Native.Terminal {call_id; disposition=disposition recovery}) |> ok

let test_active_restart_preserves_seed_and_exact_identity () = with_store @@ fun path store operation ->
  let call = make_call operation in
  bind store operation call;
  mutate store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2}) |> ok;
  let before = read store in
  with_reopened path store @@ fun reopened ->
  check int "active call is not marked interrupted" 0 (List.length (Store.settle_running_after_restart reopened ~now:4. |> ok));
  let resumed = match Store.claim_next reopened ~now:5. |> ok with
    | Some operation -> operation | None -> fail "active operation did not resume" in
  check bool "same operation" true (Operation.Operation_id.equal resumed.operation_id operation.operation_id);
  check bool "same input and metadata" true (resumed.input = operation.input);
  check bool "same durable call" true (Native.equal_state before (read reopened));
  let call = match read reopened with Native.Active call -> call | _ -> fail "lost active call" in
  check bool "original seed is immutable" true (Keeper_checkpoint_ref.equal call.seed_checkpoint (checkpoint 1));
  check bool "latest checkpoint retained" true (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 2));
  mutate reopened resumed (Native.Bind {observed=before; call}) |> ok

let test_terminal_restart_never_dispatches () = with_store @@ fun path store operation ->
  bind store operation (make_call operation);
  terminal store operation Agent.Retire;
  let before = read store in
  with_reopened path store @@ fun reopened ->
  check int "terminal call lacks an Owner receipt" 1 (List.length (Store.settle_running_after_restart reopened ~now:4. |> ok));
  check bool "terminal journal never dispatched" true (Option.is_none (Store.claim_next reopened ~now:5. |> ok));
  check bool "terminal evidence survives" true (Native.equal_state before (read reopened));
  (match Store.get reopened operation_id |> ok with
   | Some {Operation.state=Operation.Failed {failure={kind=Operation.Interrupted_by_restart; _}; _}; _} -> ()
   | _ -> fail "terminal call inferred completion instead of interruption");
  match Store.inspect_outstanding ~path |> ok with
  | Store.Stored_operations {semantic_executions=[execution]; _} ->
    check int "unacknowledged checkpoint refs retained" 2
      (List.length (Keeper_semantic_execution.checkpoint_references execution))
  | _ -> fail "unacknowledged native receipt excluded from retention"

let test_unknown_effect_survives_failure_and_rejects_retry () = with_store @@ fun path store operation ->
  bind store operation (make_call operation);
  terminal store operation (Agent.Operator_repair_required Agent.Effect_outcome_unknown);
  let observed = read store in
  rejected "unknown effect replaced" (mutate store operation (Native.Bind {observed; call=make_call ~id:next_call_id operation}));
  rejected "unknown effect completed" (Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"not-evidence");
  ignore (Store.fail_running store ~now:4. ~operation_id ~kind:Operation.Turn_exception
    ~detail:"effect outcome unknown" ~outcome_ref:None |> ok);
  check bool "failure retains unknown disposition" true (Native.equal_state observed (read store));
  with_reopened path store @@ fun reopened ->
  check bool "unknown persists across reopen" true (Native.equal_state observed (read reopened));
  check bool "failed operation is not replayed" true (Option.is_none (Store.claim_next reopened ~now:5. |> ok))

let test_retired_replacement_is_atomic_and_normal_receipt_acknowledges () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  terminal store operation Agent.Retire;
  let observed = read store in
  let call = make_call ~id:next_call_id operation in
  rejected "stale terminal replacement" (mutate store operation (Native.Bind {observed=Native.No_native_call; call}));
  check bool "stale write preserves terminal evidence" true (Native.equal_state observed (read store));
  mutate store operation (Native.Bind {observed; call}) |> ok;
  mutate store operation (Native.Terminal {call_id=next_call_id; disposition={Agent.outcome=Agent.Terminal_succeeded; recovery=Agent.Retire}}) |> ok;
  ignore (Store.succeed_running store ~now:5. ~operation_id ~outcome_ref:"verified-owner-receipt" |> ok);
  check bool "Owner receipt transaction retires locator" true (Native.equal_state Native.No_native_call (read store))

let test_stale_checkpoint_digest_and_commit_readback () = with_store @@ fun _path store operation ->
  let call = make_call operation in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  bind store operation call;
  mutate store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2}) |> ok;
  rejected "stale checkpoint accepted" (mutate store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 3}));
  rejected "wrong operation digest accepted"
    (Store.update_direct_native_call store ~now:4. ~operation_id ~execution_digest:(String.make 64 'a')
       (Native.Terminal {call_id; disposition=disposition Agent.Retire}));
  rejected "active scope completed without terminal receipt" (Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"missing-core-receipt");
  match read store with
  | Native.Active current -> check bool "failed writes preserve latest checkpoint" true (Keeper_checkpoint_ref.equal current.checkpoint (checkpoint 2))
  | _ -> fail "failed writes changed native call state"

let test_checkpoint_deferral_acknowledges_only_committed_retirement () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  terminal store operation Agent.Retire;
  let before = read store in
  let defer () = Store.defer_direct_checkpoint store ~now:4. ~operation_id
    ~execution_digest:operation.Operation.execution_digest
    ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 1)) in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  rejected "failed deferral was acknowledged" (defer ());
  check bool "failed deferral retains native terminal" true (Native.equal_state before (read store));
  ignore (defer () |> ok);
  check bool "committed checkpoint owns continuation" true (Native.equal_state Native.No_native_call (read store));
  check bool "same operation is queued" true
    (match Store.get store operation_id |> ok with Some {Operation.state=Operation.Queued; _} -> true | _ -> false)

let () = run "native-call-owner-store" ["recovery", [
  test_case "active restart preserves exact admission" `Quick test_active_restart_preserves_seed_and_exact_identity;
  test_case "terminal restart retains incomplete receipt without dispatch" `Quick test_terminal_restart_never_dispatches;
  test_case "unknown effect survives settlement and rejects retry" `Quick test_unknown_effect_survives_failure_and_rejects_retry;
  test_case "retired call replacement and Owner acknowledgement" `Quick test_retired_replacement_is_atomic_and_normal_receipt_acknowledges;
  test_case "checkpoint deferral acknowledges only committed retirement" `Quick test_checkpoint_deferral_acknowledges_only_committed_retirement;
  test_case "checkpoint CAS, digest and commit readback" `Quick test_stale_checkpoint_digest_and_commit_readback]]
