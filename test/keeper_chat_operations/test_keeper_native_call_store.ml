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
let checkpoint_of_bytes ~turn_count bytes =
  Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string "native-trace" |> value)
    ~turn_count ~canonical_checkpoint_bytes:(string_of_int bytes)
  |> function Ok reference -> reference | Error _ -> fail "checkpoint fixture"
let checkpoint turn_count = checkpoint_of_bytes ~turn_count turn_count
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
let commit store operation change = mutate store operation change |> ok
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
let released label expected store =
  check (list string) label (shas expected)
    (Store.take_released_checkpoints store |> List.map Store.released_reference |> shas)
let advance store operation ~observed ~next =
  commit store operation (Native.Checkpoint {call_id; observed=checkpoint observed; checkpoint=checkpoint next})
let retired_after_advancing store operation =
  bind store operation (make_call operation);
  advance store operation ~observed:1 ~next:2;
  terminal store operation Agent.Retire;
  released "the call so far released nothing" [] store

let test_a_native_commit_releases_what_it_stopped_naming () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  released "a first bind releases nothing" [] store;
  advance store operation ~observed:1 ~next:2;
  released "advancing off the seed keeps the seed" [] store;
  advance store operation ~observed:2 ~next:3;
  released "the superseded checkpoint is released" [checkpoint 2] store;
  released "a release is handed over once" [] store;
  advance store operation ~observed:3 ~next:3;
  released "committing the current checkpoint again releases nothing" [] store;
  terminal store operation Agent.Retire;
  released "a terminal receipt keeps both references" [] store;
  commit store operation (Native.Bind {observed=read store; call=make_call ~id:next_call_id ~seed:4 operation});
  released "the next call releases the retired call's seed and latest checkpoint"
    [checkpoint 1; checkpoint 3] store

let test_a_replacement_seeded_from_the_retired_checkpoint_keeps_it () = with_store @@ fun _path store operation ->
  retired_after_advancing store operation;
  commit store operation (Native.Bind {observed=read store; call=make_call ~id:next_call_id ~seed:2 operation});
  released "only the retired seed is released" [checkpoint 1] store

let test_settlement_releases_the_retired_call () = with_store @@ fun _path store operation ->
  retired_after_advancing store operation;
  ignore (Store.succeed_running store ~now:4. ~operation_id ~outcome_ref:"owner-receipt" |> ok);
  released "acknowledging the receipt releases its seed and latest checkpoint"
    [checkpoint 1; checkpoint 2] store

let test_failure_settlement_releases_the_retired_call () = with_store @@ fun _path store operation ->
  retired_after_advancing store operation;
  ignore (settle_failed store ~now:4. |> ok);
  released "a failed operation releases its retired call" [checkpoint 1; checkpoint 2] store

(* A cooperative yield commits the canonical checkpoint and retires the native
   call in one transaction. Here the canonical checkpoint has the bytes of the
   call's latest one, so that file is still read and only the seed goes. *)
let test_a_suspend_keeps_the_checkpoint_it_names () = with_store @@ fun _path store operation ->
  retired_after_advancing store operation;
  ignore (Store.defer_direct_checkpoint store ~now:4. ~operation_id
            ~execution_digest:operation.Operation.execution_digest
            ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 2)) |> ok);
  released "only the seed is released" [checkpoint 1] store;
  let resumed = claim store in
  check bool "the deferred operation resumes" true
    (Operation.Operation_id.equal resumed.operation_id operation_id);
  Store.resume_direct_checkpoint store ~now:5. ~operation_id
    ~observed:(Keeper_semantic_execution.Agent_core (checkpoint 2)) |> ok;
  released "resuming releases the checkpoint the suspension named" [checkpoint 2] store

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
  let waiting = Keeper_semantic_execution.gate_wait ~checkpoint:reference ~obligations:[obligation]
    |> value in
  ignore (Store.defer_direct_gate store ~now:1.5 ~operation_id:gate_operation_id
            ~execution_digest:gate_operation.Operation.execution_digest ~waiting |> ok);
  ignore (Store.take_released_checkpoints store : Store.released_checkpoint list)

