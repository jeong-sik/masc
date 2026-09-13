open Alcotest
module Store = Keeper_chat_operation_store
module Operation = Keeper_chat_operation
module Semantic = Keeper_semantic_execution
module Scope = Keeper_execution_scope_id

let ok = function Ok value -> value | Error error -> fail (Store.error_to_string error)
let string_ok = function Ok value -> value | Error error -> fail error
let semantic_ok = function Ok value -> value | Error error -> fail (Store.semantic_error_to_string error)
let rejected = function Error _ -> () | Ok _ -> fail "invalid continuation was accepted"
let operation_id = Operation.Operation_id.of_string "direct-runtime-continuation" |> string_ok
let source = `Assoc ["channel", `String "dashboard"; "thread_id", `String "keeper:writer"]
let input = `Assoc ["message", `String "Finish the original PDF task";
  "turn_instructions", `String "Preserve task criteria";
  "attachments", `List [`Assoc ["id", `String "original-reference"; "mime_type", `String "application/pdf"]]]
let input = match Operation.canonical_json input with
  | Ok input -> input | Error _ -> fail "invalid canonical input fixture"
let checkpoint bytes =
  let trace_id = Keeper_id.Trace_id.of_string "direct-runtime-trace" |> string_ok in
  match Keeper_checkpoint_ref.create ~trace_id ~turn_count:3 ~canonical_checkpoint_bytes:bytes with
  | Ok value -> value | Error _ -> fail "invalid checkpoint fixture"
let continuation ?(bytes = "original input and three completed tool results") () =
  Semantic.runtime_retry ~not_before:None ~checkpoint:(checkpoint bytes) ~assignment_id:"direct-assignment"
    ~failed_runtime_id:"rate-limited-runtime" ~next_runtime_id:"alternate-runtime"
    ~later_runtime_ids:["final-runtime"] |> string_ok
let rec remove path =
  match Unix.lstat path with
  | {Unix.st_kind = Unix.S_DIR; _} ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
let with_path f =
  let root = Filename.temp_dir "direct-continuation-" "" in
  Fun.protect ~finally:(fun () -> Store.For_testing.clear_commit_fault (); remove root)
    (fun () -> f (Filename.concat root Store.database_file))
let with_open path f =
  let store = Store.open_or_create ~path |> ok in
  Fun.protect ~finally:(fun () -> Store.close store |> ok) (fun () -> f store)
let current store = match Store.get store operation_id |> ok with
  | Some value -> value | None -> fail "operation disappeared"
let claim store = match Store.claim_next store ~now:11. |> ok with
  | Some operation -> operation | None -> fail "original operation was not queued"
let admitted store =
  ignore (Store.submit store ~now:10. ~operation_id ~source ~input |> ok);
  claim store
let defer store (operation : Operation.t) continuation =
  Store.defer_direct_runtime_retry store ~now:12. ~operation_id
    ~execution_digest:operation.execution_digest ~continuation
let execution store =
  match Store.semantic_get store (Scope.direct_operation operation_id) |> semantic_ok with
  | Some value -> value | None -> fail "semantic continuation disappeared"
let assert_bound store expected =
  match Store.direct_runtime_retry store ~operation_id |> ok with
  | Some observed -> check bool "exact checkpoint and frozen suffix" true (Semantic.equal_runtime_retry expected observed)
  | None -> fail "checkpointed runtime continuation disappeared"

let test_same_operation_survives_and_completes () = with_path (fun path ->
  let retry = continuation () in
  let admission_digest = with_open path (fun store ->
    let original = admitted store in
    let queued = defer store original retry |> ok in
    check bool "same operation queued" true (queued.state = Operation.Queued);
    check bool "original input retained" true (queued.input = original.input);
    check bool "channel and thread retained" true (queued.source = original.source);
    check string "same execution digest" original.execution_digest queued.execution_digest;
    assert_bound store retry;
    original.admission_digest) in
  with_open path (fun store ->
    check int "queued continuation is not interrupted" 0 (Store.settle_running_after_restart store ~now:20. |> ok);
    let claimed = claim store in
    check string "same admission identity" admission_digest claimed.admission_digest;
    check bool "attachments and instructions intact" true (claimed.input = Some input);
    assert_bound store retry;
    Store.resume_direct_runtime_retry store ~now:21. ~operation_id ~observed:retry |> ok;
    let complete = Store.succeed_running store ~now:22. ~operation_id ~outcome_ref:"alternate-runtime-result" |> ok in
    check bool "completed original operation" true (match complete.state with Operation.Succeeded _ -> true | _ -> false);
    check bool "semantic completion committed with operation" true ((execution store).phase = Semantic.Settled Semantic.Completed);
    check bool "terminal body released" true ((execution store).input = None)))

