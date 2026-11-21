open Masc
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Progress = Lane_addon_request_progress
module Sweep = Server_settled_archive_sweep
module Consumer = Server_tool_request_consumer

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let date = "2026-10-27"
(* Any consumer's scope; the pass reads every consumer's records alike. *)
let owned = Verifier_review_owner.scope

let with_store f =
  let parent = Filename.temp_dir "settled-sweep" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Unix.chmod path 0o700;
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "store" in f root (Store.create ~root))

let request id = `Assoc ["input",`String id]
let retain ?request_json store ~scope id =
  let request = Option.value request_json ~default:(request id) in
  owned (Owner.retain ~store ~scope ~request_id:id ~installation_id:"original-installation"
    ~package_id:"owner-package" ~tool:"owner-tool" ~summary:`Null ~request);
  match owned (Owner.load ~store ~scope ~request_id:id) with
  | Some original -> original
  | None -> Alcotest.fail "retained original is absent"
let advance store original event =
  match get (Result.map_error Owner.update_error_to_string (Owner.advance ~store ~expected:original ~event)) with
  | Owner.Stored next -> next
  | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "progress event not stored"
let settle store original =
  match Owner.settle ~store ~date (Owner.listed original) with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Owner.settle_error_to_string error)
(* A record nothing names, settled beside the named one in the same scope. *)
let settle_stray store ~scope = settle store (retain store ~scope "stray")
let run store = match Sweep.run ~store with
  | Ok report -> report
  | Error error -> Alcotest.fail (Sweep.error_to_string error)
let refused store = match Sweep.run ~store with
  | Error (Sweep.Sweep_refused _) -> ()
  | Error (Sweep.Removal_stopped _ as error) -> Alcotest.fail (Sweep.error_to_string error)
  | Ok _ -> Alcotest.fail "the sweep deleted from a store it cannot classify"
let archived root ~scope id =
  Sys.file_exists (Filename.concat root (Store.tool_request_archive_record_path ~scope ~date ~request_id:id))
let archive_day root ~scope =
  Filename.concat root (Filename.concat Store.tool_request_archive_directory
    (Filename.concat (Store.digest scope) date))
(* The named settled record stays; the stray settled beside it goes. *)
let check_named_stays root ~scope ~named (report : Sweep.report) =
  Alcotest.(check int) "the named settled record is kept" 1 report.kept_records;
  Alcotest.(check int) "only the record no live record names is deleted" 1 report.removed_records;
  Alcotest.(check bool) "the named record is still archived" true (archived root ~scope named);
  Alcotest.(check bool) "the stray record is gone" false (archived root ~scope "stray")

(* A live record names the successor its progress
   observed. *)
let test_successor_is_named () = with_store (fun root store ->
  let child = retain store ~scope:owned "child" in
  let parent = retain store ~scope:owned "parent" in
  let parent = advance store parent Progress.Dispatch_intended in
  let parent = advance store parent (Progress.Refused {stage=Progress.Execution;evidence=`String "too large"}) in
  let digest = get (Owner.request_digest (request "child")) in
  let parent = advance store parent (Progress.Successor_intended {request_id="child";request_digest=digest}) in
  ignore (advance store parent (Progress.Successor_observed "child"));
  settle store child;
  settle_stray store ~scope:owned;
  let report = run store in
  check_named_stays root ~scope:owned ~named:"child" report;
  Alcotest.(check int) "the live parent is the only live record" 1 report.live_records)

(* A live record also names the replacement its progress observed. *)
let test_replacement_is_named () = with_store (fun root store ->
  let child = retain store ~scope:owned "replacement" in
  let parent = retain store ~scope:owned "conflicted" in
  let parent = advance store parent Progress.Dispatch_intended in
  let parent = advance store parent (Progress.Judgment_retained (`String "judged")) in
  let parent = advance store parent
      (Progress.Commit_intended {before=`String "before";after=`String "after"}) in
  let parent = advance store parent (Progress.Commit_conflicted (`String "other")) in
  let parent = advance store parent
      (Progress.Replacement_intended {request_id="replacement";request=request "replacement"}) in
  ignore (advance store parent (Progress.Replacement_observed "replacement"));
  settle store child;
  settle_stray store ~scope:owned;
  check_named_stays root ~scope:owned ~named:"replacement" (run store))

