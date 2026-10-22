open Alcotest
module Store = Keeper_chat_operation_store
module Semantic = Keeper_semantic_execution
module Operation = Keeper_chat_operation
module Native = Keeper_native_call
module Agent = Agent_core.Agent
let ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let value = function Ok value -> value | Error detail -> fail detail
let rejected = function Ok _ -> fail "unexpectedly admitted transition" | Error _ -> ()
let original = Operation.Operation_id.of_string "original-input-wait" |> value
let other = Operation.Operation_id.of_string "independent-input" |> value
let call_id = "019a0010-1000-7000-8000-000000000031"
let input = `Assoc ["message",`String "original request";"metadata",`Assoc ["speaker",`String "operator"]]
let checkpoint bytes = Keeper_checkpoint_ref.create
  ~trace_id:(Keeper_id.Trace_id.of_string "trace-direct-input" |> value)
  ~turn_count:2 ~canonical_checkpoint_bytes:bytes
  |> function Ok reference -> reference | Error _ -> fail "invalid checkpoint fixture"
let seed = checkpoint "seed"
let owned = checkpoint "exact pending bytes"
let pending : Agent_core.Agent_input_request.pending =
  {run_id="execution-run-direct-input-wait";request={request_id="original-question";
    participant_name=Some "operator";question="Which original option?";
    schema=Some (`Assoc ["type",`String "object";"properties",`Assoc ["choice",`Assoc ["type",`String "string"]]]);
    timeout_s=Some 0.1;created_at=1.}}
let waiting = Semantic.input_wait ~checkpoint:owned ~pending |> value
let locator = Agent.execution_locator_of_yojson (`Assoc ["version",`Int 1;"run_id",`String pending.run_id]) |> value
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);Unix.rmdir path
  | _ -> Unix.unlink path
let with_path f =
  let root=Filename.temp_dir "direct-input-wait-" "" in
  Fun.protect ~finally:(fun () -> Store.For_testing.clear_commit_fault ();remove root)
    (fun () -> f (Filename.concat root Store.database_file))
let with_store path f =
  let store=Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> Store.close store |> ok) (fun () -> f store)
(* Real SQLite admission/native/input transactions. Retained filesystem
   availability and the Owner's canonical-pending comparison are caller
   obligations, not evidence supplied by these opaque reference fixtures. *)
let admit store =
  Store.submit store ~now:1. ~operation_id:original ~source:(`Assoc []) ~input |> ok |> ignore;
  let operation=match Store.claim_next store ~now:2. |> ok with Some operation -> operation | None -> fail "original not claimed" in
  let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:operation.execution_digest
    ~api:(Native.New_input {seed_message_count=1}) ~seed_checkpoint:seed ~locator |> value in
  Store.update_direct_native_call store ~now:3. ~operation_id:original ~execution_digest:operation.execution_digest
    (Native.Bind {observed=Native.No_native_call;call}) |> ok;
  (match Store.update_direct_input_checkpoint store ~now:4. ~operation_id:original ~execution_digest:operation.execution_digest
      ~call_id ~observed:seed ~observed_input:None ~checkpoint:owned |> ok with
   | Store.Input_checkpoint_updated -> () | Input_checkpoint_source_changed _ -> fail "fresh input was not published");
  operation
let retire store operation recovery =
  Store.update_direct_native_call store ~now:5. ~operation_id:original ~execution_digest:operation.Operation.execution_digest
    (Native.Terminal {call_id;disposition={Agent.outcome=Agent.Terminal_succeeded;recovery}}) |> ok
let defer store operation waiting = Store.defer_direct_input_wait store ~now:6. ~operation_id:original
  ~execution_digest:operation.Operation.execution_digest ~waiting
let wait store = Store.direct_input_wait store ~operation_id:original |> ok
let native store = Store.direct_native_call store ~operation_id:original |> ok
let current store = match Store.get store original |> ok with Some operation -> operation | None -> fail "original disappeared"
let semantic store = match Store.semantic_get store (Keeper_execution_scope_id.direct_operation original)
    |> Result.map_error Store.semantic_error_to_string |> value with
  | Some execution -> execution | None -> fail "original semantic execution disappeared"
let check_wait store = check bool "complete original request survives" true
  (Option.equal Semantic.equal_input_wait (Some waiting) (wait store))
let check_owner store = check bool "global owned input survives" true
  ((Store.input_checkpoint store ~trace_id:owned.trace_id |> ok)=Store.Input_observed owned)

let test_wait_survives_restart_and_time () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=admit store in retire store operation Agent.Retire;
    ignore (defer store operation waiting |> ok);
    check_wait store;check_owner store;
    check bool "retired native receipt acknowledged with wait" true (native store=Native.No_native_call);
    check bool "original remains nonterminal queued" true ((current store).state=Operation.Queued);
    check bool "no timeout-derived expiry" false (Store.has_claimable_queued store ~now:1e12 |> ok);
    rejected (Store.move_queued_to_front store ~now:1e12 ~operation_id:original);
    rejected (Store.edit_queued store ~operation_id:original ~input:(`String "replacement input"));
    check bool "queue controls preserve original input" true ((current store).input=Some input);
    Store.submit store ~now:7. ~operation_id:other ~source:(`Assoc []) ~input:(`String "independent request") |> ok |> ignore;
    let independent=match Store.claim_next store ~now:8. |> ok with Some operation -> operation | None -> fail "independent input blocked" in
    check bool "only independent work claims" true (Operation.Operation_id.equal independent.operation_id other);
    Store.succeed_running store ~now:9. ~operation_id:other ~outcome_ref:"actual independent result" |> ok |> ignore);
  with_store path (fun store ->
    check int "restart does not invent interruption of queued wait" 0 (List.length (Store.settle_running_after_restart store ~now:1e12 |> ok));
    check_wait store;check_owner store;
    check bool "restart cannot redispatch unresolved input" true (Store.claim_next store ~now:1e12 |> ok=None);
    let references=Semantic.continuation_checkpoints (semantic store) in
    check bool "waiting checkpoint retained for original continuation" true
      (List.exists (fun (row:Keeper_checkpoint_ref.t) -> Keeper_checkpoint_ref.equal owned row) references);
    check bool "original digest/input persist after restart" true ((current store).input=Some input))

let test_only_retired_native_can_wait () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=admit store in
  (match defer store operation waiting with Error Store.Native_call_unsettled -> () | _ -> fail "active call permitted input deferral");
  check bool "active refusal records no wait" true (wait store=None);
  retire store operation (Agent.Operator_repair_required Agent.Effect_outcome_unknown);
  let before=native store in
  (match defer store operation waiting with Error Store.Native_call_unsettled -> () | _ -> fail "unknown effect permitted input deferral");
  check bool "unknown effect evidence unchanged" true (Native.equal_state before (native store));
  check bool "unknown effect is not silently queued" true (match (current store).state with Operation.Running _ -> true | _ -> false)

let test_stale_digest_and_checkpoint_refuse () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=admit store in retire store operation Agent.Retire;
  let before=native store in
  (match Store.defer_direct_input_wait store ~now:6. ~operation_id:original ~execution_digest:"another digest" ~waiting with
   | Error (Store.Invalid_input _) -> () | _ -> fail "foreign digest permitted wait");
  let changed=checkpoint "same-turn different input" in
  (match Store.update_input_checkpoint store ~observed:(Some owned) ~checkpoint:changed |> ok with
   | Store.Input_checkpoint_updated -> () | _ -> fail "fixture current input did not advance");
  (match defer store operation waiting with Error (Store.Invalid_input _) -> () | _ -> fail "stale input authorized wait");
  let changed_wait=Semantic.input_wait ~checkpoint:changed ~pending |> value in
  (match defer store operation changed_wait with Error (Store.Invalid_input _) -> () | _ -> fail "retired native checkpoint was replaced");
  check bool "identity failures keep native receipt" true (Native.equal_state before (native store));
  check bool "identity failures mint no wait" true (wait store=None)

