open Masc
module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Sweep = Lane_addon_orphan_body_sweep
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let updated value = get (Result.map_error Owner.update_error_to_string value)
let some = function Some value -> value | None -> Alcotest.fail "missing original"
let with_store f =
  let parent = Filename.temp_dir "addon-body-sweep" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () ->
    let root = Filename.concat parent "store" in f root (Store.create ~root))
let body_path root ~scope ~request =
  let digest = get (Owner.request_digest request) in
  Filename.concat root (Store.tool_request_body_path ~scope ~request_digest:digest)
let retain store ~scope ~id ~request =
  owned (Owner.retain ~store ~scope ~request_id:id ~installation_id:"installation"
    ~package_id:"package" ~tool:"tool" ~summary:`Null ~request)
let load store ~scope ~id = some (owned (Owner.load ~store ~scope ~request_id:id))
let advance store expected event = match updated (Owner.advance ~store ~expected ~event) with
  | Owner.Stored record -> record
  | Owner.Already_stored _ -> Alcotest.fail "unexpected already-stored event"
  | Owner.Unconfirmed detail -> Alcotest.fail detail
let stage_orphan store ~scope request =
  let bytes = Yojson.Safe.to_string request in
  get (Store.save_tool_request_body store ~scope ~request_digest:(Store.digest bytes) bytes)
let run store = get (Result.map_error Sweep.error_to_string (Sweep.run ~store))
let exists path = Sys.file_exists path

let test_orphan_is_removed_but_active_successor_and_interrupted_archive_survive () =
  with_store (fun root store ->
    let scope = "parent" and child_scope = "different-child-scope" in
    let parent = `Assoc ["kind",`String "parent"] in
    let child = `Assoc ["kind",`String "staged child"] in
    let archived = `Assoc ["kind",`String "archived original"] in
    let orphan = `Assoc ["kind",`String "body only"] in
    retain store ~scope ~id:"parent-id" ~request:parent;
    let successor = owned (Owner.prepare_successor ~store ~scope:child_scope ~request_id:"child-id" ~request:child) in
    let dispatched = advance store (load store ~scope ~id:"parent-id") Progress.Dispatch_intended in
    let refused = advance store dispatched (Progress.Refused {stage=Progress.Execution;evidence=`Null}) in
    ignore (advance store refused (Progress.Successor_intended successor));
    retain store ~scope:"archived-scope" ~id:"archive-id" ~request:archived;
    let record = Owner.listed (load store ~scope:"archived-scope" ~id:"archive-id") in
    (match Owner.settle ~store ~date:"2026-10-27" record with
     | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
    let archived_digest = get (Owner.request_digest archived) in
    let archive_path = Filename.concat root (Store.tool_request_archive_body_path
      ~scope:"archived-scope" ~date:"2026-10-27" ~request_digest:archived_digest) in
    let original_path = body_path root ~scope:"archived-scope" ~request:archived in
    Unix.rename archive_path original_path;
    stage_orphan store ~scope:"orphan-scope" orphan;
    let report = run store in
    Alcotest.(check int) "only the unreferenced body is removed" 1 report.removed;
    Alcotest.(check bool) "an unprotected live body makes the archive read" true
      (report.archive = Sweep.Archive_read);
    Alcotest.(check bool) "orphan is gone" false (exists (body_path root ~scope:"orphan-scope" ~request:orphan));
    Alcotest.(check bool) "active original still loads" true ((load store ~scope ~id:"parent-id").request = parent);
    Alcotest.(check bool) "intent in a different scope still restores its exact body" true
      (owned (Owner.load_successor_request ~store ~scope:child_scope successor) = child);
    Alcotest.(check bool) "interrupted archive body remains available" true (exists original_path);
    (match Owner.settle ~store ~date:"2026-10-27" record with
     | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
    Alcotest.(check bool) "the original settlement can still be retried" true (exists archive_path))

let test_bad_archive_refuses_before_any_removal () = with_store (fun root store ->
  let archived = `Assoc ["kind",`String "archive"] and orphan = `String "orphan" in
  retain store ~scope:"archived" ~id:"id" ~request:archived;
  let record = Owner.listed (load store ~scope:"archived" ~id:"id") in
  (match Owner.settle ~store ~date:"2026-10-27" record with
   | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
  stage_orphan store ~scope:"orphan" orphan;
  let path = Filename.concat root (Store.tool_request_archive_record_path ~scope:"archived"
    ~date:"2026-10-27" ~request_id:"id") in
  get (Fs_compat.save_file_atomic_strict path "{}");
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "bad archive did not reject the inventory");
  Alcotest.(check bool) "unrelated body was not deleted" true (exists (body_path root ~scope:"orphan" ~request:orphan)))

(* Archived records only add protection. When the live records protect every
   live body, the archive is not read: a settled record that would refuse the
   inventory changes nothing. *)
let test_protected_live_bodies_leave_the_archive_unread () = with_store (fun root store ->
  let active = `Assoc ["kind",`String "active"] and archived = `Assoc ["kind",`String "archive"] in
  retain store ~scope:"active" ~id:"active-id" ~request:active;
  retain store ~scope:"archived" ~id:"id" ~request:archived;
  let record = Owner.listed (load store ~scope:"archived" ~id:"id") in
  (match Owner.settle ~store ~date:"2026-10-27" record with
   | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
  let path = Filename.concat root (Store.tool_request_archive_record_path ~scope:"archived"
    ~date:"2026-10-27" ~request_id:"id") in
  get (Fs_compat.save_file_atomic_strict path "{}");
  let report = run store in
  Alcotest.(check int) "nothing is removed" 0 report.removed;
  Alcotest.(check bool) "the archive is not read" true (report.archive = Sweep.Archive_not_needed);
  Alcotest.(check int) "only the live record's digest is counted" 1 report.protected_digests;
  Alcotest.(check bool) "the active original still loads" true
    ((load store ~scope:"active" ~id:"active-id").request = active))

let test_hard_link_refuses_before_any_removal () = with_store (fun root store ->
  let first = `String "one" and second = `String "two" in
  stage_orphan store ~scope:"one" first;
  stage_orphan store ~scope:"two" second;
  let first_path = body_path root ~scope:"one" ~request:first in
  Unix.link first_path (Filename.concat (Filename.dirname root) "extra-link");
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "aliased body did not reject the inventory");
  Alcotest.(check bool) "other candidate remains" true (exists (body_path root ~scope:"two" ~request:second)))

let test_replaced_body_is_not_removed () = with_store (fun root store ->
  let request = `String "staged original" and scope = "scope" in
  stage_orphan store ~scope request;
  let path = body_path root ~scope ~request in
  let before_remove _ =
    Unix.rename path (Filename.concat (Filename.dirname root) "old-body");
    stage_orphan store ~scope request in
  (match Sweep.For_testing.run ~before_remove ~store with
   | Error (Sweep.Removal_incomplete {removed=0;_}) -> ()
   | Error (Sweep.Removal_incomplete _) | Error (Sweep.Inventory_unavailable _) | Ok _ ->
     Alcotest.fail "replacement was not reported as an unconfirmed removal");
  Alcotest.(check bool) "replacement remains" true (exists path))

let test_missing_active_body_is_not_masked_by_another_scope () = with_store (fun root store ->
  let request = `String "shared request" and orphan = `String "unrelated orphan" in
  retain store ~scope:"first" ~id:"first" ~request;
  retain store ~scope:"second" ~id:"second" ~request;
  stage_orphan store ~scope:"other" orphan;
  Sys.remove (body_path root ~scope:"first" ~request);
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "another scope masked a missing active body");
  Alcotest.(check bool) "unrelated orphan was not deleted" true (exists (body_path root ~scope:"other" ~request:orphan)))

let test_two_active_records_can_share_a_body () = with_store (fun root store ->
  let request = `String "shared request" and orphan = `String "unrelated orphan" in
  retain store ~scope:"shared" ~id:"first" ~request;
  retain store ~scope:"shared" ~id:"second" ~request;
  stage_orphan store ~scope:"other" orphan;
  let report = run store in
  Alcotest.(check int) "unrelated orphan is removed" 1 report.removed;
  Alcotest.(check bool) "shared body remains" true (exists (body_path root ~scope:"shared" ~request));
  List.iter (fun id ->
    Alcotest.(check bool) "each original still restores its shared input" true
      ((load store ~scope:"shared" ~id).request = request)) ["first";"second"])

let test_referenced_non_json_body_is_protected_but_not_loadable () = with_store (fun root store ->
  let scope = "owner" and request = `String "original" and orphan = `String "unrelated" in
  retain store ~scope ~id:"id" ~request;
  let record_path = Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest scope) (Store.digest "id" ^ ".json"))) in
  let bytes = "{not-json" in
  let digest = Store.digest bytes in
  get (Store.save_tool_request_body store ~scope ~request_digest:digest bytes);
  let record = Yojson.Safe.from_file record_path in
  let record = match record with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key = "request_digest" then key,`String digest else key,value) fields)
    | _ -> Alcotest.fail "fixture needs an owner record" in
  get (Store.save_tool_request_owner store ~scope ~request_id:"id" record);
  Sys.remove (body_path root ~scope ~request);
  stage_orphan store ~scope:"other" orphan;
  let report = run store in
  Alcotest.(check int) "unrelated orphan is removed" 1 report.removed;
  Alcotest.(check bool) "named body remains" true
    (exists (Filename.concat root (Store.tool_request_body_path ~scope ~request_digest:digest)));
  Alcotest.(check bool) "normal owner load still rejects noncanonical input" true
    (Result.is_error (Owner.load ~store ~scope ~request_id:"id")))

let test_unsafe_staging_entry_aborts_but_regular_partial_stage_is_kept () = with_store (fun root store ->
  let orphan = `String "orphan" in
  stage_orphan store ~scope:"one" orphan;
  let directory = Filename.dirname (body_path root ~scope:"one" ~request:orphan) in
  let stage = Filename.concat directory ".atomic_incomplete.tmp" in
  Unix.symlink (body_path root ~scope:"one" ~request:orphan) stage;
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "unsafe staging entry did not abort");
  Alcotest.(check bool) "orphan is preserved after refusal" true (exists (body_path root ~scope:"one" ~request:orphan));
  Unix.unlink stage;
  get (Fs_compat.save_file_atomic_strict stage "partial, not JSON");
  let report = run store in
  Alcotest.(check int) "safe incomplete staging does not prevent cleanup" 1 report.removed;
  Alcotest.(check bool) "partial staging file is preserved" true (exists stage))

