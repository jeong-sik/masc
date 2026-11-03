open Masc
module Store = Lane_addon_store
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Inventory = Lane_addon_original_body_inventory
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
let with_runtime_store f =
  let base_path = Filename.temp_dir "addon-body-inventory-runtime" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let runtime_root = Filename.concat base_path ".masc" in
    Unix.mkdir runtime_root 0o700;
    let root = Filename.concat runtime_root "lane-addons" in
    f base_path root (Store.create ~root))
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
let run store = get (Result.map_error Inventory.error_to_string (Inventory.run ~store))
let exists path = Sys.file_exists path
let file_size path = Int64.of_int (Unix.stat path).Unix.st_size

let test_unprotected_body_and_owned_bodies_survive () =
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
    Alcotest.(check int) "the orphan and the body only a settled record names are counted" 2
      report.unprotected_files;
    Alcotest.(check int64) "count reports both bodies' logical bytes"
      (Int64.add (file_size (body_path root ~scope:"orphan-scope" ~request:orphan))
         (file_size original_path)) report.unprotected_logical_bytes;
    Alcotest.(check bool) "unprotected body remains" true (exists (body_path root ~scope:"orphan-scope" ~request:orphan));
    Alcotest.(check bool) "active original still loads" true ((load store ~scope ~id:"parent-id").request = parent);
    Alcotest.(check bool) "intent in a different scope still restores its exact body" true
      (owned (Owner.load_successor_request ~store ~scope:child_scope successor) = child);
    Alcotest.(check bool) "interrupted archive body remains available" true (exists original_path);
    (match Owner.settle ~store ~date:"2026-10-27" record with
     | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
    Alcotest.(check bool) "the original settlement can still be retried" true (exists archive_path))

(* Settled records are never read: a settled record that would refuse the
   inventory changes nothing, with or without an unprotected live body. *)
let test_settled_records_are_not_read () = with_store (fun root store ->
  let active = `Assoc ["kind",`String "active"] and archived = `Assoc ["kind",`String "archive"] in
  let orphan = `String "orphan" in
  retain store ~scope:"active" ~id:"active-id" ~request:active;
  retain store ~scope:"archived" ~id:"id" ~request:archived;
  let record = Owner.listed (load store ~scope:"archived" ~id:"id") in
  (match Owner.settle ~store ~date:"2026-10-27" record with
   | Ok () -> () | Error error -> Alcotest.fail (Owner.settle_error_to_string error));
  let path = Filename.concat root (Store.tool_request_archive_record_path ~scope:"archived"
    ~date:"2026-10-27" ~request_id:"id") in
  get (Fs_compat.save_file_atomic_strict path "{}");
  let report = run store in
  Alcotest.(check int) "no live body lacks digest protection" 0 report.unprotected_files;
  Alcotest.(check int) "only the live record's digest is counted" 1 report.protected_digests;
  stage_orphan store ~scope:"orphan" orphan;
  let report = run store in
  Alcotest.(check int) "an unprotected live body does not make the archive read" 1 report.unprotected_files;
  Alcotest.(check bool) "unrelated body was not deleted" true
    (exists (body_path root ~scope:"orphan" ~request:orphan));
  Alcotest.(check bool) "the active original still loads" true
    ((load store ~scope:"active" ~id:"active-id").request = active))

let test_hard_link_refuses_before_any_removal () = with_store (fun root store ->
  let first = `String "one" and second = `String "two" in
  stage_orphan store ~scope:"one" first;
  stage_orphan store ~scope:"two" second;
  let first_path = body_path root ~scope:"one" ~request:first in
  Unix.link first_path (Filename.concat (Filename.dirname root) "extra-link");
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "aliased body did not reject the inventory");
  Alcotest.(check bool) "other candidate remains" true (exists (body_path root ~scope:"two" ~request:second)))

let test_displaced_unknown_owner_preserves_original_body () = with_runtime_store (fun base_path root store ->
  let request = `String "original with unknown execution" and scope = "scope" and id = "original" in
  retain store ~scope ~id ~request;
  let started = advance store (load store ~scope ~id) Progress.Dispatch_intended in
  ignore (advance store started (Progress.Execution_observed
    (Progress.Outcome_unknown (`Assoc ["cause",`String "reply lost"]))));
  let path = body_path root ~scope ~request in
  let bytes = Fs_compat.load_file path in
  let owner_path = Filename.concat root (Filename.concat Store.tool_request_owners_directory
    (Filename.concat (Store.digest scope) (Store.digest id ^ ".json"))) in
  let aside = Filename.concat base_path "owner-aside.json" in
  Unix.rename owner_path aside;
  List.iter (fun () ->
    let report = get (Result.map_error Inventory.error_to_string (Inventory.run_at_startup ~base_path)) in
    Alcotest.(check int) "the displaced owner's body is not protected by the known inventory" 1 report.unprotected_files;
    Alcotest.(check int64) "the retained body's logical bytes are reported"
      (Int64.of_int (String.length bytes)) report.unprotected_logical_bytes;
    Alcotest.(check string) "repeated startup observation retains exact body bytes" bytes (Fs_compat.load_file path)) [(); ()];
  Unix.rename aside owner_path;
  let restored = load store ~scope ~id in
  Alcotest.(check bool) "restoring the owner makes the exact original readable" true
    (restored.request = request);
  (match Progress.phase restored.progress with
   | Progress.Dispatch_pending (Some (Outcome_unknown _)) -> ()
   | _ -> Alcotest.fail "restoring the owner lost its unknown execution phase"))

