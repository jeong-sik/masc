open Masc
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Store = Lane_addon_store
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let updated value = get (Result.map_error Owner.update_error_to_string value)
let some = function Some value -> value | None -> Alcotest.fail "missing original request"
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let scope = "workspace-curator"
let request_id = "original-accepted-work"
let request = `Assoc ["input",`String "Complete original captured input"]
let evidence text = `Assoc ["receipt",`String text]
let before = `Assoc ["ledger",`List [`String "original source"]]
let after = `Assoc ["ledger",`List [`String "original source";`String "original judgment"]]
let judgment = `Assoc ["output",`String "Original domain-validated answer";"usage",`Int 7]
let with_store f =
  let parent = Filename.temp_dir "addon-progress" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "store" in f root (Store.create ~root))
let retain store = Owner.retain ~store ~scope ~request_id ~installation_id:"original-installation"
  ~package_id:"curator" ~tool:"classify" ~request
let load store = some (owned (Owner.load ~store ~scope ~request_id))
let advance store expected event = Owner.advance ~store ~expected ~event
let stored store expected event = match updated (advance store expected event) with
  | Owner.Stored record -> record
  | Owner.Already_stored _ -> Alcotest.fail "new fact reported as a previous publication"
  | Owner.Unconfirmed detail -> Alcotest.fail detail
let invalid store expected event = match advance store expected event with
  | Error (Owner.Invalid_transition _) -> ()
  | Error (Owner.Ownership_error _ | Owner.State_conflict)
  | Ok (Owner.Stored _ | Owner.Already_stored _ | Owner.Unconfirmed _) -> Alcotest.fail "invalid transition accepted"
let events record = Progress.to_json record.Owner.progress
let check_events label expected record = Alcotest.check json label expected (events record)
let dispatch store = owned (retain store); stored store (load store) Progress.Dispatch_intended
let judge store = stored store (dispatch store) (Progress.Judgment_retained judgment)
let commit store = stored store (judge store) (Progress.Commit_intended {before;after})

let test_restart_preserves_unknown_and_late_original_result () = with_store (fun root store ->
  owned (retain store);
  let captured = load (Store.create ~root) in
  Alcotest.(check bool) "capture and Captured are published together" true
    (Progress.phase captured.progress = Progress.Captured && Progress.events captured.progress = []);
  let pending = stored store captured Progress.Dispatch_intended in
  let waiting = stored store pending (Progress.Execution_observed (Progress.Waiting (evidence "original worker accepted"))) in
  let unknown = stored store waiting (Progress.Execution_observed (Progress.Outcome_unknown (evidence "reply lost after admission"))) in
  let reopened = load (Store.create ~root) in
  check_events "restart keeps the entire accepted/unknown history" (events unknown) reopened;
  owned (retain (Store.create ~root));
  check_events "immutable retain never resets progress" (events unknown) (load store);
  invalid store reopened Progress.Dispatch_intended;
  let absent = stored store reopened (Progress.Execution_observed (Progress.Absent (evidence "worker cannot find original id"))) in
  invalid store absent Progress.Dispatch_intended;
  let done_ = stored store absent (Progress.Judgment_retained judgment) in
  Alcotest.(check bool) "late original result retains unknown and absence evidence" true
    (Progress.events done_.progress = Progress.events absent.progress @ [Progress.Judgment_retained judgment]);
  Alcotest.(check string) "original destination survives restart" "original-installation" done_.installation_id;
  Alcotest.check json "original input survives restart" request done_.request)

let test_expected_history_and_exact_uncertain_ack_are_distinct () = with_store (fun root store ->
  let pending = dispatch store in
  let expected = load (Store.create ~root) in
  let observed = Progress.Execution_observed (Progress.Waiting (`Assoc ["z",`Int 1;"a",`String "original"])) in
  let next = stored store pending observed in
  let equivalent = Progress.Execution_observed (Progress.Waiting (`Assoc ["a",`String "original";"z",`Float 1.])) in
  (match updated (advance store expected equivalent) with
   | Owner.Already_stored record -> check_events "exact existing next tail is acknowledged" (events next) record
   | Owner.Stored _ | Owner.Unconfirmed _ -> Alcotest.fail "acknowledgement wrote a new transition");
  (match advance store expected (Progress.Execution_observed (Progress.Outcome_unknown (evidence "different tail"))) with
   | Error Owner.State_conflict -> ()
   | Error (Owner.Ownership_error _ | Owner.Invalid_transition _)
   | Ok (Owner.Stored _ | Owner.Already_stored _ | Owner.Unconfirmed _) -> Alcotest.fail "stale writer erased progress");
  check_events "stale writer leaves original history intact" (events next) (load store);
  (match Owner.retain ~store ~scope ~request_id ~installation_id:"replacement"
      ~package_id:"curator" ~tool:"classify" ~request with
   | Error Owner.Binding_conflict -> ()
   | Error (Owner.Store_unavailable _ | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok () ->
     Alcotest.fail "replacement acquired the advancing original request");
  (* Reusing an old capture to acknowledge the first intent cannot append or
     acknowledge an arbitrary later tail. *)
  owned (retain store);
  let fresh = load store in check_events "retain preserves fresh progress" (events next) fresh)

let test_commit_recovery_uses_original_before_after_and_judgment () = with_store (fun root store ->
  let intent = commit store in
  let domain_path = Filename.concat (Filename.dirname root) "domain-state.json" in
  let save value = get (Fs_compat.save_file_atomic_strict domain_path (Yojson.Safe.to_string value)) in
  let read () = Yojson.Safe.from_string (Fs_compat.load_file domain_path) in
  save before;
  let unknown = stored store intent (Progress.Commit_uncertain (evidence "commit acknowledgement lost")) in
  let restarted = load (Store.create ~root) in
  check_events "uncertain commit survives restart" (events unknown) restarted;
  invalid store restarted Progress.Dispatch_intended;
  invalid store restarted (Progress.Judgment_retained (evidence "replacement judgment"));
  invalid store restarted (Progress.Commit_observed (`Assoc ["ledger",`List []]));
  invalid store restarted (Progress.Commit_retry_observed (`Assoc ["ledger",`List []]));
  let retry = stored store restarted (Progress.Commit_retry_observed (read ())) in
  Alcotest.check json "recording a retry performs no domain write" before (read ());
  save after;
  let finished = stored store retry (Progress.Commit_observed (read ())) in
  (match Progress.phase finished.progress with
   | Progress.Finished commit ->
     Alcotest.check json "original judgment remains bound to commit" judgment commit.judgment;
     Alcotest.check json "original before-state survives recovery" before commit.change.before;
     Alcotest.check json "original expected after-state survives recovery" after commit.change.after
   | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _ | Progress.Committing _
   | Progress.Commit_unknown _ | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ -> Alcotest.fail "commit not confirmed");
  (match updated (advance store retry (Progress.Commit_observed (read ()))) with
   | Owner.Already_stored record -> check_events "lost terminal acknowledgement is idempotent" (events finished) record
   | Owner.Stored _ | Owner.Unconfirmed _ -> Alcotest.fail "terminal acknowledgement republished");
  invalid store finished Progress.Dispatch_intended;
  invalid store finished (Progress.Refused {stage=Progress.Execution;evidence=evidence "late refusal"});
  check_events "reopened terminal preserves all original facts" (events finished) (load (Store.create ~root)))