let test_restart_after_claim_requires_exact_checkpoint () = with_path (fun path ->
  let retry = continuation () in
  with_open path (fun store ->
    let original = admitted store in
    ignore (defer store original retry |> ok);
    ignore (claim store));
  with_open path (fun store ->
    check int "typed pending retry is restored, not terminalized" 0 (Store.settle_running_after_restart store ~now:20. |> ok);
    check bool "same operation requeued" true ((current store).state = Operation.Queued);
    ignore (claim store);
    rejected (Store.resume_direct_runtime_retry store ~now:21. ~operation_id
      ~observed:(continuation ~bytes:"another checkpoint" ()));
    assert_bound store retry;
    Store.resume_direct_runtime_retry store ~now:22. ~operation_id ~observed:retry |> ok))

let test_interrupted_resumed_effects_are_not_replayed () = with_path (fun path ->
  with_open path (fun store ->
    let original = admitted store in
    let retry = continuation () in
    ignore (defer store original retry |> ok);
    ignore (claim store);
    Store.resume_direct_runtime_retry store ~now:13. ~operation_id ~observed:retry |> ok);
  with_open path (fun store ->
    check int "execution without a new checkpoint needs reconciliation" 1 (Store.settle_running_after_restart store ~now:20. |> ok);
    check bool "no blind queue replay" true ((Store.claim_next store ~now:21. |> ok) = None);
    check bool "original semantic input remains for reconciliation" true ((execution store).input = Some input);
    check bool "typed interrupted origin" true (match (execution store).phase with
      | Semantic.Recovering {origin = Semantic.Interrupted_execution; _} -> true | _ -> false)))

let test_binding_and_edit_refusal () = with_path (fun path -> with_open path (fun store ->
  let original = admitted store in
  rejected (Store.defer_direct_runtime_retry store ~now:12. ~operation_id
    ~execution_digest:(String.make 64 '0') ~continuation:(continuation ()));
  check bool "wrong digest did not clear input" true ((current store).input = Some input);
  ignore (defer store original (continuation ()) |> ok);
  rejected (Store.edit_queued store ~operation_id ~input:(`Assoc ["message", `String "different work"]));
  check bool "checkpointed input cannot be edited" true ((current store).input = Some input)))

let test_commit_faults_keep_one_bound_continuation () = with_path (fun path -> with_open path (fun store ->
  let original = admitted store in
  let retry = continuation () in
  Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
  rejected (defer store original retry);
  check bool "rollback keeps running operation" true (match (current store).state with Operation.Running _ -> true | _ -> false);
  check bool "rollback leaves no detached continuation" true ((Store.direct_runtime_retry store ~operation_id |> ok) = None);
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  ignore (defer store original retry |> ok);
  assert_bound store retry;
  ignore (defer store original retry |> ok);
  check int "one original queued operation" 1 (Store.inventory store |> ok).queued_count))

let test_resume_uncertain_commit_is_read_back () = with_path (fun path -> with_open path (fun store ->
  let original = admitted store in
  let retry = continuation () in
  ignore (defer store original retry |> ok);
  ignore (claim store);
  Store.For_testing.fail_next_commit Store.For_testing.Fail_after_commit;
  Store.resume_direct_runtime_retry store ~now:13. ~operation_id ~observed:retry |> ok;
  check bool "resumed phase independently confirmed" true (match (execution store).phase with
      | Semantic.Resuming_runtime_retry observed -> Semantic.equal_runtime_retry retry observed
      | Semantic.Preparing | Semantic.Ready | Semantic.Running | Semantic.Resuming_gate _ | Semantic.Suspended _
      | Semantic.Recovering _ | Semantic.Settled _ -> false);
  check bool "input retained while execution is active" true ((current store).input = Some input)))