let test_a_reference_another_execution_names_is_kept () =
  with_store ~before:(gate_waiting_on (checkpoint 2)) @@ fun _path store operation ->
  bind store operation (make_call operation);
  advance store operation ~observed:1 ~next:2;
  advance store operation ~observed:2 ~next:3;
  released "a checkpoint the Gate wait names is kept" [] store;
  advance store operation ~observed:3 ~next:4;
  released "the next superseded checkpoint is released" [checkpoint 3] store

let test_only_a_committed_transaction_releases () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  advance store operation ~observed:1 ~next:2;
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  rejected "an uncommitted advance was reported"
    (mutate store operation (Native.Checkpoint {call_id; observed=checkpoint 2; checkpoint=checkpoint 3}));
  released "a rolled-back transaction releases nothing" [] store;
  (match read store with
   | Native.Active call ->
     check bool "the rolled-back advance still names its source" true
       (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 2))
   | Native.No_native_call | Native.Terminal_unacknowledged _ -> fail "failed commit changed the call");
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  advance store operation ~observed:2 ~next:3;
  released "an uncertain commit releases nothing, even once readback confirms it" [] store;
  advance store operation ~observed:3 ~next:4;
  released "the next commit releases only what it stopped naming" [checkpoint 3] store

(* A restart settles a call that had no Owner receipt but keeps the receipt,
   so the settled execution still names the call's checkpoints. A later
   operation superseding a checkpoint with the same bytes must keep it. *)
let test_a_settled_execution_with_a_receipt_keeps_its_checkpoints () =
  let directory = Filename.temp_dir "native-call-owner" "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result)) (fun () ->
    submit store operation_id "interrupted input";
    let operation = claim store in
    bind store operation (make_call operation);
    advance store operation ~observed:1 ~next:2;
    terminal store operation Agent.Retire;
    ignore (Store.settle_running_after_restart store ~now:4. |> ok : Operation.t list);
    released "a restart that keeps the receipt releases nothing" [] store;
    let later_id = Operation.Operation_id.of_string "native-later-operation" |> value in
    submit store later_id "later input";
    let later = claim store in
    let later_call = Native.create ~call_id:next_call_id ~runtime_id:"native.primary"
        ~operation_digest:later.Operation.execution_digest
        ~api:(Native.New_input {seed_message_count=3}) ~seed_checkpoint:(checkpoint 5)
        ~locator:(locator next_call_id) |> value in
    let later_commit change = Store.update_direct_native_call store ~now:5. ~operation_id:later_id
        ~execution_digest:later.Operation.execution_digest change |> ok in
    later_commit (Native.Bind {observed=Native.No_native_call; call=later_call});
    later_commit (Native.Checkpoint {call_id=next_call_id; observed=checkpoint 5; checkpoint=checkpoint 6});
    (* The bytes of the interrupted call's latest checkpoint, at a later turn. *)
    let same_bytes = checkpoint_of_bytes ~turn_count:6 2 in
    later_commit (Native.Checkpoint {call_id=next_call_id; observed=checkpoint 6; checkpoint=same_bytes});
    released "the later call releases its own superseded checkpoint" [checkpoint 6] store;
    later_commit (Native.Checkpoint {call_id=next_call_id; observed=same_bytes; checkpoint=checkpoint 7});
    released "a checkpoint the settled receipt names is kept" [] store)

(* The release reads only the rows SQL lets through. On a store holding every
   kind of row, that selection is exactly what the startup sweep's inspection
   keeps after decoding everything. *)