let test_digest_mismatch_aborts_before_removal () = with_store (fun root store ->
  let orphan = `String "unrelated" and original = "original bytes" in
  stage_orphan store ~scope:"valid" orphan;
  let digest = Store.digest original in
  get (Store.save_tool_request_body store ~scope:"invalid" ~request_digest:digest original);
  let path = Filename.concat root (Store.tool_request_body_path ~scope:"invalid" ~request_digest:digest) in
  get (Fs_compat.save_file_atomic_strict path "changed bytes");
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "digest mismatch was accepted");
  Alcotest.(check bool) "unrelated orphan was not deleted" true (exists (body_path root ~scope:"valid" ~request:orphan)))

let test_unreferenced_non_json_body_is_removed () = with_store (fun root store ->
  let bytes = "{incomplete" and scope = "scope" in
  let digest = Store.digest bytes in
  get (Store.save_tool_request_body store ~scope ~request_digest:digest bytes);
  let report = run store in
  Alcotest.(check int) "store permits an unreferenced non-JSON body" 1 report.removed;
  Alcotest.(check bool) "the unreferenced file is gone" false
    (exists (Filename.concat root (Store.tool_request_body_path ~scope ~request_digest:digest))))

let test_sparse_body_mismatch_preserves_other_candidates () = with_store (fun root store ->
  let original = "original" and orphan = `String "unrelated" in
  let digest = Store.digest original in
  stage_orphan store ~scope:"valid" orphan;
  get (Store.save_tool_request_body store ~scope:"sparse" ~request_digest:digest original);
  let path = Filename.concat root (Store.tool_request_body_path ~scope:"sparse" ~request_digest:digest) in
  let fd = Unix.openfile path [Unix.O_WRONLY;Unix.O_TRUNC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    ignore (Unix.LargeFile.lseek fd 8388607L Unix.SEEK_SET);
    ignore (Unix.write_substring fd "x" 0 1));
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "large sparse mismatch was accepted");
  Alcotest.(check bool) "other candidate remains" true (exists (body_path root ~scope:"valid" ~request:orphan)))