let test_cancel_releases_both_inputs () = with_path (fun path -> with_open path (fun store ->
  let original = admitted store in
  ignore (defer store original (continuation ()) |> ok);
  let cancelled = Store.cancel_queued store ~now:13. ~operation_id |> ok in
  check bool "chat cancellation" true (match cancelled.state with Operation.Cancelled _ -> true | _ -> false);
  check bool "semantic cancellation" true ((execution store).phase = Semantic.Settled Semantic.Cancelled);
  check bool "both bodies released" true (cancelled.input = None && (execution store).input = None)))

let test_cooling_retry_is_not_claimable_until_not_before () = with_path (fun path ->
  (* 2026-09-10 drain investigation: a deferred retry whose failure was the
     provider throttling carries [not_before]; claiming it earlier re-issues
     the rejected call in a tight loop. *)
  let retry_with_backoff not_before =
    Semantic.runtime_retry ~not_before:(Some not_before)
      ~checkpoint:(checkpoint "provider throttled the original call")
      ~assignment_id:"direct-assignment" ~failed_runtime_id:"rate-limited-runtime"
      ~next_runtime_id:"alternate-runtime" ~later_runtime_ids:["final-runtime"] |> string_ok in
  with_open path (fun store ->
    let original = admitted store in
    ignore (defer store original (retry_with_backoff 100.) |> ok);
    (* The idempotent re-defer path keeps the persisted continuation when the
       identity matches — not_before is scheduling metadata, not identity — so
       the first backoff wins and the fresh 200. is discarded. Pin that:
       claimable at 150. proves the persisted value is 100., not 200. *)
    ignore (defer store original (retry_with_backoff 200.) |> ok);
    let before_priority = Store.get store operation_id |> ok in
    (match Store.move_queued_to_front store ~now:12. ~operation_id with
     | Error (Store.Invalid_input _) -> ()
     | _ -> fail "run-next bypassed provider retry readiness");
    check bool "refused priority leaves queued continuation intact" true
      ((Store.get store operation_id |> ok) = before_priority);
    check bool "cooling retry is not claimable" false (Store.has_claimable_queued store ~now:12. |> ok);
    check bool "claim skips the cooling retry" true ((Store.claim_next store ~now:12. |> ok) = None);
    let independent = Operation.Operation_id.of_string "independent-work" |> string_ok in
    Store.submit store ~now:13. ~operation_id:independent ~source ~input |> ok |> ignore;
    (match Store.claim_next store ~now:14. |> ok with
     | Some operation -> check bool "new work claimed ahead of the cooling retry" true
         (Operation.Operation_id.equal independent operation.operation_id)
     | None -> fail "the cooling head blocked independent work");
    Store.succeed_running store ~now:15. ~operation_id:independent ~outcome_ref:"done" |> ok |> ignore;
    check bool "backoff still running" false (Store.has_claimable_queued store ~now:99. |> ok);
    check bool "first backoff wins over an idempotent re-defer" true (Store.has_claimable_queued store ~now:150. |> ok));
  with_open path (fun store ->
    check bool "backoff survives a restart" false (Store.has_claimable_queued store ~now:99. |> ok);
    check bool "backoff elapsed makes the retry claimable" true (Store.has_claimable_queued store ~now:201. |> ok);
    match Store.claim_next store ~now:201. |> ok with
    | Some operation -> check bool "original operation claimed after backoff" true
        (Operation.Operation_id.equal operation_id operation.operation_id)
    | None -> fail "cooling retry never became claimable"))

