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
let make_call ?(id=call_id) ?(seed=1) operation = Native.create ~call_id:id ~runtime_id:"native.primary"
  ~operation_digest:operation.Operation.execution_digest
  ~api:(Native.New_input {seed_message_count=3}) ~seed_checkpoint:(checkpoint seed) ~locator:(locator id) |> value
let submit store operation_id text =
  ignore (Store.submit store ~now:1. ~operation_id
    ~source:(`Assoc ["kind", `String "fixture"])
    ~input:(`Assoc ["text", `String text; "metadata", `Assoc ["speaker", `String "operator"]]) |> ok)
let claim store = match Store.claim_next store ~now:2. |> ok with
  | Some operation -> operation | None -> fail "no operation claimed"
let with_store ?(before = fun _store -> ()) f =
  let directory = Filename.temp_dir "native-call-owner" "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result)) (fun () ->
    before store;
    submit store operation_id "original input";
    let operation = claim store in
    check bool "the native operation is claimed" true
      (Operation.Operation_id.equal operation.operation_id operation_id);
    f path store operation)
let mutate store operation change = Store.update_direct_native_call store ~now:3. ~operation_id
  ~execution_digest:operation.Operation.execution_digest change
let commit store operation change = ignore (mutate store operation change |> ok : Keeper_checkpoint_ref.t list)
let read store = Store.direct_native_call store ~operation_id |> ok
let bind store operation call = commit store operation (Native.Bind {observed=Native.No_native_call; call})
let with_reopened path store f =
  Store.close store |> ok;
  let reopened = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close reopened : (unit, Store.error) result)) (fun () -> f reopened)
let disposition recovery = {Agent.outcome=Agent.Terminal_failed; recovery}
let terminal store operation recovery =
  commit store operation (Native.Terminal {call_id; disposition=disposition recovery})

let test_active_restart_preserves_seed_and_exact_identity () = with_store @@ fun path store operation ->
  let call = make_call operation in
  bind store operation call;
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2});
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
  commit reopened resumed (Native.Bind {observed=before; call})

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
  commit store operation (Native.Bind {observed; call});
  commit store operation (Native.Terminal {call_id=next_call_id; disposition={Agent.outcome=Agent.Terminal_succeeded; recovery=Agent.Retire}});
  ignore (Store.succeed_running store ~now:5. ~operation_id ~outcome_ref:"verified-owner-receipt" |> ok);
  check bool "Owner receipt transaction retires locator" true (Native.equal_state Native.No_native_call (read store))

let test_stale_checkpoint_digest_and_commit_readback () = with_store @@ fun _path store operation ->
  let call = make_call operation in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  bind store operation call;
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2});
  rejected "stale checkpoint accepted" (mutate store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 3}));
  rejected "wrong operation digest accepted"
    (Store.update_direct_native_call store ~now:4. ~operation_id ~execution_digest:(String.make 64 'a')
       (Native.Terminal {call_id; disposition=disposition Agent.Retire}));
  (match Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"missing-core-receipt" with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "active scope completed without terminal receipt");
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

let still_running store =
  match Store.get store operation_id |> ok with
  | Some {Operation.state=Operation.Running _; _} -> true
  | Some _ | None -> false

let settle_failed store ~now =
  Store.fail_running store ~now ~operation_id ~kind:Operation.Turn_cancelled
    ~detail:"operator interrupted the turn" ~outcome_ref:None

let test_settling_an_active_call_is_a_precondition_not_corruption () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  let before = read store in
  (match settle_failed store ~now:4. with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "failing an active call was not refused as unsettled");
  (match Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"x" with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "completing an active call was not refused as unsettled");
  (match Store.defer_direct_checkpoint store ~now:4. ~operation_id
           ~execution_digest:operation.Operation.execution_digest
           ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 1)) with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "suspending an active call was not refused as unsettled");
  check bool "refusals keep the operation running" true (still_running store);
  check bool "refusals keep the active call" true (Native.equal_state before (read store));
  terminal store operation Agent.Retire;
  (match settle_failed store ~now:5. with
   | Ok {Operation.state=Operation.Failed _; _} -> ()
   | Ok _ | Error _ -> fail "the recorded disposition did not release settlement")

let test_unknown_effect_receipt_lets_the_operation_fail_but_not_complete () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  terminal store operation (Agent.Operator_repair_required Agent.Effect_outcome_unknown);
  (match Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"x" with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "an unknown effect completed, or its refusal was not a precondition");
  (match Store.defer_direct_checkpoint store ~now:4. ~operation_id
           ~execution_digest:operation.Operation.execution_digest
           ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 1)) with
   | Error Store.Native_call_unsettled -> ()
   | Ok _ | Error _ -> fail "an unknown effect resumed through another continuation");
  (match settle_failed store ~now:5. with
   | Ok {Operation.state=Operation.Failed _; _} -> ()
   | Ok _ | Error _ -> fail "an unknown effect could not fail the operation");
  (match read store with
   | Native.Terminal_unacknowledged (_, {Agent.recovery=Agent.Operator_repair_required Agent.Effect_outcome_unknown; _}) -> ()
   | Native.No_native_call | Native.Active _ | Native.Terminal_unacknowledged _ ->
     fail "the unknown-effect receipt was not preserved")

