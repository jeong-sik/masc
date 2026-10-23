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
  ~package_id:"curator" ~tool:"classify" ~summary:`Null ~request
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
      ~package_id:"curator" ~tool:"classify" ~summary:`Null ~request with
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
  let linked=stored store prepared (Progress.Successor_intended
      {request_id="original-child";request_digest=Store.digest "original child request"}) in
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

let test_typed_receipt_sharing_and_strict_replay () =
  let start=receipt 1. (`Assoc ["z",`List [`String "quoted \"input\"";`Float 2.];"a",request]) in
  let registered=get (Progress.append Progress.captured
    (Progress.Observer (Receipt.Intended (Receipt.Registration,start)))) in
  (match (Progress.observer registered).registration with
   | Receipt.Pending original ->
     Alcotest.(check bool) "retain the already validated immutable receipt" true (original==start)
   | Receipt.Unobserved | Receipt.Acknowledged _ -> Alcotest.fail "registration not pending");
  let events=[Progress.Observer (Receipt.Recorded (Receipt.Registration,start.digest));
    Progress.Dispatch_intended;Progress.Judgment_retained judgment;
    Progress.Commit_intended {before;after};Progress.Commit_observed after] in
  let completed=get (List.fold_left (fun state event ->
    Result.bind state (fun state -> Progress.append state event)) (Ok registered) events) in
  let encoded=Progress.to_json completed in
  let restored=get (Progress.of_json encoded) in
  Alcotest.check json "strict replay preserves canonical history" encoded (Progress.to_json restored);
  Alcotest.(check bool) "strict replay preserves original commit" true
    (Progress.phase restored=Progress.phase completed);
  let malformed=[`Assoc ["duplicate",`Int 1;"duplicate",`Int 2];`Float nan] in
  List.iter (fun evidence ->
    match Progress.append Progress.captured (Progress.Refused {stage=Progress.Before_dispatch;evidence}) with
    | Error _ -> () | Ok _ -> Alcotest.fail "public event bypassed payload validation") malformed;
  match Progress.append registered (Progress.Observer (Receipt.Recorded (Receipt.Registration," "))) with
  | Error _ -> () | Ok _ -> Alcotest.fail "blank acknowledgement bypassed validation"

let record_path root = Filename.concat (Filename.concat (Filename.concat root "tool-request-owners") (Store.digest scope))
    (Store.digest request_id ^ ".json")
let body_path root = Filename.concat root
    (Store.tool_request_body_path ~scope ~request_digest:(get (Owner.request_digest request)))