let test_conflict_and_refusal_are_terminal_facts () = with_store (fun _ store ->
  let intent = commit store in
  let observed = `Assoc ["ledger",`String "another writer committed"] in
  let conflict = stored store intent (Progress.Commit_conflicted observed) in
  invalid store conflict (Progress.Commit_retry_observed before);
  invalid store conflict (Progress.Commit_observed after);
  invalid store conflict Progress.Dispatch_intended;
  (match Progress.phase (load store).progress with
   | Progress.Conflicted (commit,current) ->
     Alcotest.check json "conflict preserves observed state" observed current;
     Alcotest.check json "conflict preserves original judgment" judgment commit.judgment
   | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _ | Progress.Committing _
   | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ -> Alcotest.fail "conflict lost"));
  with_store (fun _ store ->
    owned (retain store);
    let captured = load store in
    invalid store captured (Progress.Refused {stage=Progress.Execution;evidence=evidence "wrong boundary"});
    let refused = stored store captured (Progress.Refused {stage=Progress.Before_dispatch;evidence=evidence "host refused before dispatch"}) in
    invalid store refused Progress.Dispatch_intended);
  with_store (fun _ store ->
    let pending = dispatch store in
    invalid store pending (Progress.Refused {stage=Progress.Before_dispatch;evidence=evidence "cannot undo dispatch intent"});
    let refused = stored store pending (Progress.Refused {stage=Progress.Execution;evidence=evidence "original execution refused"}) in
    invalid store refused (Progress.Judgment_retained judgment))