let test_sparse_malformed_record_preserves_other_candidates () = with_store (fun root store ->
  let orphan = `String "unrelated" in
  retain store ~scope:"owner" ~id:"id" ~request:(`String "original");
  stage_orphan store ~scope:"valid" orphan;
  let path = Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest "owner") (Store.digest "id" ^ ".json"))) in
  let fd = Unix.openfile path [Unix.O_WRONLY;Unix.O_TRUNC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    ignore (Unix.LargeFile.lseek fd 8388607L Unix.SEEK_SET);
    ignore (Unix.write_substring fd "x" 0 1));
  (match Sweep.run ~store with
   | Error (Sweep.Inventory_unavailable _) -> ()
   | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "malformed sparse record was accepted");
  Alcotest.(check bool) "other candidate remains" true (exists (body_path root ~scope:"valid" ~request:orphan)))

let test_inventory_errors_do_not_disclose_input () =
  let sentinel = "private-sentinel-in-malformed-json" in
  let refuses_without_leak store =
    match Sweep.run ~store with
    | Error (Sweep.Inventory_unavailable _ as error) ->
      Alcotest.(check bool) "error does not expose input bytes" false
        (String_util.contains_substring (Sweep.error_to_string error) sentinel)
    | Error (Sweep.Removal_incomplete _) | Ok _ -> Alcotest.fail "malformed input was accepted" in
  with_store (fun root store ->
    let bytes = "original" in
    let digest = Store.digest bytes in
    get (Store.save_tool_request_body store ~scope:"bad" ~request_digest:digest bytes);
    let path = Filename.concat root (Store.tool_request_body_path ~scope:"bad" ~request_digest:digest) in
    get (Fs_compat.save_file_atomic_strict path ("!" ^ sentinel));
    refuses_without_leak store);
  with_store (fun root store ->
    retain store ~scope:"owner" ~id:"id" ~request:(`String "original");
    let path = Filename.concat root (Filename.concat Store.tool_request_owners_directory
      (Filename.concat (Store.digest "owner") (Store.digest "id" ^ ".json"))) in
    get (Fs_compat.save_file_atomic_strict path ("!" ^ sentinel));
    refuses_without_leak store)

let () = Alcotest.run "lane addon orphan body sweep" ["cleanup", [
  Alcotest.test_case "protect live, successor and archived requests" `Quick test_orphan_is_removed_but_active_successor_and_interrupted_archive_survive;
  Alcotest.test_case "archive corruption aborts before removal" `Quick test_bad_archive_refuses_before_any_removal;
  Alcotest.test_case "protected live bodies leave the archive unread" `Quick test_protected_live_bodies_leave_the_archive_unread;
  Alcotest.test_case "hard linked body aborts before removal" `Quick test_hard_link_refuses_before_any_removal;
  Alcotest.test_case "changed body is retained" `Quick test_replaced_body_is_not_removed;
  Alcotest.test_case "missing body in one scope is not masked" `Quick test_missing_active_body_is_not_masked_by_another_scope;
  Alcotest.test_case "same-scope shared body remains available" `Quick test_two_active_records_can_share_a_body;
  Alcotest.test_case "referenced noncanonical body stays owned" `Quick test_referenced_non_json_body_is_protected_but_not_loadable;
  Alcotest.test_case "staging file safety" `Quick test_unsafe_staging_entry_aborts_but_regular_partial_stage_is_kept;
  Alcotest.test_case "digest mismatch aborts before removal" `Quick test_digest_mismatch_aborts_before_removal;
  Alcotest.test_case "unreferenced non-JSON body can be removed" `Quick test_unreferenced_non_json_body_is_removed;
  Alcotest.test_case "sparse body mismatch aborts before removal" `Quick test_sparse_body_mismatch_preserves_other_candidates;
  Alcotest.test_case "sparse malformed record aborts before removal" `Quick test_sparse_malformed_record_preserves_other_candidates;
  Alcotest.test_case "inventory errors do not disclose input" `Quick test_inventory_errors_do_not_disclose_input;
]]