let test_batch_runtime_retry_keeps_frozen_members () = with_path (fun path ->
  let follower = Operation.Operation_id.of_string "batch-runtime-follower" |> string_ok in
  let arrival = Operation.Operation_id.of_string "batch-runtime-new-arrival" |> string_ok in
  with_open path (fun store ->
    List.iter (fun operation_id -> ignore (Store.submit store ~now:1. ~operation_id ~source ~input |> ok)) [operation_id; follower];
    let combined = `Assoc ["message", `String "frozen batch"] in
    let batch _ _ = Ok (Some {Store.members=[operation_id; follower]; input=combined}) in
    let claimed = match Store.claim_next ~batch store ~now:2. |> ok with Some value -> value | None -> fail "no batch" in
    let retry = continuation () in
    ignore (defer store claimed retry |> ok);
    ignore (Store.submit store ~now:13. ~operation_id:arrival ~source ~input |> ok);
    let prioritized = Store.move_queued_to_front store ~now:14. ~operation_id:follower |> ok in
    check bool "pending follower priority retains original request identity" true
      (Operation.Operation_id.equal prioritized.operation_id follower);
    check bool "pending follower resolves to frozen execution" true
      (Option.exists (fun (binding : Operation.batch_membership) -> Operation.Operation_id.equal binding.execution_id operation_id) prioritized.batch_membership);
    let forbidden _ _ = fail "resumed batch asked to reselect membership" in
    let resumed = match Store.claim_next ~batch:forbidden store ~now:14. |> ok with Some value -> value | None -> fail "no retry" in
    check bool "same frozen aggregate" true (resumed.input = claimed.input);
    check int "same frozen members" 2 (List.length (Store.batch_operations store ~operation_id |> ok));
    check int "new arrival remains queued" 1 (Store.inventory store |> ok).queued_count;
    Store.resume_direct_runtime_retry store ~now:15. ~operation_id ~observed:retry |> ok;
    ignore (Store.succeed_running store ~now:16. ~operation_id ~outcome_ref:"shared-retry" |> ok);
    match Store.get store follower |> ok with
    | Some {Operation.state=Operation.Succeeded _; _} -> ()
    | _ -> fail "follower was not settled by resumed execution"))

let test_cooperative_checkpoint_preserves_identity_and_yields_to_steering () = with_path (fun path ->
  let saved = Semantic.Agent_core (checkpoint "cooperative tool results") in
  with_open path (fun store ->
    let first = admitted store in
    let steering = Operation.Operation_id.of_string "new-user-steering" |> string_ok in
    ignore (Store.submit store ~now:11. ~operation_id:steering ~source ~input:(`Assoc ["message", `String "change direction"]) |> ok);
    let queued = Store.defer_direct_checkpoint store ~now:12. ~operation_id
      ~execution_digest:first.execution_digest ~checkpoint:saved |> ok in
    check bool "checkpoint keeps original input" true (queued.input = first.input);
    check bool "checkpoint is unfinished" true (queued.state = Operation.Queued);
    check bool "no provider retry invented" true (Store.direct_runtime_retry store ~operation_id |> ok = None);
    let next = Store.claim_next store ~now:13. |> ok |> Option.get in
    check bool "new user steering precedes continuation" true (Operation.Operation_id.equal steering next.operation_id);
    ignore (Store.succeed_running store ~now:14. ~operation_id:steering ~outcome_ref:"steering" |> ok);
    ignore (Store.claim_next store ~now:15. |> ok));
  with_open path (fun store ->
    check int "claim crash retains unconsumed checkpoint" 0 (Store.settle_running_after_restart store ~now:16. |> ok);
    ignore (Store.claim_next store ~now:17. |> ok);
    rejected (Store.resume_direct_checkpoint store ~now:18. ~operation_id ~observed:(Semantic.Agent_core (checkpoint "wrong")));
    Store.resume_direct_checkpoint store ~now:18. ~operation_id ~observed:saved |> ok;
    ignore (Store.succeed_running store ~now:19. ~operation_id ~outcome_ref:"actual-answer" |> ok);
    check bool "actual answer settles semantic execution" true (Semantic.is_terminal (execution store));
    check bool "success releases original input" true ((current store).input = None)))

let test_cooperative_checkpoint_commit_fault_and_cancel () = with_path (fun path ->
  with_open path (fun store ->
    let first = admitted store in
    let saved = Semantic.Agent_core (checkpoint "saved") in
    Store.For_testing.fail_next_commit Store.For_testing.Fail_before_commit;
    rejected (Store.defer_direct_checkpoint store ~now:12. ~operation_id
      ~execution_digest:first.execution_digest ~checkpoint:saved);
    check bool "failed defer leaves operation running" true
      (match (current store).state with Operation.Running _ -> true | _ -> false);
    check bool "failed defer has no checkpoint authority" true (Store.direct_checkpoint store ~operation_id |> ok = None);
    ignore (Store.defer_direct_checkpoint store ~now:13. ~operation_id
      ~execution_digest:first.execution_digest ~checkpoint:saved |> ok);
    ignore (Store.cancel_queued store ~now:14. ~operation_id |> ok);
    check bool "cancel settles checkpoint authority" true (Semantic.is_terminal (execution store));
    check bool "cancel does not authorize resume" true (Store.direct_checkpoint store ~operation_id |> ok = None)))