let test_missing_active_body_is_not_masked_by_another_scope () = with_store (fun root store ->
  let request = `String "shared request" and orphan = `String "unrelated orphan" in
  retain store ~scope:"first" ~id:"first" ~request;
  retain store ~scope:"second" ~id:"second" ~request;
  stage_orphan store ~scope:"other" orphan;
  Sys.remove (body_path root ~scope:"first" ~request);
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "another scope masked a missing active body");
  Alcotest.(check bool) "unrelated orphan was not deleted" true (exists (body_path root ~scope:"other" ~request:orphan)))

let test_two_active_records_can_share_a_body () = with_store (fun root store ->
  let request = `String "shared request" and orphan = `String "unrelated orphan" in
  retain store ~scope:"shared" ~id:"first" ~request;
  retain store ~scope:"shared" ~id:"second" ~request;
  stage_orphan store ~scope:"other" orphan;
  let report = run store in
  Alcotest.(check int) "unrelated body remains unprotected" 1 report.unprotected_files;
  Alcotest.(check bool) "shared body remains" true (exists (body_path root ~scope:"shared" ~request));
  List.iter (fun id ->
    Alcotest.(check bool) "each original still restores its shared input" true
      ((load store ~scope:"shared" ~id).request = request)) ["first";"second"])

let test_same_digest_in_another_scope_is_not_counted () = with_store (fun root store ->
  let request = `String "shared bytes in two scopes" in
  retain store ~scope:"owned" ~id:"id" ~request;
  stage_orphan store ~scope:"other" request;
  let report = run store in
  Alcotest.(check int) "digest protection is intentionally global across scopes" 0 report.unprotected_files;
  Alcotest.(check int64) "protected bytes are excluded from the count" 0L report.unprotected_logical_bytes;
  Alcotest.(check bool) "the second scope's body is still retained" true
    (exists (body_path root ~scope:"other" ~request)))

let test_missing_runtime_root_reports_empty_without_creating_it () =
  let base_path = Filename.temp_dir "addon-body-inventory-empty" "" in
  Fun.protect ~finally:(fun () -> Unix.rmdir base_path) (fun () ->
    match Inventory.run_at_startup ~base_path with
    | Ok report ->
      Alcotest.(check int) "missing runtime contains no observed files" 0 report.unprotected_files;
      Alcotest.(check int64) "missing runtime contains no observed logical bytes" 0L report.unprotected_logical_bytes;
      Alcotest.(check bool) "observation does not create the runtime root" false
        (Sys.file_exists (Filename.concat base_path ".masc"))
    | Error error -> Alcotest.fail (Inventory.error_to_string error))

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
  Alcotest.(check int) "unrelated body remains unprotected" 1 report.unprotected_files;
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
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "unsafe staging entry did not abort");
  Alcotest.(check bool) "orphan is preserved after refusal" true (exists (body_path root ~scope:"one" ~request:orphan));
  Unix.unlink stage;
  get (Fs_compat.save_file_atomic_strict stage "partial, not JSON");
  let report = run store in
  Alcotest.(check int) "safe incomplete staging is not counted as a live body" 1 report.unprotected_files;
  Alcotest.(check bool) "partial staging file is preserved" true (exists stage))

let test_digest_mismatch_aborts_before_removal () = with_store (fun root store ->
  let orphan = `String "unrelated" and original = "original bytes" in
  stage_orphan store ~scope:"valid" orphan;
  let digest = Store.digest original in
  get (Store.save_tool_request_body store ~scope:"invalid" ~request_digest:digest original);
  let path = Filename.concat root (Store.tool_request_body_path ~scope:"invalid" ~request_digest:digest) in
  get (Fs_compat.save_file_atomic_strict path "changed bytes");
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "digest mismatch was accepted");
  Alcotest.(check bool) "unrelated orphan was not deleted" true (exists (body_path root ~scope:"valid" ~request:orphan)))