let replace key value = function
  | `Assoc fields -> `Assoc (List.map (fun (name,old) -> name, if name=key then value else old) fields)
  | _ -> Alcotest.fail "record is not an object"
let test_strict_load_rejects_invalid_or_tampered_history () = with_store (fun root store ->
  let original = commit store in
  let wire = some (get (Store.load_tool_request_owner store ~scope ~request_id)) in
  let event kind fields = `Assoc (("event",`String kind) :: fields) in
  let dispatch = event "dispatch_intended" [] in
  let bad = [
    `List [event "commit_observed" ["after",after]];
    `List [dispatch;dispatch];
    `List [dispatch;event "judgment_retained" ["judgment",judgment];
      event "judgment_retained" ["judgment",evidence "replacement"]];
    `List [event "unknown_event" []];
    `List [event "dispatch_intended" ["event",`String "dispatch_intended"]];
    `List [event "dispatch_intended" ["extra",`Null]];
    `List [dispatch;event "waiting" ["evidence",`Assoc ["same",`Int 1;"same",`Int 2]]];
    `List [dispatch;event "refused" ["stage",`String "unknown";"evidence",`Null]];
    `List [dispatch;event "judgment_retained" ["judgment",judgment];
      event "commit_intended" ["before",before;"after",after];
      event "commit_observed" ["after",before]];
    `Null] in
  List.iter (fun history ->
    get (Store.save_tool_request_owner store ~scope ~request_id (replace "progress" history wire));
    (match Owner.load ~store:(Store.create ~root) ~scope ~request_id with
     | Error (Owner.Store_unavailable _) -> ()
     | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok _ ->
       Alcotest.fail "invalid history became valid or absent");
    (match advance store original (Progress.Commit_observed after) with
     | Error (Owner.Ownership_error (Owner.Store_unavailable _)) -> ()
     | Error (Owner.Ownership_error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _)
         | Owner.State_conflict | Owner.Invalid_transition _)
     | Ok (Owner.Stored _ | Owner.Already_stored _ | Owner.Unconfirmed _) -> Alcotest.fail "invalid original history was overwritten");
    Alcotest.check json "failed update preserves original malformed evidence" history
      (Yojson.Safe.Util.member "progress" (some (get (Store.load_tool_request_owner store ~scope ~request_id))))) bad)

let test_missing_original_cannot_be_recreated_by_update () = with_store (fun root store ->
  let pending = dispatch store in
  let directory = Filename.concat (Filename.concat root "tool-request-owners") (Store.digest scope) in
  Sys.remove (Filename.concat directory (Store.digest request_id ^ ".json"));
  (match advance store pending (Progress.Execution_observed (Progress.Outcome_unknown (evidence "lost reply"))) with
   | Error Owner.State_conflict -> ()
   | Error (Owner.Ownership_error _ | Owner.Invalid_transition _)
   | Ok (Owner.Stored _ | Owner.Already_stored _ | Owner.Unconfirmed _) -> Alcotest.fail "missing original request was recreated");
  Alcotest.(check bool) "update did not mint a new capture" true
    (owned (Owner.load ~store ~scope ~request_id) = None))

let test_explicit_capacity_preserves_original_admission_without_replaying_unknown () = with_store (fun root store ->
  let pending=dispatch store in
  let capacity=stored store pending (Progress.Admission_declined (evidence "worker refused before retention")) in
  let reopened=load (Store.create ~root) in
  Alcotest.(check bool) "restart preserves explicit non-admission" true
    (Progress.phase reopened.progress=Progress.Admission_wait (evidence "worker refused before retention"));
  let retry=stored store reopened Progress.Dispatch_intended in
  Alcotest.(check string) "capacity retries the same original request" capacity.request_id retry.request_id;
  Alcotest.check json "capacity preserves original input" capacity.request retry.request;
  let waiting=stored store retry (Progress.Execution_observed (Progress.Waiting (evidence "accepted"))) in
  invalid store waiting (Progress.Admission_declined (evidence "late capacity cannot undo admission"));
  let unknown=stored store waiting (Progress.Execution_observed (Progress.Outcome_unknown (evidence "reply lost"))) in
  invalid store unknown (Progress.Admission_declined (evidence "unknown is not a non-admission receipt"));
  invalid store unknown Progress.Dispatch_intended;
  let absent=stored store unknown (Progress.Execution_observed (Progress.Absent (evidence "original no longer listed"))) in
  invalid store absent (Progress.Admission_declined (evidence "absence is not capacity"));
  invalid store absent Progress.Dispatch_intended;
  check_events "capacity and uncertainty history survives another handle" (events absent) (load (Store.create ~root)))

module Receipt = Lane_addon_request_receipt
let receipt time payload = get (Receipt.make ~observed_at:time ~payload)
let observe store record event = stored store record (Progress.Observer event)
let test_observer_pending_receipts_survive_domain_completion_and_restart () = with_store (fun root store ->
  owned (retain store);
  let start=receipt 10. (`Assoc ["original_input",request;"actor",`String scope]) in
  let started=observe store (load store) (Receipt.Intended (Receipt.Registration,start)) in
  let pending=stored store started Progress.Dispatch_intended in
  let judged=stored store pending (Progress.Judgment_retained judgment) in
  let committing=stored store judged (Progress.Commit_intended {before;after}) in
  let uncertain=stored store committing (Progress.Commit_uncertain (evidence "original save receipt lost")) in
  let finished=stored store uncertain (Progress.Commit_observed after) in
  let finish_phase=Progress.phase finished.progress in
  let terminal=receipt 8. (`Assoc ["judgment",judgment;"after",after;"timing",`String "observer_only"]) in
  (* Wall time may move backwards. It is neither a duration nor new authority. *)
  let prepared=observe store finished (Receipt.Intended (Receipt.Completion,terminal)) in
  invalid store prepared (Progress.Observer (Receipt.Recorded (Receipt.Completion,terminal.digest)));
  let reopened=load (Store.create ~root) in
  (match Progress.observer reopened.progress with
   | {Receipt.registration=Pending original;completion=Pending last} ->
     Alcotest.check json "first start survives failed observer registration" (Receipt.to_json start) (Receipt.to_json original);
     Alcotest.check json "first terminal survives restart before registration ACK" (Receipt.to_json terminal) (Receipt.to_json last)
   | _ -> Alcotest.fail "pending immutable observer evidence lost");
  let registered=observe store reopened (Receipt.Recorded (Receipt.Registration,start.digest)) in
  let recorded=observe store registered (Receipt.Recorded (Receipt.Completion,terminal.digest)) in
  Alcotest.(check bool) "observer receipt retry preserves completed domain phase" true
    (Progress.phase recorded.progress=finish_phase);
  invalid store recorded Progress.Dispatch_intended;
  invalid store recorded (Progress.Commit_retry_observed before);
  (match Progress.observer (load (Store.create ~root)).progress with
   | {Receipt.registration=Acknowledged original;completion=Acknowledged last} ->
     Alcotest.(check (float 0.)) "original start is not restart time" 10. original.observed_at;
     Alcotest.(check (float 0.)) "clock rollback remains evidence without invented elapsed time" 8. last.observed_at
   | _ -> Alcotest.fail "observer acknowledgements did not survive actual store reopen"))

let test_observer_lost_ack_never_republishes_or_changes_input () = with_store (fun root store ->
  let pending=dispatch store in
  let start=receipt 12. (`Assoc ["input",request]) in
  let prepared=observe store pending (Receipt.Intended (Receipt.Registration,start)) in
  let recorded=observe store prepared (Receipt.Recorded (Receipt.Registration,start.digest)) in
  let path=Filename.concat (Filename.concat (Filename.concat root "tool-request-owners") (Store.digest scope))
      (Store.digest request_id ^ ".json") in
  let bytes=Fs_compat.load_file path and identity=Unix.stat path in
  (match updated (advance store prepared (Progress.Observer (Receipt.Recorded (Receipt.Registration,start.digest)))) with
   | Owner.Already_stored record -> check_events "lost original ACK is acknowledged" (events recorded) record
   | Owner.Stored _ | Owner.Unconfirmed _ -> Alcotest.fail "retry republished original ACK");
  let current=Unix.stat path in
  Alcotest.(check string) "ACK retry keeps actual journal bytes" bytes (Fs_compat.load_file path);
  Alcotest.(check bool) "ACK retry keeps actual journal identity" true
    (identity.st_dev=current.st_dev && identity.st_ino=current.st_ino && identity.st_mtime=current.st_mtime);
  let changed=receipt 99. (`Assoc ["input",request]) in
  invalid store recorded (Progress.Observer (Receipt.Intended (Receipt.Registration,changed)));
  invalid store recorded (Progress.Observer (Receipt.Recorded (Receipt.Registration,changed.digest)));
  let waiting=stored store recorded (Progress.Execution_observed (Progress.Waiting (evidence "same accepted original"))) in
  Alcotest.check json "observer retry cannot replace original captured input" request waiting.request;
  Alcotest.(check bool) "normal execution preserves recorded observation" true
    ((Progress.observer waiting.progress).registration=Receipt.Acknowledged start))

let test_observer_completion_needs_original_terminal_and_keeps_refusal_chain () = with_store (fun _ store ->
  let pending=dispatch store in
  let start=receipt 1. (`Assoc ["input",request]) in
  let pending=observe store pending (Receipt.Intended (Receipt.Registration,start)) in
  let terminal=receipt 2. (`Assoc ["original_refusal",`String "size_refused"]) in
  invalid store pending (Progress.Observer (Receipt.Intended (Receipt.Completion,terminal)));
  let refused=stored store pending (Progress.Refused {stage=Progress.Execution;evidence=evidence "size_refused"}) in
  let prepared=observe store refused (Receipt.Intended (Receipt.Completion,terminal)) in
  let linked=stored store prepared (Progress.Successor_intended {request_id="original-child";request=`Assoc ["child",`Bool true]}) in
  let linked=stored store linked (Progress.Successor_observed "original-child") in
  let registered=observe store linked (Receipt.Recorded (Receipt.Registration,start.digest)) in
  let complete=observe store registered (Receipt.Recorded (Receipt.Completion,terminal.digest)) in
  Alcotest.(check bool) "linking a child preserves the parent's original refusal receipt" true
    ((Progress.observer complete.progress).completion=Receipt.Acknowledged terminal);
  invalid store complete (Progress.Observer (Receipt.Intended (Receipt.Completion,
    receipt 3. (`Assoc ["replacement",`Bool true])))));
  with_store (fun _ store ->
    let judged=judge store in
    let start=receipt 1. (`Assoc ["input",request]) in
    let judged=observe store judged (Receipt.Intended (Receipt.Registration,start)) in
    let terminal=receipt 2. (`Assoc ["output",judgment]) in
    invalid store judged (Progress.Observer (Receipt.Intended (Receipt.Completion,terminal)));
    let intent=stored store judged (Progress.Commit_intended {before;after}) in
    invalid store intent (Progress.Observer (Receipt.Intended (Receipt.Completion,terminal)));
    let unknown=stored store intent (Progress.Commit_uncertain (evidence "not confirmed")) in
    invalid store unknown (Progress.Observer (Receipt.Intended (Receipt.Completion,terminal))))