let shas = List.map (fun (reference : Keeper_checkpoint_ref.t) -> reference.sha256)
let released label expected result = check (list string) label (shas expected) (shas (ok result))
let advance store operation ~observed ~next =
  mutate store operation (Native.Checkpoint {call_id; observed=checkpoint observed; checkpoint=checkpoint next})

let test_a_commit_releases_what_it_stopped_naming () = with_store @@ fun _path store operation ->
  released "a first bind releases nothing" []
    (mutate store operation (Native.Bind {observed=Native.No_native_call; call=make_call operation}));
  released "advancing off the seed keeps the seed" [] (advance store operation ~observed:1 ~next:2);
  released "the superseded checkpoint is released" [checkpoint 2] (advance store operation ~observed:2 ~next:3);
  released "committing the current checkpoint again releases nothing" []
    (advance store operation ~observed:3 ~next:3);
  released "a terminal receipt keeps both references" []
    (mutate store operation (Native.Terminal {call_id; disposition=disposition Agent.Retire}));
  let observed = read store in
  released "the next call releases the retired call's seed and latest checkpoint"
    [checkpoint 1; checkpoint 3]
    (mutate store operation (Native.Bind {observed; call=make_call ~id:next_call_id ~seed:4 operation}))

let test_a_replacement_seeded_from_the_retired_checkpoint_keeps_it () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2});
  terminal store operation Agent.Retire;
  let observed = read store in
  released "only the retired seed is released" [checkpoint 1]
    (mutate store operation (Native.Bind {observed; call=make_call ~id:next_call_id ~seed:2 operation}))

(* Another operation of the same keeper waits on a Gate with a checkpoint whose
   bytes, and so sha256, equal one the native call supersedes. That file is
   still read by the waiting operation and must not be released. *)
let gate_waiting_on reference store =
  let gate_operation_id = Operation.Operation_id.of_string "native-gate-operation" |> value in
  submit store gate_operation_id "approve first";
  let gate_operation = claim store in
  let obligation = Keeper_semantic_execution.gate_obligation ~approval_id:"approval"
      ~tool_name:"tool_execute" ~input_hash:(Digestif.SHA256.(digest_string "tool input" |> to_hex))
    |> value in
  let waiting = Keeper_semantic_execution.gate_wait ~checkpoint:reference
      ~session_scope:(Keeper_semantic_execution.session_scope [] |> value) ~obligations:[obligation]
    |> value in
  ignore (Store.defer_direct_gate store ~now:1.5 ~operation_id:gate_operation_id
            ~execution_digest:gate_operation.Operation.execution_digest ~waiting |> ok)

let test_a_reference_another_execution_names_is_kept () =
  with_store ~before:(gate_waiting_on (checkpoint 2)) @@ fun _path store operation ->
  bind store operation (make_call operation);
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2});
  released "a checkpoint the Gate wait names is kept" [] (advance store operation ~observed:2 ~next:3);
  released "the next superseded checkpoint is released" [checkpoint 3]
    (advance store operation ~observed:3 ~next:4)

let test_only_a_confirmed_commit_releases () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint 1; checkpoint=checkpoint 2});
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  rejected "an uncommitted advance was reported" (advance store operation ~observed:2 ~next:3);
  (match read store with
   | Native.Active call ->
     check bool "the uncommitted advance still names its source" true
       (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 2))
   | Native.No_native_call | Native.Terminal_unacknowledged _ -> fail "failed commit changed the call");
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  released "a commit the readback confirms releases its superseded checkpoint" [checkpoint 2]
    (advance store operation ~observed:2 ~next:3)

let () = run "native-call-owner-store" ["recovery", [
  test_case "active restart preserves exact admission" `Quick test_active_restart_preserves_seed_and_exact_identity;
  test_case "terminal restart retains incomplete receipt without dispatch" `Quick test_terminal_restart_never_dispatches;
  test_case "unknown effect survives settlement and rejects retry" `Quick test_unknown_effect_survives_failure_and_rejects_retry;
  test_case "settling an active call is a precondition, not corruption" `Quick test_settling_an_active_call_is_a_precondition_not_corruption;
  test_case "unknown-effect receipt lets the operation fail but not complete" `Quick test_unknown_effect_receipt_lets_the_operation_fail_but_not_complete;
  test_case "retired call replacement and Owner acknowledgement" `Quick test_retired_replacement_is_atomic_and_normal_receipt_acknowledges;
  test_case "checkpoint deferral acknowledges only committed retirement" `Quick test_checkpoint_deferral_acknowledges_only_committed_retirement;
  test_case "checkpoint CAS, digest and commit readback" `Quick test_stale_checkpoint_digest_and_commit_readback];
  "checkpoint release", [
  test_case "a commit releases what it stopped naming" `Quick test_a_commit_releases_what_it_stopped_naming;
  test_case "a replacement seeded from the retired checkpoint keeps it" `Quick
    test_a_replacement_seeded_from_the_retired_checkpoint_keeps_it;
  test_case "a reference another execution names is kept" `Quick test_a_reference_another_execution_names_is_kept;
  test_case "only a confirmed commit releases" `Quick test_only_a_confirmed_commit_releases]]