let save path bytes = get (Fs_compat.save_file_atomic_strict path bytes)
let same_file (a : Unix.stats) (b : Unix.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino && a.st_mtime = b.st_mtime

let test_progress_rewrites_only_the_record_and_its_size_ignores_the_request () = with_store (fun root store ->
  let pending = dispatch store in
  let body = body_path root in
  let bytes = Fs_compat.load_file body and identity = Unix.stat body in
  let judged = stored store pending (Progress.Judgment_retained judgment) in
  ignore (stored store (stored store judged (Progress.Commit_intended {before;after})) (Progress.Commit_observed after));
  Alcotest.(check string) "progress keeps the body bytes" bytes (Fs_compat.load_file body);
  Alcotest.(check bool) "progress never writes the body again" true (same_file identity (Unix.stat body));
  let large_input_bytes = 1 lsl 20 in
  with_store (fun small_root small_store ->
    with_store (fun large_root large_store ->
      let large = `Assoc ["input",`String (String.make large_input_bytes 'x')] in
      owned (retain small_store);
      owned (Owner.retain ~store:large_store ~scope ~request_id ~installation_id:"original-installation"
        ~package_id:"curator" ~tool:"classify" ~summary:`Null ~request:large);
      ignore (stored small_store (load small_store) Progress.Dispatch_intended);
      ignore (stored large_store (some (owned (Owner.load ~store:large_store ~scope ~request_id))) Progress.Dispatch_intended);
      Alcotest.(check int) "a record is as large for a large request as for a small one"
        (Unix.stat (record_path small_root)).st_size (Unix.stat (record_path large_root)).st_size)))

let test_an_interrupted_retain_is_completed_by_the_next_retain () = with_store (fun root store ->
  let bytes = Yojson.Safe.to_string (get (Lane_addon_action.canonical request)) in
  get (Store.save_tool_request_body store ~scope ~request_digest:(Store.digest bytes) bytes);
  Alcotest.(check bool) "a body no record names is not an original request" true
    (owned (Owner.load ~store ~scope ~request_id) = None);
  Alcotest.(check int) "and discovery does not list it" 0 (List.length (owned (Owner.discover ~store ~scope)));
  save (body_path root) "changed before any record named it";
  owned (retain store);
  Alcotest.check json "the next retain publishes the body its record names" request (load store).request)

let test_a_record_without_its_body_is_an_error_not_absence () = with_store (fun root store ->
  let pending = dispatch store in
  let wire = some (get (Store.load_tool_request_owner store ~scope ~request_id)) in
  let body = body_path root in
  let original = Fs_compat.load_file body in
  let refused label =
    (match Owner.load ~store:(Store.create ~root) ~scope ~request_id with
     | Error (Owner.Store_unavailable _) -> ()
     | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok _ ->
       Alcotest.fail (label ^ " became valid or absent")) in
  Sys.remove body;
  refused "a missing body";
  Alcotest.(check int) "discovery reads records only, so it still lists that record" 1
    (List.length (owned (Owner.discover ~store:(Store.create ~root) ~scope)));
  (match retain store with
   | Error (Owner.Store_unavailable _) -> ()
   | Error (Owner.Binding_conflict | Owner.Invalid_identity _ | Owner.Invalid_request _) | Ok () ->
     Alcotest.fail "a retain over a record without its body succeeded");
  Alcotest.(check bool) "that retain does not write the missing body again" false (Sys.file_exists body);
  save body (original ^ " ");
  refused "a changed body";
  save body original;
  let named bytes = get (Store.save_tool_request_body store ~scope ~request_digest:(Store.digest bytes) bytes);
    get (Store.save_tool_request_owner store ~scope ~request_id (replace "request_digest" (`String (Store.digest bytes)) wire)) in
  named {|{"z":1,"a":2}|};
  refused "a body that is not canonical JSON";
  named (Yojson.Safe.to_string (`Assoc ["input",`String "another captured input"]));
  let renamed = Fs_compat.load_file (record_path root) in
  (match advance store pending (Progress.Execution_observed (Progress.Waiting (evidence "late"))) with
   | Error Owner.State_conflict -> ()
   | Error (Owner.Ownership_error _ | Owner.Invalid_transition _)
   | Ok (Owner.Stored _ | Owner.Already_stored _ | Owner.Unconfirmed _) ->
     Alcotest.fail "progress landed on a record that names another request");
  Alcotest.(check string) "the refused progress leaves that record as it was" renamed
    (Fs_compat.load_file (record_path root)))