let test_official_checkpoint_retains_session_input_and_cancel_boundary () = with_path (fun path ->
  let official = ref None in
  with_open path (fun store ->
    let first = admitted store in
    let seed = match Semantic.create ~id:(Scope.direct_operation operation_id) ~input ~sources:[] ~now:10. with
      | Ok value -> value | Error error -> fail (Semantic.error_to_string error) in
    let checkpoint : Semantic.official_client_checkpoint =
      { client_kind = Codex; runtime_id = "codex.test"; session_id = "original-thread";
        turn_id = "yielded-turn"; tool_surface_sha256 = String.make 64 'a'; frame = seed.frame } in
    official := Some checkpoint;
    let authority = Semantic.Official_client checkpoint in
    ignore (Store.defer_direct_checkpoint store ~now:12. ~operation_id
      ~execution_digest:first.execution_digest ~checkpoint:authority |> ok);
    check bool "original multimodal input remains durable" true ((current store).input = first.input);
    check bool "official yield is pending, not a fake provider retry" true
      ((current store).state = Operation.Queued && Store.direct_runtime_retry store ~operation_id |> ok = None));
  with_open path (fun store ->
    let saved = Option.get !official in
    let authority = Semantic.Official_client saved in
    check bool "reopen preserves the official authority" true
      (match Store.direct_checkpoint store ~operation_id |> ok with
       | Some observed -> Semantic.equal_gate_checkpoint authority observed | None -> false);
    ignore (Store.claim_next store ~now:13. |> ok);
    rejected (Store.resume_direct_checkpoint store ~now:14. ~operation_id
      ~observed:(Semantic.Official_client {saved with session_id="unrelated-thread"}));
    Store.resume_direct_checkpoint store ~now:14. ~operation_id ~observed:authority |> ok;
    let advanced = Semantic.Official_client {saved with turn_id="next-yield"} in
    ignore (Store.defer_direct_checkpoint store ~now:15. ~operation_id
      ~execution_digest:(current store).execution_digest ~checkpoint:advanced |> ok);
    ignore (Store.cancel_queued store ~now:16. ~operation_id |> ok);
    check bool "cancel terminalizes official continuation" true (Semantic.is_terminal (execution store));
    check bool "cancel removes resume authority" true (Store.direct_checkpoint store ~operation_id |> ok = None)))

let () = run "Keeper direct runtime continuation" ["durable owner journal", [
  test_case "official checkpoint preserves original conversation without native replay" `Quick test_official_checkpoint_retains_session_input_and_cancel_boundary;
  test_case "cooperative checkpoint yields to steering and survives claim crash" `Quick test_cooperative_checkpoint_preserves_identity_and_yields_to_steering;
  test_case "cooperative checkpoint commit fault and cancel" `Quick test_cooperative_checkpoint_commit_fault_and_cancel;
  test_case "batch retry freezes members and excludes new arrivals" `Quick test_batch_runtime_retry_keeps_frozen_members;
  test_case "same operation survives and completes" `Quick test_same_operation_survives_and_completes;
  test_case "restart after claim requires exact checkpoint" `Quick test_restart_after_claim_requires_exact_checkpoint;
  test_case "interrupted resumed effects are not replayed" `Quick test_interrupted_resumed_effects_are_not_replayed;
  test_case "input digest and queued edit binding" `Quick test_binding_and_edit_refusal;
  test_case "commit faults preserve one continuation" `Quick test_commit_faults_keep_one_bound_continuation;
  test_case "resume uncertain commit readback" `Quick test_resume_uncertain_commit_is_read_back;
  test_case "cancellation settles both records" `Quick test_cancel_releases_both_inputs;
  test_case "cooling retry waits for not_before" `Quick test_cooling_retry_is_not_claimable_until_not_before;
]]