let test_observer_malformed_receipts_and_order_never_become_valid_history () = with_store (fun root store ->
  let pending=dispatch store in
  let start=receipt 1. (`Assoc ["input",request]) in
  let event=Receipt.event_to_json (Receipt.Intended (Receipt.Registration,start)) in
  let stored_receipt=Receipt.to_json start in
  let invalid_receipts=[replace "digest" (`String "wrong") stored_receipt;
    replace "observed_at" (`Float (-1.)) stored_receipt;
    replace "payload" (`List []) stored_receipt;
    replace "payload" (`Assoc ["input",request;"input",`Null]) stored_receipt;
    `Assoc ["observed_at",`Int 1;"payload",request;"digest",`String start.digest;"extra",`Null]] in
  List.iter (fun malformed ->
    match Receipt.of_json malformed with Error _ -> () | Ok _ -> Alcotest.fail "malformed receipt accepted") invalid_receipts;
  List.iter (fun value -> match Receipt.make ~observed_at:value ~payload:request with
    | Error _ -> () | Ok _ -> Alcotest.fail "invalid observer wall time accepted") [nan;infinity;neg_infinity];
  let wire=some (get (Store.load_tool_request_owner store ~scope ~request_id)) in
  let histories=[`List [event;event];
    `List [Receipt.event_to_json (Receipt.Recorded (Receipt.Registration,start.digest))];
    `List [Receipt.event_to_json (Receipt.Intended (Receipt.Completion,start))];
    `List [replace "receipt" (List.hd invalid_receipts) event];
    `List [event;Receipt.event_to_json (Receipt.Recorded (Receipt.Registration,"wrong"))]] in
  List.iter (fun history ->
    get (Store.save_tool_request_owner store ~scope ~request_id (replace "progress" history wire));
    (match Owner.load ~store:(Store.create ~root) ~scope ~request_id with
     | Error (Owner.Store_unavailable _) -> ()
     | Error (Owner.Invalid_identity _ | Owner.Invalid_request _ | Owner.Binding_conflict) | Ok _ ->
       Alcotest.fail "malformed observer history became valid or absent");
    (match advance store pending (Progress.Execution_observed (Progress.Waiting (`Assoc []))) with
     | Error (Owner.Ownership_error (Owner.Store_unavailable _)) -> ()
     | Error (Owner.Ownership_error (Owner.Invalid_identity _ | Owner.Invalid_request _ | Owner.Binding_conflict)
         | Owner.State_conflict | Owner.Invalid_transition _)
     | Ok _ -> Alcotest.fail "malformed original observer evidence was overwritten")) histories)