let test_original_preparation_survives_partial_publication () = with_store (fun root store ->
  let judged=judge store in
  let intended:Progress.preparation_intent={request_id="original-required-child";
    request=`Assoc ["input",request;"original_authority",`List [`String "first";`String "second"]]} in
  let pending=stored store judged (Progress.Preparation_intended intended) in
  let reopened=load (Store.create ~root) in
  Alcotest.(check bool) "preparation is separate from a Memory commit attempt" true
    (Progress.phase reopened.progress=Progress.Judged judgment);
  Alcotest.(check bool) "full immutable child survives interruption before publication" true
    (Progress.preparation reopened.progress=Some (Progress.Preparation_pending intended));
  invalid store reopened (Progress.Commit_intended {before;after});
  invalid store reopened (Progress.Preparation_observed "replacement-child");
  invalid store reopened (Progress.Preparation_intended {intended with request_id="replacement-child"});
  let child_scope="original-prerequisite" in
  owned (Owner.retain ~store ~scope:child_scope ~request_id:intended.request_id
    ~installation_id:pending.installation_id ~package_id:pending.package_id ~tool:pending.tool
    ~summary:`Null ~request:intended.request);
  let child=some (owned (Owner.load ~store:(Store.create ~root) ~scope:child_scope ~request_id:intended.request_id)) in
  Alcotest.check json "actual prerequisite publication preserves the whole original" intended.request child.request;
  let acknowledged=stored store reopened (Progress.Preparation_observed child.request_id) in
  Alcotest.(check bool) "publication ACK does not fabricate Memory commit" true
    (Progress.phase acknowledged.progress=Progress.Judged judgment);
  Alcotest.(check bool) "restart restores exact acknowledged prerequisite" true
    (Progress.preparation (load (Store.create ~root)).progress=Some (Progress.Preparation_confirmed intended));
  invalid store acknowledged (Progress.Preparation_observed intended.request_id);
  let committing=stored store acknowledged (Progress.Commit_intended {before;after}) in
  let finished=stored store committing (Progress.Commit_observed after) in
  Alcotest.(check bool) "actual later disposition retains original prerequisite" true
    (Progress.preparation finished.progress=Some (Progress.Preparation_confirmed intended));
  let history=Progress.to_json pending.progress in
  let malformed=`Assoc ["event",`String "preparation_observed";"request_id",`String intended.request_id;
    "request_id",`String "replacement"] in
  let history=match history with `List events -> `List (events@[malformed])
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> Alcotest.fail "expected event history" in
  Alcotest.(check bool) "duplicate prerequisite identity never parses as an acknowledgement" true
    (Result.is_error (Progress.of_json history)))

let test_conflicted_replacement_survives_partial_child_publication () = with_store (fun root store ->
  let judged=judge store in
  let prerequisite:Progress.preparation_intent={request_id="original-gate";request=`Assoc ["gate",request]} in
  let prepared=stored store judged (Progress.Preparation_intended prerequisite) in
  let prepared=stored store prepared (Progress.Preparation_observed prerequisite.request_id) in
  let registration=receipt 1. (`Assoc ["original",request]) in
  let registered=observe store prepared (Receipt.Intended (Receipt.Registration,registration)) in
  let registered=observe store registered (Receipt.Recorded (Receipt.Registration,registration.digest)) in
  let committing=stored store registered (Progress.Commit_intended {before;after}) in
  let conflict=stored store committing (Progress.Commit_conflicted (evidence "known original basis superseded")) in
  let terminal=receipt 2. (`Assoc ["original_conflict",events conflict]) in
  let conflict=observe store conflict (Receipt.Intended (Receipt.Completion,terminal)) in
  let intended:Progress.preparation_intent={request_id="one-original-replacement";
    request=get (Lane_addon_action.canonical
      (`Assoc ["original_source",request;"current_basis",`List [`String "later Memory"]]))} in
  let pending=stored store conflict (Progress.Replacement_intended intended) in
  let reopened=load (Store.create ~root) in
  Alcotest.(check bool) "restart retains full replacement intent without changing the original conflict" true
    (Progress.replacement reopened.progress=Some (Progress.Preparation_pending intended)
     && Progress.phase reopened.progress=Progress.phase conflict.progress);
  Alcotest.(check bool) "replacement is orthogonal to prerequisite and observer evidence" true
    (Progress.preparation reopened.progress=Progress.preparation conflict.progress
     && Progress.observer reopened.progress=Progress.observer conflict.progress);
  invalid store reopened (Progress.Replacement_observed "different-child");
  invalid store reopened (Progress.Replacement_intended intended);
  invalid store reopened (Progress.Replacement_intended {intended with request=`Assoc ["changed",`Bool true]});
  invalid store reopened Progress.Dispatch_intended;
  invalid store reopened (Progress.Commit_retry_observed before);
  let child_scope="original-replacement" in
  owned (Owner.retain ~store ~scope:child_scope ~request_id:intended.request_id
    ~installation_id:pending.installation_id ~package_id:pending.package_id ~tool:pending.tool
    ~summary:`Null ~request:intended.request);
  let child=some (owned (Owner.load ~store:(Store.create ~root) ~scope:child_scope ~request_id:intended.request_id)) in
  Alcotest.check json "actual retained child matches the whole immutable intent" intended.request child.request;
  let acknowledged=stored store reopened (Progress.Replacement_observed child.request_id) in
  let path=Filename.concat (Filename.concat (Filename.concat root "tool-request-owners") (Store.digest scope))
    (Store.digest request_id ^ ".json") in
  let bytes=Fs_compat.load_file path and identity=Unix.stat path in
  (match updated (advance store reopened (Progress.Replacement_observed child.request_id)) with
   | Owner.Already_stored record -> check_events "lost child publication ACK is idempotent" (events acknowledged) record
   | Owner.Stored _ | Owner.Unconfirmed _ -> Alcotest.fail "lost replacement ACK rewrote its original journal");
  let current=Unix.stat path in
  Alcotest.(check bool) "lost ACK keeps original parent bytes and inode" true
    (bytes=Fs_compat.load_file path && identity.st_ino=current.st_ino && identity.st_dev=current.st_dev);
  let completed=observe store acknowledged (Receipt.Recorded (Receipt.Completion,terminal.digest)) in
  let child_path=Filename.concat (Filename.concat (Filename.concat root "tool-request-owners") (Store.digest child_scope))
    (Store.digest intended.request_id ^ ".json") in
  Sys.remove child_path;
  let restored=load (Store.create ~root) in
  Alcotest.(check bool) "missing once-published child does not erase the parent's exact confirmed identity" true
    (Progress.replacement restored.progress=Some (Progress.Preparation_confirmed intended)
     && Progress.preparation restored.progress=Progress.preparation conflict.progress
     && Progress.phase restored.progress=Progress.phase conflict.progress
     && Progress.observer restored.progress=Progress.observer completed.progress);
  invalid store restored (Progress.Replacement_intended {intended with request_id="replacement-after-missing-child"});
  invalid store restored (Progress.Replacement_observed intended.request_id);
  invalid store restored Progress.Dispatch_intended)

let test_replacement_cannot_infer_away_unknown_or_other_phases () =
  let fold events=get (List.fold_left (fun state event ->
    Result.bind state (fun state -> Progress.append state event)) (Ok Progress.captured) events) in
  let dispatch=[Progress.Dispatch_intended] in
  let judged=dispatch@[Progress.Judgment_retained judgment] in
  let committing=judged@[Progress.Commit_intended {before;after}] in
  let refused=dispatch@[Progress.Refused {stage=Progress.Execution;evidence=evidence "not a basis conflict"}] in
  let child:Progress.preparation_intent={request_id="must-not-dispatch";request} in
  let successor:Progress.successor={request_id=child.request_id;request_digest=get (Owner.request_digest child.request)} in
  let invalid_histories=[[];dispatch;
    dispatch@[Progress.Execution_observed (Progress.Outcome_unknown (evidence "accepted but reply lost"))];
    judged;committing;committing@[Progress.Commit_uncertain (evidence "Memory effect unknown")];
    committing@[Progress.Commit_observed after];refused;
    refused@[Progress.Successor_intended successor];
    refused@[Progress.Successor_intended successor;Progress.Successor_observed child.request_id]] in
  List.iter (fun history ->
    let state=fold history in
    List.iter (fun event -> match Progress.append state event with
      | Error _ -> () | Ok _ -> Alcotest.fail "a non-conflicted original acquired replacement authority")
      [Progress.Replacement_intended child;Progress.Replacement_observed child.request_id]) invalid_histories

let test_replacement_strict_codec_rejects_malformed_and_changed_intents () =
  let state=get (Progress.append Progress.captured Progress.Dispatch_intended) in
  let state=get (Progress.append state (Progress.Judgment_retained judgment)) in
  let state=get (Progress.append state (Progress.Commit_intended {before;after})) in
  let state=get (Progress.append state (Progress.Commit_conflicted (evidence "known conflict"))) in
  let history=match Progress.to_json state with `List events -> events
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> Alcotest.fail "expected event list" in
  let intent=`Assoc ["event",`String "replacement_intended";"request_id",`String "one-child";"request",request] in
  let ack=`Assoc ["event",`String "replacement_observed";"request_id",`String "one-child"] in
  let malformed=[
    [ack];[intent;intent];[intent;replace "request_id" (`String "changed-child") ack];[intent;ack;ack];
    [replace "request_id" (`String " ") intent];
    [`Assoc ["event",`String "replacement_intended";"request_id",`String "one-child"]];
    [`Assoc ["event",`String "replacement_intended";"request_id",`String "one-child";
      "request_id",`String "changed";"request",request]];
    [replace "request" (`Assoc ["duplicate",`Int 1;"duplicate",`Int 2]) intent];
    [`Assoc ["event",`String "replacement_observed";"request_id",`String "one-child";"extra",`Null]];
    [replace "event" (`String "unknown_replacement") intent]] in
  List.iter (fun tail -> match Progress.of_json (`List (history@tail)) with
    | Error _ -> () | Ok _ -> Alcotest.fail "malformed replacement history became valid") malformed

let test_staged_successor_input_survives_publication_cuts () = with_store (fun root store ->
  let child_id="one-retry-child" in
  let child_request=`Assoc ["parent",request;"authority",`String "original replay"] in
  let child_scope="retry-fixture" in
  let successor=owned (Owner.prepare_successor ~store ~scope:child_scope ~request_id:child_id ~request:child_request) in
  let reopen ()=Store.create ~root in
  Alcotest.(check bool) "staging publishes no owner record" true
    (owned (Owner.load ~store:(reopen ()) ~scope:child_scope ~request_id:child_id)=None);
  Alcotest.(check int) "staged bodies are not discoverable requests" 0
    (List.length (owned (Owner.discover ~store:(reopen ()) ~scope:child_scope)));
  let original=dispatch store in
  let refused=stored store original (Progress.Refused {stage=Progress.Execution;evidence=evidence "retry required"}) in
  ignore (stored store refused (Progress.Successor_intended successor));
  let pending=load (reopen ()) in
  Alcotest.(check bool) "restart restores the exact digest intent before child publication" true
    (match Progress.phase pending.progress with
     | Progress.Subdividing (_,intent) -> intent=successor
     | _ -> false);
  let restored=owned (Owner.load_successor_request ~store:(reopen ()) ~scope:child_scope successor) in
  Alcotest.check json "retained intent resolves the complete original child" child_request restored;
  owned (Owner.retain ~store ~scope:child_scope ~request_id:child_id
    ~installation_id:pending.installation_id ~package_id:pending.package_id ~tool:pending.tool
    ~summary:`Null ~request:restored);
  let child=some (owned (Owner.load ~store:(reopen ()) ~scope:child_scope ~request_id:child_id)) in
  Alcotest.(check string) "child publication names the staged digest" successor.request_digest child.request_digest;
  let acknowledged=stored store pending (Progress.Successor_observed child_id) in
  check_events "restart preserves the same child acknowledgement" (events acknowledged) (load (reopen ()));
  let path=Filename.concat root (Store.tool_request_body_path ~scope:child_scope ~request_digest:successor.request_digest) in
  let bytes=Fs_compat.load_file path in
  let refuses ()=Alcotest.(check bool) "missing or changed staged input cannot be reconstructed" true
    (Result.is_error (Owner.load_successor_request ~store:(reopen ()) ~scope:child_scope successor)) in
  save path (bytes ^ " "); refuses ();
  Sys.remove path; refuses ();
  Alcotest.(check bool) "a digest cannot address an arbitrary path" true
    (Result.is_error (Store.load_tool_request_body store ~scope:child_scope ~request_digest:"../outside")))

let () = Alcotest.run "Original Add-on request progress" ["owner",[
  Alcotest.test_case "staged successor body survives intent/record/ACK cuts and rejects corruption" `Quick
    test_staged_successor_input_survives_publication_cuts;
  Alcotest.test_case "conflicted replacement survives actual partial child publication and lost ACK" `Quick
    test_conflicted_replacement_survives_partial_child_publication;
  Alcotest.test_case "replacement cannot infer away unknown or non-conflicted work" `Quick
    test_replacement_cannot_infer_away_unknown_or_other_phases;
  Alcotest.test_case "replacement strict codec refuses malformed changed or duplicate intents" `Quick
    test_replacement_strict_codec_rejects_malformed_and_changed_intents;
  Alcotest.test_case "opaque receipt reuse and strict replay" `Quick
    test_typed_receipt_sharing_and_strict_replay;
  Alcotest.test_case "original prerequisite publication survives restart without attempting Memory" `Quick
    test_original_preparation_survives_partial_publication;
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
    test_observer_malformed_receipts_and_order_never_become_valid_history;
  Alcotest.test_case "progress rewrites only the record, whatever the request size" `Quick
    test_progress_rewrites_only_the_record_and_its_size_ignores_the_request;
  Alcotest.test_case "the next retain completes an interrupted one" `Quick
    test_an_interrupted_retain_is_completed_by_the_next_retain;
  Alcotest.test_case "a record without its body is an error, not absence" `Quick
    test_a_record_without_its_body_is_an_error_not_absence]]