let test_the_release_selection_matches_the_sweep () =
  let directory = Filename.temp_dir "native-call-owner" "" in
  let path = Filename.concat directory Store.For_testing.database_file in
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> ignore (Store.close store : (unit, Store.error) result)) (fun () ->
    let id name = Operation.Operation_id.of_string name |> value in
    gate_waiting_on (checkpoint 9) store;
    let cancelled = id "native-cancelled-operation" in
    submit store cancelled "cancel me";
    let operation = claim store in
    ignore (Store.defer_direct_checkpoint store ~now:2. ~operation_id:cancelled
              ~execution_digest:operation.Operation.execution_digest
              ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 8)) |> ok);
    ignore (Store.cancel_queued store ~now:2.5 ~operation_id:cancelled |> ok);
    let completed = id "native-completed-operation" in
    submit store completed "complete me";
    let operation = claim store in
    let call = Native.create ~call_id ~runtime_id:"native.primary"
        ~operation_digest:operation.Operation.execution_digest
        ~api:(Native.New_input {seed_message_count=3}) ~seed_checkpoint:(checkpoint 1)
        ~locator:(locator call_id) |> value in
    let commit_to operation_id change = Store.update_direct_native_call store ~now:3. ~operation_id
        ~execution_digest:operation.Operation.execution_digest change |> ok in
    commit_to completed (Native.Bind {observed=Native.No_native_call; call});
    commit_to completed (Native.Terminal {call_id; disposition=disposition Agent.Retire});
    ignore (Store.succeed_running store ~now:4. ~operation_id:completed ~outcome_ref:"done" |> ok);
    let interrupted = id "native-interrupted-operation" in
    submit store interrupted "interrupt me";
    let operation = claim store in
    let call = Native.create ~call_id:next_call_id ~runtime_id:"native.primary"
        ~operation_digest:operation.Operation.execution_digest
        ~api:(Native.New_input {seed_message_count=3}) ~seed_checkpoint:(checkpoint 3)
        ~locator:(locator next_call_id) |> value in
    let commit change = Store.update_direct_native_call store ~now:5. ~operation_id:interrupted
        ~execution_digest:operation.Operation.execution_digest change |> ok in
    commit (Native.Bind {observed=Native.No_native_call; call});
    commit (Native.Terminal {call_id=next_call_id; disposition=disposition Agent.Retire});
    ignore (Store.settle_running_after_restart store ~now:6. |> ok : Operation.t list);
    let suspended = id "native-suspended-operation" in
    submit store suspended "suspend me";
    let operation = claim store in
    ignore (Store.defer_direct_checkpoint store ~now:7. ~operation_id:suspended
              ~execution_digest:operation.Operation.execution_digest
              ~checkpoint:(Keeper_semantic_execution.Agent_core (checkpoint 4)) |> ok);
    let ids executions =
      List.map (fun (execution : Keeper_semantic_execution.t) ->
          Yojson.Safe.to_string (Keeper_execution_scope_id.to_json execution.id)) executions
      |> List.sort String.compare in
    let selected = Store.For_testing.owning_semantic_executions store |> ok in
    let swept = match Store.inspect_outstanding ~path |> ok with
      | Store.Stored_operations {semantic_executions; _} -> semantic_executions
      | Store.Missing_store -> fail "the store is missing" in
    let all = match Store.inspect_durable_records ~path |> ok with
      | Store.Stored_durable_records {semantic_executions; _} -> semantic_executions
      | Store.Missing_durable_store -> fail "the store is missing" in
    check int "every kind of row is present" 5 (List.length all);
    check (list string) "the release selects what the sweep keeps" (ids swept) (ids selected);
    check int "the gate wait, the receipt kept by the restart and the suspension" 3
      (List.length selected))

let input_updated = function
  | Store.Input_checkpoint_updated -> ()
  | Store.Input_checkpoint_source_changed _ -> fail "input checkpoint source unexpectedly changed"
let current_input store = Store.input_checkpoint store
  ~trace_id:(Keeper_id.Trace_id.of_string "native-trace" |> value) |> ok
let check_input label expected store =
  check bool label true (Option.equal Keeper_checkpoint_ref.equal expected (current_input store))
let advance_input store operation ~observed ~observed_input checkpoint =
  Store.update_direct_input_checkpoint store ~now:4. ~operation_id
    ~execution_digest:operation.Operation.execution_digest ~call_id ~observed ~observed_input ~checkpoint