let test_conflicting_wait_cannot_replace_original () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=admit store in retire store operation Agent.Retire;
  ignore (defer store operation waiting |> ok);
  let before=current store in
  ignore (defer store operation waiting |> ok);
  check bool "exact duplicate is only the original observation" true (current store=before);
  let replacement={pending with request={pending.request with question="Changed question with same IDs"}} in
  let conflict=Semantic.input_wait ~checkpoint:owned ~pending:replacement |> value in
  (match defer store operation conflict with Error (Store.Invalid_input _) -> () | _ -> fail "same IDs replaced canonical question");
  check_wait store;check bool "conflict preserves original operation" true (current store=before)

let test_cancel_settles_wait_without_forgetting_input () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=admit store in retire store operation Agent.Retire;
    ignore (defer store operation waiting |> ok);
    Store.cancel_queued store ~now:7. ~operation_id:original |> ok |> ignore;
    check bool "cancelled wait is terminal" true (Semantic.is_terminal (semantic store));
    check bool "semantic wait released" true (wait store=None);
    check_owner store);
  with_store path (fun store -> check_owner store;check bool "cancelled original never reclaims" true (Store.claim_next store ~now:1e12 |> ok=None))

let test_commit_fault_preserves_actual_state after_commit () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=admit store in retire store operation Agent.Retire;
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match defer store operation waiting with Error (Store.Store_unavailable _) -> () | _ -> fail "uncertain commit inferred acceptance");
    Store.For_testing.clear_commit_fault ();
    check int "failed acknowledgement grants no retained deletion" 0
      (List.length (Store.take_released_checkpoints store));
    check bool "actual wait follows actual commit" after_commit (Option.is_some (wait store));
    check bool "retire acknowledgement follows the same commit" after_commit (native store=Native.No_native_call);
    check bool "queue state follows the same commit" after_commit
      ((current store).state=Operation.Queued);
    check bool "commit uncertainty preserves original input" true ((current store).input=Some input);
    check_owner store);
  with_store path (fun store ->
    check bool "actual wait survives actual reopen" after_commit (Option.is_some (wait store));
    if after_commit then check bool "uncertain committed wait never dispatches" true (Store.claim_next store ~now:1e12 |> ok=None))

let test_semantic_wait_cannot_resume_or_complete () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=admit store in retire store operation Agent.Retire;
  ignore (defer store operation waiting |> ok);
  let execution=semantic store in
  let decoded=Semantic.of_json (Semantic.to_json execution) |> Result.map_error Semantic.error_to_string |> value in
  check bool "full pending request survives actual semantic codec" true
    (match decoded.phase with Semantic.Recovering {origin=Semantic.Input_wait restored;_} -> Semantic.equal_input_wait restored waiting | _ -> false);
  List.iter (fun action -> rejected (Semantic.apply ~now:7. action decoded))
    [Semantic.Begin_execution;Semantic.Resume_checkpoint owned;Semantic.Settle Semantic.Completed];
  let reconciled=Semantic.apply ~now:7. (Semantic.Require_reconciliation "read actual original input") decoded
    |> Result.map_error Semantic.error_to_string |> value in
  check bool "reconciliation does not turn waiting into runnable" true
    (match reconciled.phase with Semantic.Recovering {origin=Semantic.Input_wait restored;_} -> Semantic.equal_input_wait restored waiting | _ -> false);
  rejected (Semantic.input_wait ~checkpoint:owned ~pending:{pending with run_id=""})

let respond store operation observed checkpoint = Store.resolve_direct_input_wait store ~now:7.
  ~operation_id:original ~execution_digest:operation.Operation.execution_digest ~observed ~checkpoint
let consumed=checkpoint "consumed original input response bytes"
let test_response_advances_original_and_input_together () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=admit store in retire store operation Agent.Retire;ignore (defer store operation waiting |> ok);
    respond store operation waiting consumed |> ok;
    check bool "response removes original wait" true (wait store=None);
    check bool "consumed global input is published" true
      (Store.input_checkpoint store ~trace_id:owned.trace_id |> ok=Store.Input_observed consumed);
    check bool "same original input is queued" true ((current store).input=Some input);
    rejected (respond store operation waiting consumed));
  with_store path (fun store ->
    let operation=match Store.claim_next store ~now:8. |> ok with Some op -> op | None -> fail "accepted response did not enable original" in
    check bool "only original operation becomes claimable" true (Operation.Operation_id.equal original operation.operation_id);
    Store.resume_direct_checkpoint store ~now:9. ~operation_id:original ~observed:(Semantic.Agent_core consumed) |> ok;
    Store.succeed_running store ~now:10. ~operation_id:original ~outcome_ref:"actual original continuation" |> ok |> ignore)
let test_response_stale_wait_digest_and_input_refuse () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=admit store in retire store operation Agent.Retire;ignore (defer store operation waiting |> ok);
  rejected (Store.resolve_direct_input_wait store ~now:7. ~operation_id:original ~execution_digest:"foreign" ~observed:waiting ~checkpoint:consumed);
  let wrong=Semantic.input_wait ~checkpoint:owned ~pending:{pending with run_id="another-run"} |> value in
  rejected (respond store operation wrong consumed);
  rejected (respond store operation waiting owned);
  let advanced=checkpoint "later independent owned input" in
  Store.update_input_checkpoint store ~observed:(Some owned) ~checkpoint:advanced |> ok |> ignore;
  rejected (respond store operation waiting consumed);
  check_wait store;check bool "rejected response preserves actual newer input" true
    (Store.input_checkpoint store ~trace_id:owned.trace_id |> ok=Store.Input_observed advanced)
let test_response_commit_uncertainty after_commit () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=admit store in retire store operation Agent.Retire;ignore (defer store operation waiting |> ok);
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match respond store operation waiting consumed with Error (Store.Store_unavailable _) -> () | _ -> fail "uncertain response reported acceptance");
    Store.For_testing.clear_commit_fault ();
    check int "uncertainty releases no retained file authority" 0 (List.length (Store.take_released_checkpoints store));
    check bool "input commit follows actual transaction" true
      (Store.input_checkpoint store ~trace_id:owned.trace_id |> ok=Store.Input_observed (if after_commit then consumed else owned));
    check bool "wait transition follows same commit" after_commit (wait store=None));
  with_store path (fun store ->
    check bool "actual response commit survives reopen" after_commit (wait store=None);
    check bool "claimability follows actual response commit" after_commit (Store.has_claimable_queued store ~now:8. |> ok))

(* These refs deliberately permit S to extend W. They are journal identity
   fixtures, not proof of a valid physical checkpoint transformation. *)
let response_checkpoint turn bytes = Keeper_checkpoint_ref.create ~trace_id:owned.trace_id
  ~turn_count:turn ~canonical_checkpoint_bytes:bytes
  |> function Ok reference -> reference | Error _ -> fail "invalid response reference"