let test_unreferenced_non_json_body_is_preserved () = with_store (fun root store ->
  let bytes = "{incomplete" and scope = "scope" in
  let digest = Store.digest bytes in
  get (Store.save_tool_request_body store ~scope ~request_digest:digest bytes);
  let report = run store in
  Alcotest.(check int) "store reports an unreferenced non-JSON body" 1 report.unprotected_files;
  Alcotest.(check bool) "the unreferenced file is preserved" true
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
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "large sparse mismatch was accepted");
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
  (match Inventory.run ~store with
   | Error (Inventory.Inventory_unavailable _) -> ()
   | Ok _ -> Alcotest.fail "malformed sparse record was accepted");
  Alcotest.(check bool) "other candidate remains" true (exists (body_path root ~scope:"valid" ~request:orphan)))

let test_inventory_errors_do_not_disclose_input () =
  let sentinel = "private-sentinel-in-malformed-json" in
  let refuses_without_leak store =
    match Inventory.run ~store with
    | Error (Inventory.Inventory_unavailable _ as error) ->
      Alcotest.(check bool) "error does not expose input bytes" false
        (String_util.contains_substring (Inventory.error_to_string error) sentinel)
    | Ok _ -> Alcotest.fail "malformed input was accepted" in
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

let () = Alcotest.run "lane addon original body inventory" ["inventory", [
  Alcotest.test_case "live and successor requests protect their bodies" `Quick test_unprotected_body_and_owned_bodies_survive;
  Alcotest.test_case "settled records are not read" `Quick test_settled_records_are_not_read;
  Alcotest.test_case "hard linked body refuses the count" `Quick test_hard_link_refuses_before_any_removal;
  Alcotest.test_case "displaced unknown owner retains its original body" `Quick test_displaced_unknown_owner_preserves_original_body;
  Alcotest.test_case "missing body in one scope is not masked" `Quick test_missing_active_body_is_not_masked_by_another_scope;
  Alcotest.test_case "same-scope shared body remains available" `Quick test_two_active_records_can_share_a_body;
  Alcotest.test_case "equal digests are protected across scopes" `Quick test_same_digest_in_another_scope_is_not_counted;
  Alcotest.test_case "missing runtime stays absent" `Quick test_missing_runtime_root_reports_empty_without_creating_it;
  Alcotest.test_case "referenced noncanonical body stays owned" `Quick test_referenced_non_json_body_is_protected_but_not_loadable;
  Alcotest.test_case "staging file safety" `Quick test_unsafe_staging_entry_aborts_but_regular_partial_stage_is_kept;
  Alcotest.test_case "digest mismatch refuses the count" `Quick test_digest_mismatch_aborts_before_removal;
  Alcotest.test_case "unreferenced non-JSON body is preserved" `Quick test_unreferenced_non_json_body_is_preserved;
  Alcotest.test_case "sparse body mismatch refuses the count" `Quick test_sparse_body_mismatch_preserves_other_candidates;
  Alcotest.test_case "sparse malformed record refuses the count" `Quick test_sparse_malformed_record_preserves_other_candidates;
  Alcotest.test_case "inventory errors do not disclose input" `Quick test_inventory_errors_do_not_disclose_input;
]]