let test_input_owner_survives_retirement_and_reopen () = with_store @@ fun path store operation ->
  bind store operation (make_call operation);
  advance_input store operation ~observed:(checkpoint 1) ~observed_input:None (checkpoint 2)
    |> ok |> input_updated;
  terminal store operation Agent.Retire;
  ignore (Store.succeed_running store ~now:5. ~operation_id ~outcome_ref:"input-pause-receipt" |> ok);
  let terminal_row = Store.get store operation_id |> ok in
  check_input "input owner remains after native retirement" (Some (checkpoint 2)) store;
  check bool "native call is retired" true (Native.equal_state Native.No_native_call (read store));
  (match Store.inspect_outstanding ~path |> ok with
   | Store.Stored_operations {input_checkpoints=[reference]; semantic_executions=[]; chat_operations=[]} ->
     check bool "settled input still keeps its exact checkpoint live" true
       (Keeper_checkpoint_ref.equal reference (checkpoint 2))
   | Store.Stored_operations _ | Missing_store -> fail "input lifetime was coupled to operation settlement");
  with_reopened path store @@ fun reopened ->
  check_input "input ownership survives restart" (Some (checkpoint 2)) reopened;
  Store.update_input_checkpoint reopened ~observed:(Some (checkpoint 2)) ~checkpoint:(checkpoint 3)
    |> ok |> input_updated;
  check_input "consumption can advance after terminal operation" (Some (checkpoint 3)) reopened;
  check bool "input update never changes immutable terminal result" true
    (terminal_row = (Store.get reopened operation_id |> ok));
  match Store.update_input_checkpoint reopened ~observed:(Some (checkpoint 2)) ~checkpoint:(checkpoint 4) |> ok with
  | Store.Input_checkpoint_source_changed (Some current) ->
    check bool "stale input cannot resurrect after a new observation" true
      (Keeper_checkpoint_ref.equal current (checkpoint 3))
  | Input_checkpoint_updated | Input_checkpoint_source_changed None -> fail "stale input was admitted"

let test_input_and_native_checkpoint_commit_atomically () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  let advance () = advance_input store operation ~observed:(checkpoint 1) ~observed_input:None (checkpoint 2) in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  rejected "precommit failure was hidden" (advance ());
  check_input "failed commit installs no input owner" None store;
  (match read store with Native.Active call ->
    check bool "failed commit does not advance native checkpoint" true
      (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 1))
   | No_native_call | Terminal_unacknowledged _ -> fail "native authority was lost");
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  rejected "uncertain input commit was claimed confirmed" (advance ());
  check_input "uncertain commit can have installed actual input owner" (Some (checkpoint 2)) store;
  (match read store with Native.Active call ->
    check bool "native ref and input owner advance together" true
      (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 2))
   | No_native_call | Terminal_unacknowledged _ -> fail "native authority was lost");
  check int "uncertain transaction releases no files" 0 (List.length (Store.take_released_checkpoints store));
  (match advance_input store operation ~observed:(checkpoint 2) ~observed_input:None (checkpoint 3) |> ok with
   | Store.Input_checkpoint_source_changed (Some actual) ->
     check bool "stale producer gets actual input owner" true (Keeper_checkpoint_ref.equal actual (checkpoint 2))
   | Input_checkpoint_updated | Input_checkpoint_source_changed None -> fail "stale input source was accepted");
  check_input "stale producer leaves input ref unchanged" (Some (checkpoint 2)) store;
  (match read store with Native.Active call ->
    check bool "stale input predecessor leaves native ref unchanged" true
      (Keeper_checkpoint_ref.equal call.checkpoint (checkpoint 2))
   | No_native_call | Terminal_unacknowledged _ -> fail "native authority was lost")

let test_input_retention_shares_native_liveness () = with_store @@ fun _path store operation ->
  bind store operation (make_call operation);
  Store.update_input_checkpoint store ~observed:None ~checkpoint:(checkpoint 1) |> ok |> input_updated;
  commit store operation (Native.Checkpoint {call_id;observed=checkpoint 1;checkpoint=checkpoint 2});
  terminal store operation Agent.Retire;
  ignore (Store.succeed_running store ~now:5. ~operation_id ~outcome_ref:"settled" |> ok);
  let released = Store.take_released_checkpoints store
    |> List.map Store.released_reference in
  check bool "terminal native checkpoint is released" true
    (List.exists (Keeper_checkpoint_ref.equal (checkpoint 2)) released);
  check bool "input owner protects a retired native seed" false
    (List.exists (Keeper_checkpoint_ref.equal (checkpoint 1)) released);
  Store.update_input_checkpoint store ~observed:(Some (checkpoint 1)) ~checkpoint:(checkpoint 3)
    |> ok |> input_updated;
  let released = Store.take_released_checkpoints store |> List.map Store.released_reference in
  check bool "superseded input ref releases after confirmed commit" true
    (List.exists (Keeper_checkpoint_ref.equal (checkpoint 1)) released)