let () = Alcotest.run "Original Add-on request progress" ["owner",[
  Alcotest.test_case "restart keeps unknown and late original result" `Quick test_restart_preserves_unknown_and_late_original_result;
  Alcotest.test_case "whole expected history and exact acknowledgement" `Quick test_expected_history_and_exact_uncertain_ack_are_distinct;
  Alcotest.test_case "commit resumes original before after and judgment" `Quick test_commit_recovery_uses_original_before_after_and_judgment;
  Alcotest.test_case "conflict and refusal remain terminal" `Quick test_conflict_and_refusal_are_terminal_facts;
  Alcotest.test_case "malformed history is not absence or replacement" `Quick test_strict_load_rejects_invalid_or_tampered_history;
  Alcotest.test_case "missing original cannot be recreated" `Quick test_missing_original_cannot_be_recreated_by_update;
  Alcotest.test_case "only explicit capacity permits original admission retry" `Quick
    test_explicit_capacity_preserves_original_admission_without_replaying_unknown;
  Alcotest.test_case "observer intents survive domain completion and restart" `Quick
    test_observer_pending_receipts_survive_domain_completion_and_restart;
  Alcotest.test_case "lost observer ACK preserves actual bytes and input" `Quick
    test_observer_lost_ack_never_republishes_or_changes_input;
  Alcotest.test_case "observer terminal preserves refusal and successor history" `Quick
    test_observer_completion_needs_original_terminal_and_keeps_refusal_chain;
  Alcotest.test_case "malformed observer evidence is neither absent nor replaceable" `Quick
    test_observer_malformed_receipts_and_order_never_become_valid_history]]