(* A settle archives only the record, so the pass deletes any body in the
   archive. *)
let test_archived_body_is_deleted () = with_store (fun root store ->
  settle_stray store ~scope:owned;
  let bodies = Filename.concat (archive_day root ~scope:owned) "bodies" in
  Unix.mkdir bodies 0o700;
  let body = Filename.concat bodies "body.json" in
  Out_channel.with_open_bin body (fun channel -> output_string channel "{}");
  let report = run store in
  Alcotest.(check int) "the archived body is deleted" 1 report.removed_bodies;
  Alcotest.(check bool) "the body file is gone" false (Sys.file_exists body))

(* A consumer that settles nothing still has live records, and the pass reads
   every live record. Each consumer is asked, so one added to the type is
   asked too. *)
let test_every_consumer_lets_the_pass_run () =
  List.iter (fun consumer -> with_store (fun root store ->
    let scope = Consumer.scope consumer in
    ignore (retain store ~scope "original");
    settle_stray store ~scope:owned;
    let report = run store in
    Alcotest.(check int) (scope ^ ": its live record is read") 1 report.live_records;
    Alcotest.(check int) (scope ^ ": the record no live record names is deleted") 1
      report.removed_records;
    Alcotest.(check bool) (scope ^ ": the stray record is gone") false
      (archived root ~scope:owned "stray")))
    Consumer.all

let consumer_name = function
  | Consumer.Completion_review -> "Completion_review"
  | Consumer.Goal_proof_review -> "Goal_proof_review"
  | Consumer.Candle_appraisal -> "Candle_appraisal"
  | Consumer.Media_reading -> "Media_reading"

let found_name scope = match Consumer.of_scope scope with
  | Some found -> consumer_name found
  | None -> "no consumer"

(* No two consumers share a scope. *)
let test_a_consumer_is_found_by_its_scope () =
  List.iter (fun consumer ->
    Alcotest.(check string) (Consumer.scope consumer) (consumer_name consumer)
      (found_name (Consumer.scope consumer)))
    Consumer.all

(* The scope each owner module retains its originals under. *)
let test_an_owner_scope_has_its_consumer () =
  List.iter (fun (scope, consumer) ->
    Alcotest.(check string) scope (consumer_name consumer) (found_name scope))
    [ Verifier_review_owner.scope, Consumer.Completion_review
    ; Goal_verifier_worker.scope, Consumer.Goal_proof_review
    ; Server_candle_appraiser.scope, Consumer.Candle_appraisal
    ; Keeper_media_reading_owner.scope, Consumer.Media_reading
    ]

let test_unclaimed_scope_refuses () = with_store (fun root store ->
  settle_stray store ~scope:owned;
  ignore (retain store ~scope:"an-owner-no-sweep-knows" "original");
  refused store;
  Alcotest.(check bool) "a refused pass deletes nothing" true (archived root ~scope:owned "stray"))

let test_unknown_archive_directory_refuses () = with_store (fun root store ->
  settle_stray store ~scope:owned;
  Unix.mkdir (Filename.concat (archive_day root ~scope:owned) "notes") 0o700;
  refused store;
  Alcotest.(check bool) "a refused pass deletes nothing" true (archived root ~scope:owned "stray"))

let () = Alcotest.run "settled archive sweep" ["sweep", [
  Alcotest.test_case "a successor keeps its settled record" `Quick test_successor_is_named;
  Alcotest.test_case "a replacement keeps its settled record" `Quick test_replacement_is_named;
  Alcotest.test_case "an archived body is deleted" `Quick test_archived_body_is_deleted;
  Alcotest.test_case "a live record of each consumer lets the pass run" `Quick
    test_every_consumer_lets_the_pass_run;
  Alcotest.test_case "a scope no owner claims refuses the pass" `Quick test_unclaimed_scope_refuses;
  Alcotest.test_case "an unknown archive directory refuses the pass" `Quick test_unknown_archive_directory_refuses;
]; "consumers", [
  Alcotest.test_case "a consumer is found by its scope" `Quick
    test_a_consumer_is_found_by_its_scope;
  Alcotest.test_case "an owner's scope has its consumer" `Quick test_an_owner_scope_has_its_consumer;
]]