let response_source=response_checkpoint 3 "canonical extended original history"
let response_candidate=response_checkpoint 3 "frozen consumed response"
let response_intent = Semantic.input_response_intent ~destination:Semantic.Canonical_input ~waiting ~source:response_source
  ~candidate:response_candidate ~response:(Agent_core.Hooks.Answer (`Assoc ["z",`Int 2;"choice",`String "original"])) |> value
let prepare store operation intent = Store.prepare_direct_input_response store ~now:7. ~operation_id:original
  ~execution_digest:operation.Operation.execution_digest ~intent
let intent store = Store.direct_input_response_intent store ~operation_id:original |> ok
let check_intent store = check bool "one exact response intent survives" true
  (Option.equal Semantic.equal_input_response_intent (Some response_intent) (intent store))
let stage_wait store =
  let operation=admit store in retire store operation Agent.Retire;
  ignore (defer store operation waiting |> ok);operation
let names reference rows = List.exists (fun (row:Keeper_checkpoint_ref.t) ->
  Keeper_checkpoint_ref.equal row reference) rows
let test_intent_survives_restart_without_resuming () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=stage_wait store in
    let before=semantic store in prepare store operation response_intent |> ok;
    check int64 "new intent spends one revision" (Int64.succ before.revision) (semantic store).revision;
    let recorded=semantic store in prepare store operation response_intent |> ok;
    check bool "same intent is the same semantic fact" true (recorded=semantic store);
    check_wait store;check_owner store;
    check bool "intent cannot expire or claim" true (Store.claim_next store ~now:1e12 |> ok=None);
    rejected (Store.move_queued_to_front store ~now:9. ~operation_id:original);
    List.iter (fun action -> rejected (Semantic.apply ~now:9. action recorded))
      [Semantic.Begin_execution;Semantic.Resume_checkpoint response_candidate;Semantic.Settle Semantic.Completed];
    let reconciled=Semantic.apply ~now:9. (Semantic.Require_reconciliation "original physical response requires validation") recorded
      |> Result.map_error Semantic.error_to_string |> value in
    check bool "diagnostic reconciliation preserves intent" true
      (Option.equal Semantic.equal_input_response_intent recorded.input_response_intent reconciled.input_response_intent));
  with_store path (fun store ->
    ignore (Store.settle_running_after_restart store ~now:1e12 |> ok);
    check_wait store;check_intent store;check_owner store;
    check bool "response kind and canonical answer survive journal reopen" true
      (match intent store with Some {response=Agent_core.Hooks.Answer answer;_} ->
        Yojson.Safe.equal answer (`Assoc ["choice",`String "original";"z",`Int 2]) | _ -> false);
    let execution=semantic store in
    List.iter (fun reference ->
      check bool "source and candidate retained by actual reopened semantic row" true (names reference (Semantic.checkpoint_references execution));
      check bool "source and candidate confer no ordinary continuation authority" false (names reference (Semantic.continuation_checkpoints execution)))
      [response_source;response_candidate];
    check bool "original wait remains the pending authority" true (names owned (Semantic.continuation_checkpoints execution)))
let test_intent_conflicts_and_newer_input_preserve_facts () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  let changed ~waiting ~source ~candidate ~response = Semantic.input_response_intent ~destination:Semantic.Canonical_input ~waiting ~source ~candidate ~response |> value in
  let forged_wait=Semantic.input_wait ~checkpoint:owned ~pending:{pending with request={pending.request with question="another original question"}} |> value in
  List.iter (fun different -> rejected (prepare store operation different)) [
    changed ~waiting ~source:response_source ~candidate:response_candidate ~response:Agent_core.Hooks.Timeout;
    changed ~waiting ~source:(response_checkpoint 3 "another source") ~candidate:response_candidate ~response:response_intent.response;
    changed ~waiting ~source:response_source ~candidate:(response_checkpoint 3 "another candidate") ~response:response_intent.response;
    changed ~waiting:forged_wait ~source:response_source ~candidate:response_candidate ~response:response_intent.response];
  rejected (Store.prepare_direct_input_response store ~now:8. ~operation_id:original ~execution_digest:"foreign" ~intent:response_intent);
  let newer=response_checkpoint 4 "actual newer published global input" in
  (match Store.update_input_checkpoint store ~observed:(Some owned) ~checkpoint:newer |> ok with
   | Store.Input_checkpoint_updated -> () | Input_checkpoint_source_changed _ -> fail "new input fixture did not publish");
  rejected (prepare store operation response_intent);
  check_intent store;check_wait store;
  check bool "refusal never overwrites independent newer global input" true
    (Store.input_checkpoint store ~trace_id:owned.trace_id |> ok=Store.Input_observed newer)
let test_intent_commit_uncertainty after_commit () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=stage_wait store in ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match prepare store operation response_intent with
     | Error (Store.Store_unavailable _) -> () | _ -> fail "intent commit uncertainty was accepted");
    Store.For_testing.clear_commit_fault ();
    check bool "intent reflects actual commit, not acknowledgement" after_commit (Option.is_some (intent store));
    check int "uncertain intent grants no deletion authority" 0 (List.length (Store.take_released_checkpoints store));
    check_wait store;check_owner store);
  with_store path (fun store ->
    check bool "intent actual commit survives reopen" after_commit (Option.is_some (intent store));
    check_wait store;check_owner store;
    check bool "uncertainty does not enable a continuation" true (Store.claim_next store ~now:9. |> ok=None);
    List.iter (fun reference -> check bool "retention follows actual commit" after_commit
      (names reference (Semantic.checkpoint_references (semantic store)))) [response_source;response_candidate])
let test_intent_pins_exact_candidate_for_original () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  rejected (respond store operation waiting (response_checkpoint 3 "unbound consumed response"));
  check_intent store;check_wait store;check_owner store;
  ignore (Store.take_released_checkpoints store);
  respond store operation waiting response_candidate |> ok;
  check bool "successful exact resolution retires intent" true (intent store=None);
  check bool "original exact continuation enabled" true
    (Store.direct_checkpoint store ~operation_id:original |> ok=Some (Semantic.Agent_core response_candidate));
  let released=Store.take_released_checkpoints store |> List.map Store.released_reference in
  check bool "source released after confirmed original resolution" true (List.exists (Keeper_checkpoint_ref.equal response_source) released);
  check bool "accepted candidate remains live" false (List.exists (Keeper_checkpoint_ref.equal response_candidate) released);
  let claimed=Store.claim_next store ~now:8. |> ok |> Option.get in
  check bool "only the original admitted operation claims" true (Operation.Operation_id.equal claimed.operation_id original)
let test_cancel_releases_intent_but_keeps_input () = with_path @@ fun path ->
  with_store path (fun store ->
    let operation=stage_wait store in prepare store operation response_intent |> ok;
    ignore (Store.take_released_checkpoints store);
    Store.cancel_queued store ~now:8. ~operation_id:original |> ok |> ignore;
    check bool "cancellation retires intent" true (intent store=None);
    let released=Store.take_released_checkpoints store |> List.map Store.released_reference in
    List.iter (fun reference -> check bool "intent-only evidence released on confirmed cancellation" true
      (List.exists (Keeper_checkpoint_ref.equal reference) released)) [response_source;response_candidate];
    check bool "current input retains its own evidence" false (List.exists (Keeper_checkpoint_ref.equal owned) released);
    check_owner store);
  with_store path (fun store -> check_owner store;check bool "terminal intent remains absent" true (intent store=None))
