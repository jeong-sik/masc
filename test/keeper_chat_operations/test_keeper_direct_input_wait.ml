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
let response_intent = Semantic.input_response_intent ~waiting ~source:response_source
  ~candidate:response_candidate ~response:(Agent_core.Hooks.Answer (`Assoc ["z",`Int 2;"choice",`String "original"])) |> value
let prepare store operation intent = Store.prepare_direct_input_response store ~now:7. ~operation_id:original
  ~execution_digest:operation.Operation.execution_digest ~intent
let intent store = Store.direct_input_response_intent store ~operation_id:original |> ok
let check_intent store = check bool "one exact response intent survives" true
  (Option.equal Semantic.equal_input_response_intent (Some response_intent) (intent store))
let stage_wait store =
  let operation=admit store in retire store operation Agent.Retire;
  ignore (defer store operation waiting |> ok);operation
let names reference rows = List.exists (fun (row:Semantic.retained_checkpoint) ->
  Keeper_checkpoint_ref.equal row.reference reference) rows
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
      check bool "source and candidate retained by actual reopened semantic row" true (names reference (Semantic.retained_checkpoints execution));
      check bool "source and candidate confer no ordinary continuation authority" false (names reference (Semantic.continuation_checkpoints execution)))
      [response_source;response_candidate];
    check bool "original wait remains the pending authority" true (names owned (Semantic.continuation_checkpoints execution)))
let test_intent_conflicts_and_newer_input_preserve_facts () = with_path @@ fun path -> with_store path @@ fun store ->
  let operation=stage_wait store in prepare store operation response_intent |> ok;
  let changed ~waiting ~source ~candidate ~response = Semantic.input_response_intent ~waiting ~source ~candidate ~response |> value in
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
      (names reference (Semantic.retained_checkpoints (semantic store)))) [response_source;response_candidate])
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
  let other_fact=Semantic.input_response_intent ~waiting:other_wait ~source:response_source ~candidate:response_candidate
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
    let intent=Semantic.input_response_intent ~waiting ~source:response_source ~candidate:response_candidate ~response |> value in
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
  List.iter (fun (source,candidate) -> rejected (Semantic.input_response_intent ~waiting ~source ~candidate ~response:Agent_core.Hooks.Declined))
    [response_source,foreign;response_source,response_source;response_source,owned;
     response_checkpoint 1 "regressed source",response_checkpoint 1 "regressed candidate";
     response_source,response_checkpoint 4 "response changed model turn"]

let () = run "durable original input wait"
  ["store",[
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