let test_input_identity_is_not_an_ordinal () = with_store @@ fun _path store _operation ->
  let first = checkpoint_of_bytes ~turn_count:4 40 in
  let same_turn = checkpoint_of_bytes ~turn_count:4 41 in
  Store.update_input_checkpoint store ~observed:None ~checkpoint:first |> ok |> input_updated;
  Store.update_input_checkpoint store ~observed:(Some first) ~checkpoint:same_turn |> ok |> input_updated;
  (match Store.update_input_checkpoint store ~observed:(Some first) ~checkpoint:(checkpoint 5) |> ok with
   | Store.Input_checkpoint_source_changed (Some actual) ->
     check bool "same turn replacement is detected by exact bytes" true
       (Keeper_checkpoint_ref.equal actual same_turn)
   | Input_checkpoint_updated | Input_checkpoint_source_changed None -> fail "ordinal was substituted for identity");
  let foreign = Keeper_checkpoint_ref.create
    ~trace_id:(Keeper_id.Trace_id.of_string "other-input-trace" |> value)
    ~turn_count:4 ~canonical_checkpoint_bytes:"foreign input"
    |> function Ok reference -> reference | Error _ -> fail "foreign trace fixture" in
  rejected "a previous trace authorized a new trace"
    (Store.update_input_checkpoint store ~observed:(Some same_turn) ~checkpoint:foreign);
  check bool "cross-trace refusal creates no foreign input owner" true
    ((Store.input_checkpoint store ~trace_id:foreign.trace_id |> ok) = None);
  rejected "input owner moved behind its source turn"
    (Store.update_input_checkpoint store ~observed:(Some same_turn) ~checkpoint:(checkpoint 3));
  check_input "identity refusals preserve actual current owner" (Some same_turn) store

let () = run "native-call-owner-store" ["input ownership", [
  test_case "same turn bytes, trace and source turn are exact" `Quick test_input_identity_is_not_an_ordinal;
  test_case "input owner survives retirement and reopen" `Quick test_input_owner_survives_retirement_and_reopen;
  test_case "input and native checkpoint commit atomically" `Quick test_input_and_native_checkpoint_commit_atomically;
  test_case "input owner shares native retained liveness" `Quick test_input_retention_shares_native_liveness];
  "recovery", [
  test_case "active restart preserves exact admission" `Quick test_active_restart_preserves_seed_and_exact_identity;
  test_case "terminal restart retains incomplete receipt without dispatch" `Quick test_terminal_restart_never_dispatches;
  test_case "unknown effect survives settlement and rejects retry" `Quick test_unknown_effect_survives_failure_and_rejects_retry;
  test_case "settling an active call is a precondition, not corruption" `Quick test_settling_an_active_call_is_a_precondition_not_corruption;
  test_case "unknown-effect receipt lets the operation fail but not complete" `Quick test_unknown_effect_receipt_lets_the_operation_fail_but_not_complete;
  test_case "retired call replacement and Owner acknowledgement" `Quick test_retired_replacement_is_atomic_and_normal_receipt_acknowledges;
  test_case "checkpoint deferral acknowledges only committed retirement" `Quick test_checkpoint_deferral_acknowledges_only_committed_retirement;
  test_case "checkpoint CAS, digest and commit readback" `Quick test_stale_checkpoint_digest_and_commit_readback];
  "checkpoint release", [
  test_case "a native commit releases what it stopped naming" `Quick test_a_native_commit_releases_what_it_stopped_naming;
  test_case "a replacement seeded from the retired checkpoint keeps it" `Quick
    test_a_replacement_seeded_from_the_retired_checkpoint_keeps_it;
  test_case "settlement releases the retired call" `Quick test_settlement_releases_the_retired_call;
  test_case "a failure settlement releases the retired call" `Quick test_failure_settlement_releases_the_retired_call;
  test_case "a suspend keeps the checkpoint it names" `Quick test_a_suspend_keeps_the_checkpoint_it_names;
  test_case "a reference another execution names is kept" `Quick test_a_reference_another_execution_names_is_kept;
  test_case "only a committed transaction releases" `Quick test_only_a_committed_transaction_releases;
  test_case "a settled execution with a receipt keeps its checkpoints" `Quick
    test_a_settled_execution_with_a_receipt_keeps_its_checkpoints;
  test_case "the release selection matches the sweep" `Quick test_the_release_selection_matches_the_sweep]]