let test_intent_strict_codec_and_reference_domain () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  let fields = function `Assoc fields -> fields | _ -> fail "expected encoded object" in
  let replace name value json = `Assoc ((name,value)::List.remove_assoc name (fields json)) in
  let encoded=Semantic.to_json (semantic store) in
  let fact=List.assoc "input_response_intent" (fields encoded) in
  let malformed_response response=replace "input_response_intent" (replace "response" response fact) encoded in
  let other_wait=Semantic.input_wait ~checkpoint:owned ~pending:{pending with run_id="other-run"} |> value in
  let other_fact=Semantic.input_response_intent ~destination:Semantic.Canonical_input ~waiting:other_wait ~source:response_source ~candidate:response_candidate
      ~response:Agent_core.Hooks.Declined |> value in
  (* Strict persisted facts cannot be attached to a different wait or phase. *)
  let mutated_wait=replace "pending" (Agent_core.Agent_input_request.pending_to_json other_fact.waiting.pending)
      (List.assoc "waiting" (fields fact)) in
  List.iter (fun json -> rejected (Semantic.of_json json)) [
    `Assoc (("input_response_intent",fact)::fields encoded);
    replace "input_response_intent" `Null encoded;
    replace "revision" (`Int 3) encoded;
    replace "input_response_intent" (`Assoc (("unknown",`Null)::fields fact)) encoded;
    malformed_response (`Assoc ["kind",`String "later"]);
    malformed_response (`Assoc ["kind",`String "timeout";"value",`Int 1]);
    malformed_response (`Assoc ["kind",`String "answer";"value",`Assoc ["a",`Int 1;"a",`Int 2]]);
    malformed_response (`Assoc ["kind",`String "answer";"value",`Float Float.nan]);
    replace "input_response_intent" (replace "waiting" mutated_wait fact) encoded;
    replace "phase" (`Assoc ["kind",`String "ready"]) encoded];
  List.iter (fun response ->
    let intent=Semantic.input_response_intent ~destination:Semantic.Canonical_input ~waiting ~source:response_source ~candidate:response_candidate ~response |> value in
    let unprepared=Semantic.of_json (`Assoc (List.remove_assoc "input_response_intent" (fields encoded)))
      |> Result.map_error Semantic.error_to_string |> value in
    let prepared=Semantic.apply ~now:7. (Semantic.Prepare_input_response intent) unprepared
        |> Result.map_error Semantic.error_to_string |> value in
    let restored=Semantic.of_json (Semantic.to_json prepared) |> Result.map_error Semantic.error_to_string |> value in
    check bool "all three response kinds retain their exact identity" true
      (Option.equal Semantic.equal_input_response_intent (Some intent) restored.input_response_intent))
    [Agent_core.Hooks.Answer (`Assoc ["choice",`String "yes"]);Agent_core.Hooks.Declined;Agent_core.Hooks.Timeout];
  let foreign=Keeper_checkpoint_ref.create ~trace_id:(Keeper_id.Trace_id.of_string "foreign-trace" |> value)
      ~turn_count:3 ~canonical_checkpoint_bytes:"foreign candidate" |> Result.get_ok in
  List.iter (fun (source,candidate) -> rejected (Semantic.input_response_intent ~destination:Semantic.Canonical_input ~waiting ~source ~candidate ~response:Agent_core.Hooks.Declined))
    [response_source,foreign;response_source,response_source;response_source,owned;
     response_checkpoint 1 "regressed source",response_checkpoint 1 "regressed candidate";
     response_source,response_checkpoint 4 "response changed model turn"]

(* Branch foundation exercises the actual semantic transition and strict
   persisted JSON. Store/Owner/physical response/native integration remains a
   separate contract; these opaque refs do not simulate an independent Producer. *)
let transition action execution = Semantic.apply ~now:20. action execution
  |> Result.map_error Semantic.error_to_string |> value
let roundtrip execution = Semantic.of_json (Semantic.to_json execution)
  |> Result.map_error Semantic.error_to_string |> value
let branch_of execution = match execution.Semantic.input_branch with
  | Some branch -> branch | None -> fail "operation lost its independent input branch"
let staged_branch store =
  let operation=stage_wait store in
  let intent=Semantic.input_response_intent ~waiting ~source:response_intent.source ~candidate:response_intent.candidate
    ~response:response_intent.response ~destination:Semantic.Operation_input |> value in
  prepare store operation intent |> ok;
  operation,transition (Semantic.Resolve_input_branch {observed=waiting;checkpoint=response_candidate}) (semantic store)
let check_branch_root execution =
  check bool "first full wait remains the immutable branch origin" true
    (Semantic.equal_input_wait (branch_of execution).origin waiting)
let test_branch_pins_after_consuming_continuation () = with_path @@ fun path -> with_store path @@ fun store ->
  let _,branched=staged_branch store in
  let suspended=roundtrip branched in
  check_branch_root suspended;
  check bool "branch resolution consumes exact prepared intent" true (suspended.input_response_intent=None);
  let running=transition (Semantic.Resume_checkpoint response_candidate) suspended |> roundtrip in
  check bool "resume consumed only the phase continuation" true (running.phase=Semantic.Running);
  List.iter (fun checkpoint -> check bool "branch evidence survives resume before next Bind" true
    (names checkpoint (Semantic.checkpoint_references running))) [owned;response_candidate];
  check bool "historical W is not current continuation authority" false
    (names owned (Semantic.continuation_checkpoints running));
  check bool "C remains current input authority between resume and native Bind" true
    (names response_candidate (Semantic.continuation_checkpoints running));
  let recovering=transition (Semantic.Require_reconciliation "process ended before native Bind") running |> roundtrip in
  check_branch_root recovering;
  check bool "reconciliation preserves the exact branch head" true
    (Keeper_checkpoint_ref.equal (branch_of recovering).checkpoint response_candidate);
  rejected (Semantic.apply ~now:21. (Semantic.Resume_checkpoint response_candidate) recovering);
  rejected (Semantic.apply ~now:21. (Semantic.Resolve_input_branch {observed=waiting;checkpoint=response_candidate}) running);
  let unprepared=semantic store |> fun prepared ->
    let json=Semantic.to_json prepared in
    match json with
    | `Assoc fields -> Semantic.of_json (`Assoc (List.remove_assoc "input_response_intent" fields))
      |> Result.map_error Semantic.error_to_string |> value
    | _ -> fail "expected semantic object" in
  rejected (Semantic.apply ~now:21. (Semantic.Resolve_input_branch {observed=waiting;checkpoint=response_candidate}) unprepared)
let bind_branch execution =
  let call=Native.create ~call_id ~runtime_id:"native.primary" ~operation_digest:execution.Semantic.input_sha256
    ~api:Native.Continue_from_checkpoint ~seed_checkpoint:response_candidate ~locator |> value in
  let execution=Semantic.update_native_call ~now:21. ~expected:Native.No_native_call ~replacement:(Native.Active call) execution
    |> Result.map_error Semantic.error_to_string |> value in
  call,execution
let test_branch_native_cas_and_second_response () = with_path @@ fun path -> with_store path @@ fun store ->
  let _,branched=staged_branch store in
  let running=transition (Semantic.Resume_checkpoint response_candidate) branched in
  let call,bound=bind_branch running in
  let second_checkpoint=response_checkpoint 4 "second owned input wait" in
  rejected (Semantic.apply ~now:22. (Semantic.Advance_input_branch {observed=response_candidate;checkpoint=second_checkpoint}) bound);
  let advanced_call=Native.advance call ~observed:response_candidate ~checkpoint:second_checkpoint |> value in
  let advanced=Semantic.update_native_call ~now:22. ~expected:(Native.Active call) ~replacement:(Native.Active advanced_call) bound
    |> Result.map_error Semantic.error_to_string |> value in
  rejected (Semantic.apply ~now:22. (Semantic.Advance_input_branch {observed=owned;checkpoint=second_checkpoint}) advanced);
  let next=transition (Semantic.Advance_input_branch {observed=response_candidate;checkpoint=second_checkpoint}) advanced |> roundtrip in
  check_branch_root next;
  check bool "branch input publication names the actual native checkpoint" true
    (Keeper_checkpoint_ref.equal (branch_of next).checkpoint second_checkpoint);
  let unchanged=transition (Semantic.Advance_input_branch {observed=second_checkpoint;checkpoint=second_checkpoint}) next in
  check int64 "same branch publication does not spend revision" next.revision unchanged.revision;
  let disposition={Agent.outcome=Agent.Terminal_succeeded;recovery=Agent.Retire} in
  let terminal=Semantic.update_native_call ~now:23. ~expected:(Native.Active advanced_call)
      ~replacement:(Native.Terminal_unacknowledged (advanced_call,disposition)) next
    |> Result.map_error Semantic.error_to_string |> value in
  rejected (Semantic.apply ~now:24. (Semantic.Advance_input_branch {observed=second_checkpoint;checkpoint=second_checkpoint}) terminal);
  let second_pending={Agent_core.Agent_input_request.run_id="second-invocation";request={pending.request with request_id="second-question";question="Second choice?"}} in
  let second_wait=Semantic.input_wait ~checkpoint:second_checkpoint ~pending:second_pending |> value in
  let waiting_again=transition (Semantic.Suspend_input second_wait) terminal |> roundtrip in
  let second_candidate=response_checkpoint 4 "second consumed response" in
  let intent=Semantic.input_response_intent ~destination:Semantic.Operation_input ~waiting:second_wait ~source:second_checkpoint
    ~candidate:second_candidate ~response:Agent_core.Hooks.Timeout |> value in
  let prepared=transition (Semantic.Prepare_input_response intent) waiting_again |> roundtrip in
  rejected (Semantic.apply ~now:24. (Semantic.Resolve_input {observed=second_wait;checkpoint=second_candidate}) prepared);
  rejected (Semantic.apply ~now:24. (Semantic.Resolve_input_branch {observed=waiting;checkpoint=response_candidate}) prepared);
  let resolved=transition (Semantic.Resolve_input_branch {observed=second_wait;checkpoint=second_candidate}) prepared |> roundtrip in
  check_branch_root resolved;
  check bool "second response advances the branch without replacing first origin" true
    (Keeper_checkpoint_ref.equal (branch_of resolved).checkpoint second_candidate);
  check bool "second response retires only its prepared intent" true (resolved.input_response_intent=None);
  check bool "old branch input is no longer retained" false
    (names response_candidate (Semantic.checkpoint_references resolved))
let test_branch_resumed_retry_and_gate_allow_new_input () = with_path @@ fun path -> with_store path @@ fun store ->
  let _,branched=staged_branch store in
  let running=transition (Semantic.Resume_checkpoint response_candidate) branched in
  let retry=Semantic.runtime_retry ~not_before:None ~checkpoint:response_candidate
    ~assignment_id:"branch-runtime" ~failed_runtime_id:"old-runtime" ~next_runtime_id:"native.primary" ~later_runtime_ids:[] |> value in
  let obligation=Semantic.gate_obligation ~approval_id:"branch-gate" ~tool_name:"tool_execute"
    ~input_hash:response_candidate.sha256 |> value in
  let gate=Semantic.gate_wait ~checkpoint:response_candidate ~obligations:[obligation] |> value in
  let resolution={Semantic.obligation;decision=Semantic.Gate_approved} in
  let resumed_retry=transition (Semantic.Suspend_runtime_retry retry) running
    |> transition (Semantic.Resume_runtime_retry retry) in
  let resumed_gate=transition (Semantic.Suspend_gate gate) running
    |> transition (Semantic.Resolve_gate resolution) |> transition (Semantic.Resume_gate (gate,resolution)) in
  List.iter (fun resumed ->
    let call,bound=bind_branch resumed in
    let next_checkpoint=response_checkpoint 4 "new input after resumed runtime or Gate" in
    let next_call=Native.advance call ~observed:response_candidate ~checkpoint:next_checkpoint |> value in
    let progressed=Semantic.update_native_call ~now:22. ~expected:(Native.Active call) ~replacement:(Native.Active next_call) bound
      |> Result.map_error Semantic.error_to_string |> value in
    let advanced=transition (Semantic.Advance_input_branch {observed=response_candidate;checkpoint=next_checkpoint}) progressed |> roundtrip in
    check_branch_root advanced;
    check bool "frozen admission does not block new input on resumed execution" true
      (Keeper_checkpoint_ref.equal (branch_of advanced).checkpoint next_checkpoint);
    check bool "original resume evidence remains retained" true
      (names response_candidate (Semantic.checkpoint_references advanced))) [resumed_retry;resumed_gate]
let test_branch_strict_codec () = with_path @@ fun path -> with_store path @@ fun store ->
  let _,branched=staged_branch store in
  let fields = function `Assoc fields -> fields | _ -> fail "expected encoded object" in
  let replace name value json = `Assoc ((name,value)::List.remove_assoc name (fields json)) in
  let encoded=Semantic.to_json branched in
  let branch=List.assoc "input_branch" (fields encoded) in
  let foreign=Keeper_checkpoint_ref.create ~trace_id:(Keeper_id.Trace_id.of_string "foreign-branch-trace" |> value)
    ~turn_count:4 ~canonical_checkpoint_bytes:"foreign" |> Result.get_ok in
  let checkpoint_json reference = `Assoc ["trace_id",`String (Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id);
    "turn_count",`Int reference.turn_count;"sha256",`String reference.sha256] in
  let with_branch branch=replace "input_branch" branch encoded in
  List.iter (fun json -> rejected (Semantic.of_json json)) [
    with_branch `Null;
    `Assoc (("input_branch",branch)::fields encoded);
    with_branch (`Assoc (("unknown",`Null)::fields branch));
    with_branch (replace "origin" (`Assoc ["kind",`String "interrupted_execution"]) branch);
    with_branch (replace "checkpoint" (checkpoint_json foreign) branch);
    with_branch (replace "checkpoint" (checkpoint_json owned) branch);
    with_branch (replace "checkpoint" (checkpoint_json (response_checkpoint 1 "regressed")) branch);
    replace "revision" (`Int 4) encoded;
    replace "phase" (`Assoc ["kind",`String "preparing"]) encoded;
    replace "phase" (`Assoc ["kind",`String "ready"]) encoded;
    replace "phase" (`Assoc ["kind",`String "suspended";"checkpoint",checkpoint_json foreign]) encoded;
    replace "phase" (`Assoc ["kind",`String "recovering";"origin",`Assoc ["kind",`String "official_checkpointed";"official_client",`Null];"detail",`String "foreign"]) encoded];
  let exhausted=replace "revision" (`Intlit (Int64.to_string Int64.max_int)) encoded
    |> Semantic.of_json |> Result.map_error Semantic.error_to_string |> value in
  (match Semantic.apply ~now:22. (Semantic.Resume_checkpoint response_candidate) exhausted with
   | Error Semantic.Revision_exhausted -> ()
   | Error error -> fail (Semantic.error_to_string error) | Ok _ -> fail "branch resume wrapped exhausted revision")
let test_branch_settlement_releases_only_branch_evidence () = with_path @@ fun path -> with_store path @@ fun store ->
  let _,branched=staged_branch store in
  let running=transition (Semantic.Resume_checkpoint response_candidate) branched in
  List.iter (fun terminal ->
    let settled=transition (Semantic.Settle terminal) running |> roundtrip in
    check bool "actual terminal settlement removes branch" true (settled.input_branch=None);
    check bool "branch root is no longer pinned" false (names owned (Semantic.checkpoint_references settled));
    check bool "branch candidate is no longer pinned" false (names response_candidate (Semantic.checkpoint_references settled)))
    [Semantic.Completed;Semantic.Cancelled;Semantic.Failed "explicit failure"];
  let call,bound=bind_branch running in
  let disposition={Agent.outcome=Agent.Terminal_failed;recovery=Agent.Operator_repair_required Agent.Effect_outcome_unknown} in
  let unknown=Semantic.update_native_call ~now:23. ~expected:(Native.Active call)
      ~replacement:(Native.Terminal_unacknowledged (call,disposition)) bound
    |> Result.map_error Semantic.error_to_string |> value in
  rejected (Semantic.apply ~now:24. (Semantic.Settle Semantic.Completed) unknown);
  let failed=transition (Semantic.Settle (Semantic.Failed "effect needs operator reconciliation")) unknown |> roundtrip in
  check bool "failed branch removes only its own pin" true (failed.input_branch=None);
  check bool "unknown native effect still retains exact checkpoint" true
    (names response_candidate (Semantic.checkpoint_references failed))

let branch_intent () = Semantic.input_response_intent ~waiting ~source:response_source ~candidate:response_candidate
  ~response:response_intent.response ~destination:Semantic.Operation_input |> value
let actual_global store reference = check bool "independent global input remains unchanged" true
  (Store.input_checkpoint store ~trace_id:owned.trace_id |> ok=Store.Input_observed reference)
let branch_reference store = Store.direct_input_branch store ~operation_id:original |> ok
let prepare_branch_with_newer_input store =
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  let newer=response_checkpoint 4 "independent newer global input" in
  ignore (Store.update_input_checkpoint store ~observed:(Some owned) ~checkpoint:newer |> ok);
  operation,newer
let test_branch_store_promotes_exact_intent_and_pins_after_resume () = with_path @@ fun path ->
  let newer=with_store path (fun store ->
    let operation,newer=prepare_branch_with_newer_input store in
    let before=(semantic store).revision in
    let branched=branch_intent () in prepare store operation branched |> ok;
    check bool "stored intent has operation destination" true
      (Option.equal Semantic.equal_input_response_intent (Some branched) (intent store));
    check int64 "promotion commits a new revision" (Int64.succ before) (semantic store).revision;
    prepare store operation branched |> ok;
    check int64 "same intent preparation is idempotent" (Int64.succ before) (semantic store).revision;
    rejected (prepare store operation response_intent);
    let changed=Semantic.input_response_intent ~waiting ~source:response_source ~candidate:response_candidate
      ~response:Agent_core.Hooks.Timeout ~destination:Semantic.Operation_input |> value in
    rejected (prepare store operation changed);
    actual_global store newer;
    respond store operation waiting response_candidate |> ok;
    check bool "response creates actual stored branch" true
      (Option.fold ~none:false ~some:(fun (branch:Semantic.input_branch) -> Semantic.equal_input_wait branch.origin waiting
        && Keeper_checkpoint_ref.equal branch.checkpoint response_candidate) (branch_reference store));
    check bool "branch response consumes prepared intent" true (intent store=None);
    let claimed=Store.claim_next store ~now:9. |> ok |> Option.get in
    check bool "primitive preserves original operation identity" true (Operation.Operation_id.equal claimed.operation_id original);
    Store.resume_direct_checkpoint store ~now:10. ~operation_id:original ~observed:(Semantic.Agent_core response_candidate) |> ok;
    List.iter (fun reference -> check bool "branch pins survive actual SQLite resume transaction" true
      (names reference (Semantic.checkpoint_references (semantic store)))) [owned;response_candidate];
    actual_global store newer;newer) in
  with_store path (fun store ->
    actual_global store newer;
    check bool "branch survives actual SQLite close/reopen" true (Option.is_some (branch_reference store));
    List.iter (fun reference -> check bool "restored running branch pins original evidence" true
      (names reference (Semantic.checkpoint_references (semantic store)))) [owned;response_candidate])
let test_branch_store_promotion_commit_uncertainty after_commit () = with_path @@ fun path ->
  let newer=with_store path (fun store ->
    let operation,newer=prepare_branch_with_newer_input store in
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match prepare store operation (branch_intent ()) with
     | Error (Store.Store_unavailable _) -> () | Error _ | Ok () -> fail "uncertain promotion was acknowledged");
    Store.For_testing.clear_commit_fault ();
    let recorded=intent store |> Option.get in
    check bool "destination reflects actual promotion commit" after_commit (recorded.destination=Semantic.Operation_input);
    check int "uncertain promotion emits no cleanup authority" 0 (List.length (Store.take_released_checkpoints store));
    actual_global store newer;newer) in
  with_store path (fun store ->
    actual_global store newer;check_wait store;
    let recorded=intent store |> Option.get in
    check bool "promotion commit survives actual reopen" after_commit (recorded.destination=Semantic.Operation_input);
    check bool "promotion alone never makes wait claimable" false (Store.has_claimable_queued store ~now:20. |> ok))
let test_branch_store_resolution_commit_uncertainty after_commit () = with_path @@ fun path ->
  let newer=with_store path (fun store ->
    let operation,newer=prepare_branch_with_newer_input store in prepare store operation (branch_intent ()) |> ok;
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match respond store operation waiting response_candidate with
     | Error (Store.Store_unavailable _) -> () | Error _ | Ok () -> fail "uncertain branch resolution was acknowledged");
    Store.For_testing.clear_commit_fault ();
    check bool "branch reflects actual resolution commit" after_commit (Option.is_some (branch_reference store));
    check int "uncertain branch resolution emits no cleanup authority" 0 (List.length (Store.take_released_checkpoints store));
    actual_global store newer;newer) in
  with_store path (fun store ->
    actual_global store newer;
    check bool "branch actual commit survives reopen" after_commit (Option.is_some (branch_reference store));
    check bool "wait consumption follows actual branch commit" after_commit (wait store=None);
    check bool "primitive claimability follows actual branch commit" after_commit (Store.has_claimable_queued store ~now:20. |> ok))
let test_branch_destination_codec_and_direction () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  let json=Semantic.to_json (semantic store) in
  let fields=function `Assoc fields -> fields | _ -> fail "expected object" in
  let fact=List.assoc "input_response_intent" (fields json) in
  let replace name value fields = (name,value)::List.remove_assoc name fields in
  List.iter (fun destination ->
    let malformed=`Assoc (replace "input_response_intent" (`Assoc (replace "destination" destination (fields fact))) (fields json)) in
    rejected (Semantic.of_json malformed)) [`Null;`String "unknown";`Bool true];
  rejected (Semantic.of_json (`Assoc (replace "input_response_intent" (`Assoc (List.remove_assoc "destination" (fields fact))) (fields json))));
  let branched=branch_intent () in
  check bool "strict intent equality includes destination" false (Semantic.equal_input_response_intent response_intent branched);
  check bool "same payload can advance only towards operation branch" true
    (Semantic.continues_input_response_intent ~previous:response_intent ~next:branched);
  check bool "operation input can never reattach" false
    (Semantic.continues_input_response_intent ~previous:branched ~next:response_intent)

let actual_running_branch store =
  let operation,newer=prepare_branch_with_newer_input store in
  prepare store operation (branch_intent ()) |> ok;
  respond store operation waiting response_candidate |> ok;
  ignore (Store.claim_next store ~now:11. |> ok |> Option.get);
  Store.resume_direct_checkpoint store ~now:12. ~operation_id:original
    ~observed:(Semantic.Agent_core response_candidate) |> ok;
  operation,newer
let branch_native_seed=response_checkpoint 3 "original branch native seed with admitted context"
let branch_native_next=response_checkpoint 4 "original branch ordinary native checkpoint"
let branch_native_call operation =
  let locator=Agent.execution_locator_of_yojson
    (`Assoc ["version",`Int 1;"run_id",`String "execution-run-branch-native-after-response"]) |> value in
  Native.create ~call_id:"019a0010-1000-7000-8000-000000000052" ~runtime_id:"native.primary"
    ~operation_digest:operation.Operation.execution_digest ~api:Native.Continue_from_checkpoint
    ~seed_checkpoint:branch_native_seed ~locator |> value
let publish_branch_native store operation change =
  Store.update_direct_native_call store ~now:13. ~operation_id:original
    ~execution_digest:operation.Operation.execution_digest change
let branch_head store = (branch_reference store |> Option.get).Semantic.checkpoint
let check_native_branch_pair store expected =
  check bool "persisted branch names exact native publication" true
    (Keeper_checkpoint_ref.equal (branch_head store) expected);
  check bool "persisted native names same publication" true
    (match native store with
     | Native.Active call | Terminal_unacknowledged (call,_) -> Keeper_checkpoint_ref.equal call.checkpoint expected
     | No_native_call -> false)
let test_branch_native_publication_is_atomic_and_repeats_wait () = with_path @@ fun path ->
  let newer,second_wait=with_store path (fun store ->
    let operation,newer=actual_running_branch store in
    let call=branch_native_call operation in
    publish_branch_native store operation (Native.Bind {observed=Native.No_native_call;call}) |> ok;
    check_native_branch_pair store branch_native_seed;
    let before=Semantic.to_json (semantic store) in
    rejected (Store.update_direct_branch_checkpoint store ~now:14. ~operation_id:original
      ~execution_digest:operation.execution_digest ~call_id:call.call_id ~observed:branch_native_seed
      ~observed_branch:response_candidate ~checkpoint:branch_native_next);
    rejected (Store.update_direct_input_checkpoint store ~now:14. ~operation_id:original
      ~execution_digest:operation.execution_digest ~call_id:call.call_id ~observed:branch_native_seed
      ~observed_input:(Some newer) ~checkpoint:branch_native_next);
    check bool "stale branch and global publication change no native fact" true (before=Semantic.to_json (semantic store));
    Store.update_direct_branch_checkpoint store ~now:15. ~operation_id:original
      ~execution_digest:operation.execution_digest ~call_id:call.call_id ~observed:branch_native_seed
      ~observed_branch:branch_native_seed ~checkpoint:branch_native_next |> ok;
    check_native_branch_pair store branch_native_next;
    rejected (publish_branch_native store operation
      (Native.Checkpoint {call_id=call.call_id;observed=branch_native_seed;checkpoint=branch_native_next}));
    let next_wait_checkpoint=response_checkpoint 5 "original branch next pending input" in
    publish_branch_native store operation (Native.Checkpoint {call_id=call.call_id;observed=branch_native_next;checkpoint=next_wait_checkpoint}) |> ok;
    check_native_branch_pair store next_wait_checkpoint;
    publish_branch_native store operation (Native.Terminal {call_id=call.call_id;
      disposition={Agent.outcome=Agent.Terminal_succeeded;recovery=Agent.Retire}}) |> ok;
    let second_pending:Agent_core.Agent_input_request.pending={run_id="execution-run-original-branch-next";
      request={pending.request with request_id="branch-next-question";question="Original branch next question?"}} in
    let second_wait=Semantic.input_wait ~checkpoint:next_wait_checkpoint ~pending:second_pending |> value in
    ignore (Store.defer_direct_input_wait store ~now:16. ~operation_id:original
      ~execution_digest:operation.execution_digest ~waiting:second_wait |> ok);
    actual_global store newer;newer,second_wait) in
  with_store path (fun store ->
    check bool "next branch wait survives actual SQLite reopen" true
      (Option.equal Semantic.equal_input_wait (Some second_wait) (wait store));
    check bool "repeated branch wait keeps immutable first origin" true
      (Semantic.equal_input_wait (branch_reference store |> Option.get).origin waiting);
    check bool "next branch wait remains blocked" false (Store.has_claimable_queued store ~now:1e12 |> ok);
    check bool "branch wait acknowledges only its retired native" true (native store=Native.No_native_call);
    actual_global store newer)
let test_branch_native_commit_uncertainty ~binding after_commit () = with_path @@ fun path ->
  let newer,expected=with_store path (fun store ->
    let operation,newer=actual_running_branch store in
    let call=branch_native_call operation in
    if not binding then publish_branch_native store operation (Native.Bind {observed=Native.No_native_call;call}) |> ok;
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    let change=if binding then Native.Bind {observed=Native.No_native_call;call}
      else Native.Checkpoint {call_id=call.call_id;observed=branch_native_seed;checkpoint=branch_native_next} in
    (match publish_branch_native store operation change with
     | Error (Store.Store_unavailable _) -> () | Error _ | Ok () -> fail "uncertain native/branch commit was acknowledged");
    Store.For_testing.clear_commit_fault ();
    let expected=if after_commit then (if binding then branch_native_seed else branch_native_next)
      else (if binding then response_candidate else branch_native_seed) in
    check bool "branch reflects actual native commit only" true (Keeper_checkpoint_ref.equal (branch_head store) expected);
    if binding && not after_commit then
      check bool "failed Bind creates no native authority" true (native store=Native.No_native_call)
    else check_native_branch_pair store expected;
    check int "uncertainty grants no retention cleanup" 0 (List.length (Store.take_released_checkpoints store));
    actual_global store newer;newer,expected) in
  with_store path (fun store ->
    check bool "actual native/branch commit survives reopen together" true
      (Keeper_checkpoint_ref.equal (branch_head store) expected);
    if not (binding && not after_commit) then check_native_branch_pair store expected;
    actual_global store newer)

let publish_host_branch store operation ~observed ~checkpoint =
  Store.checkpoint_direct_input_branch store ~now:18. ~operation_id:original
    ~execution_digest:operation.Operation.execution_digest ~observed ~checkpoint
let test_branch_host_checkpoint_preserves_native_retirement () = with_path @@ fun path ->
  let newer,host=with_store path (fun store ->
    let operation,newer=actual_running_branch store in
    let admitted=response_checkpoint response_candidate.turn_count "branch pre-dispatch host admission" in
    publish_host_branch store operation ~observed:response_candidate ~checkpoint:admitted |> ok;
    check bool "host admission advances the branch without native dispatch" true
      (Keeper_checkpoint_ref.equal (branch_head store) admitted && native store=Native.No_native_call);
    rejected (publish_host_branch store operation ~observed:response_candidate ~checkpoint:admitted);
    let call=branch_native_call operation in
    publish_branch_native store operation (Native.Bind {observed=Native.No_native_call;call}) |> ok;
    let active_edit=response_checkpoint branch_native_seed.turn_count "host cannot edit an active native checkpoint" in
    (match publish_host_branch store operation ~observed:branch_native_seed ~checkpoint:active_edit with
     | Error Store.Native_call_unsettled -> () | Error _ | Ok () -> fail "active native call admitted a host history edit");
    publish_branch_native store operation
      (Native.Checkpoint {call_id=call.call_id;observed=branch_native_seed;checkpoint=branch_native_next}) |> ok;
    publish_host_branch store operation ~observed:branch_native_next ~checkpoint:branch_native_next |> ok;
    publish_branch_native store operation (Native.Terminal {call_id=call.call_id;
      disposition={Agent.outcome=Agent.Terminal_succeeded;recovery=Agent.Retire}}) |> ok;
    let host=response_checkpoint branch_native_next.turn_count "host finalizes the original retired branch" in
    rejected (publish_host_branch store operation ~observed:branch_native_next
      ~checkpoint:(response_checkpoint (branch_native_next.turn_count+1) "host cannot invent a later native turn"));
    publish_host_branch store operation ~observed:branch_native_next ~checkpoint:host |> ok;
    let before=(semantic store).revision in
    publish_host_branch store operation ~observed:host ~checkpoint:host |> ok;
    check int64 "same host checkpoint does not spend a semantic revision" before (semantic store).revision;
    check bool "host result is the retained branch head" true (Keeper_checkpoint_ref.equal (branch_head store) host);
    check bool "host metadata does not masquerade as native execution evidence" true
      (match native store with
       | Native.Terminal_unacknowledged (actual,{Agent.recovery=Retire;_}) ->
         Keeper_checkpoint_ref.equal actual.checkpoint branch_native_next
       | No_native_call | Active _
       | Terminal_unacknowledged (_, {Agent.recovery=(Retire | Operator_repair_required Effect_outcome_unknown);_}) -> false);
    actual_global store newer;newer,host) in
  with_store path (fun store ->
    check bool "post-native host checkpoint survives actual SQLite reopen" true (Keeper_checkpoint_ref.equal (branch_head store) host);
    check bool "native evidence remains separately retained" true (names branch_native_next (Semantic.checkpoint_references (semantic store)));
    actual_global store newer)
let test_branch_host_checkpoint_rejects_unknown_effect () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation,newer=actual_running_branch store in
  let call=branch_native_call operation in
  publish_branch_native store operation (Native.Bind {observed=Native.No_native_call;call}) |> ok;
  publish_branch_native store operation (Native.Terminal {call_id=call.call_id;
    disposition={Agent.outcome=Agent.Terminal_failed;recovery=Agent.Operator_repair_required Agent.Effect_outcome_unknown}}) |> ok;
  let before=Semantic.to_json (semantic store) in
  rejected (publish_host_branch store operation ~observed:branch_native_seed ~checkpoint:branch_native_seed);
  rejected (publish_host_branch store operation ~observed:branch_native_seed
    ~checkpoint:(response_checkpoint branch_native_seed.turn_count "cannot finalize an unknown native effect"));
  check bool "unknown native effect preserves all original facts" true (before=Semantic.to_json (semantic store));
  actual_global store newer
let test_branch_host_checkpoint_commit_uncertainty after_commit () = with_path @@ fun path ->
  let newer,expected=with_store path (fun store ->
    let operation,newer=actual_running_branch store in
    let host=response_checkpoint response_candidate.turn_count "exact retained host admission" in
    ignore (Store.take_released_checkpoints store);
    Store.For_testing.fail_next_commit (if after_commit then Fail_after_commit else Fail_before_commit);
    (match publish_host_branch store operation ~observed:response_candidate ~checkpoint:host with
     | Error (Store.Store_unavailable _) -> () | Error _ | Ok () -> fail "uncertain host checkpoint minted acknowledgement");
    Store.For_testing.clear_commit_fault ();
    let expected=if after_commit then host else response_candidate in
    check bool "host head reflects actual commit" true (Keeper_checkpoint_ref.equal (branch_head store) expected);
    check int "host checkpoint uncertainty grants no cleanup" 0 (List.length (Store.take_released_checkpoints store));
    actual_global store newer;newer,expected) in
  with_store path (fun store ->
    check bool "actual host checkpoint commit survives reopen" true (Keeper_checkpoint_ref.equal (branch_head store) expected);
    actual_global store newer)

let () = run "durable original input wait"
  ["store",[
    test_case "host checkpoint preserves exact native retirement and independent input" `Quick test_branch_host_checkpoint_preserves_native_retirement;
    test_case "host checkpoint cannot hide unknown native effects" `Quick test_branch_host_checkpoint_rejects_unknown_effect;
    test_case "host checkpoint precommit failure grants no receipt" `Quick (test_branch_host_checkpoint_commit_uncertainty false);
    test_case "host checkpoint uncertain commit stays an error after reopen" `Quick (test_branch_host_checkpoint_commit_uncertainty true);
    test_case "native seed and later branch checkpoints publish atomically and wait again" `Quick test_branch_native_publication_is_atomic_and_repeats_wait;
    test_case "branch native Bind precommit failure grants no receipt" `Quick (test_branch_native_commit_uncertainty ~binding:true false);
    test_case "branch native Bind uncertain commit stays an error after reopen" `Quick (test_branch_native_commit_uncertainty ~binding:true true);
    test_case "branch native checkpoint precommit failure changes neither reference" `Quick (test_branch_native_commit_uncertainty ~binding:false false);
    test_case "branch native checkpoint uncertain commit persists both references" `Quick (test_branch_native_commit_uncertainty ~binding:false true);
    test_case "branch Store promotion and resume preserve independent input" `Quick test_branch_store_promotes_exact_intent_and_pins_after_resume;
    test_case "branch promotion precommit failure preserves canonical intent" `Quick (test_branch_store_promotion_commit_uncertainty false);
    test_case "uncertain committed branch promotion survives reopen" `Quick (test_branch_store_promotion_commit_uncertainty true);
    test_case "branch resolution precommit failure preserves blocked wait" `Quick (test_branch_store_resolution_commit_uncertainty false);
    test_case "uncertain committed branch resolution survives reopen" `Quick (test_branch_store_resolution_commit_uncertainty true);
    test_case "branch destination codec and promotion are strict" `Quick test_branch_destination_codec_and_direction;
    test_case "branch pins survive consumed continuation and reconciliation" `Quick test_branch_pins_after_consuming_continuation;
    test_case "branch native CAS and repeated input preserve original lineage" `Quick test_branch_native_cas_and_second_response;
    test_case "resumed runtime and Gate keep admission while branch input advances" `Quick test_branch_resumed_retry_and_gate_allow_new_input;
    test_case "branch persisted codec rejects inconsistent authority" `Quick test_branch_strict_codec;
    test_case "branch settlement preserves unknown native evidence" `Quick test_branch_settlement_releases_only_branch_evidence;
    test_case "prepared response survives restart and stays blocked" `Quick test_intent_survives_restart_without_resuming;
    test_case "conflicting intents and newer input preserve original facts" `Quick test_intent_conflicts_and_newer_input_preserve_facts;
    test_case "intent precommit failure does not invent retained intent" `Quick (test_intent_commit_uncertainty false);
    test_case "uncertain committed intent persists without acknowledgement" `Quick (test_intent_commit_uncertainty true);
    test_case "prepared intent pins the original exact consumed candidate" `Quick test_intent_pins_exact_candidate_for_original;
    test_case "cancellation releases response evidence but keeps owned input" `Quick test_cancel_releases_intent_but_keeps_input;
    test_case "persisted intent has a strict response and reference domain" `Quick test_intent_strict_codec_and_reference_domain;
    test_case "accepted response atomically enables original continuation and survives reopen" `Quick test_response_advances_original_and_input_together;
    test_case "stale response wait digest and input refuse atomically" `Quick test_response_stale_wait_digest_and_input_refuse;
    test_case "response before-commit failure preserves wait and input" `Quick (test_response_commit_uncertainty false);
    test_case "uncertain committed response stays an error but survives reopen" `Quick (test_response_commit_uncertainty true);
    test_case "original wait survives restart and elapsed time" `Quick test_wait_survives_restart_and_time;
    test_case "only retired native evidence can defer input" `Quick test_only_retired_native_can_wait;
    test_case "stale digest and input/native references refuse" `Quick test_stale_digest_and_checkpoint_refuse;
    test_case "same IDs cannot replace canonical question" `Quick test_conflicting_wait_cannot_replace_original;
    test_case "cancellation settles wait while input owner remains" `Quick test_cancel_settles_wait_without_forgetting_input;
    test_case "precommit failure retains running/native evidence" `Quick (test_commit_fault_preserves_actual_state false);
    test_case "uncertain committed wait remains blocked after reopen" `Quick (test_commit_fault_preserves_actual_state true);
    test_case "wait codec and generic resume preserve original lifetime" `Quick test_semantic_wait_cannot_resume_or_complete]]
