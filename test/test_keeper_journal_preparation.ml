open Alcotest
open Masc
module Journal = Keeper_journal_preparation
module Store = Keeper_chat_operation_store

let ok = function Ok value -> value | Error cause -> fail (Journal.error_message cause)
let store_ok = function Ok value -> value | Error cause -> fail (Store.error_to_string cause)
let contents path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let digest text = Digestif.SHA256.(digest_string text |> to_hex)
let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect ~finally:(fun () -> check bool "database closed" true (Sqlite3.db_close db)) (fun () -> f db)
let sql db statement =
  let rc = Sqlite3.exec db statement in
  if rc<>Sqlite3.Rc.OK then fail (Sqlite3.errmsg db)
let scalar db query =
  let value = ref None in
  let rc = Sqlite3.exec db ~cb:(fun row _ -> value := row.(0)) query in
  if rc<>Sqlite3.Rc.OK then fail (Sqlite3.errmsg db);
  match !value with Some value -> value | None -> fail "missing scalar"
let rec remove path = match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | {Unix.st_kind=(S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK);_} -> Unix.unlink path
let with_workspace f =
  let directory = Filename.temp_dir "keeper-journal-bundle-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> remove directory) (fun () ->
    let base_path = Filename.concat directory "workspace" in
    let run_dir = Filename.concat directory "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    let config = Workspace.default_config base_path in
    let path = Store.path_for_keeper ~keepers_runtime_dir:(Workspace.keepers_runtime_dir config)
      ~keeper_name:"imp" in
    Fs_compat.mkdir_p (Filename.dirname path);
    let store = Store.open_or_create ~path |> store_ok in
    let operation_id = Keeper_chat_operation.Operation_id.of_string "original-request"
      |> (function Ok id -> id | Error detail -> fail detail) in
    ignore (Store.submit store ~now:1. ~operation_id ~source:(`Assoc [])
      ~input:(`Assoc ["message",`String "preserve my queued request"]) |> store_ok);
    Store.close store |> store_ok;
    with_db path (fun db ->
      let next = scalar db "SELECT next_sequence FROM metadata" in
      sql db "BEGIN IMMEDIATE";
      sql db "DROP TABLE input_checkpoints"; sql db "DROP TABLE input_history";
      sql db "DROP TABLE metadata";
      sql db "CREATE TABLE metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema TEXT NOT NULL CHECK (schema = 'masc.keeper_chat_operations.v2'), next_sequence INTEGER NOT NULL CHECK (next_sequence >= 0)) STRICT";
      sql db ("INSERT INTO metadata VALUES(1, 'masc.keeper_chat_operations.v2', " ^ next ^ ")");
      sql db "PRAGMA user_version=2"; sql db "COMMIT");
    f ~base_path ~run_dir ~path)
let plan base_path = Journal.assess ~base_path ~keeper_name:"imp" |> ok
let bundle_path base_path id =
  Filename.concat (Filename.concat (Filename.concat (Filename.concat base_path Common.masc_dirname)
    "upgrades") "journals") id
let published = function
  | Journal.Published receipt -> receipt
  | Publication_unconfirmed _ -> fail "normal publication was not confirmed"
let expect_failure expected = function
  | Ok _ -> fail "unsafe journal preparation succeeded"
  | Error cause -> check bool (Journal.error_message cause) true (cause.Journal.failure=expected)

let test_bundle_publication_and_readonly_recovery () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let receipt = Journal.prepare ~run_dir (plan base_path) |> ok |> published in
  check string "source never replaced" original (contents path);
  let id = Journal.bundle_id receipt in
  let directory = bundle_path base_path id in
  check int "bundle directory private" 0o700 (Unix.stat directory).st_perm;
  List.iter (fun file -> check int "bundle file private" 0o600 (Unix.stat (Filename.concat directory file)).st_perm)
    ["original.sqlite3";"prepared.sqlite3";"manifest.json"];
  check string "original bytes retained" original (contents (Filename.concat directory "original.sqlite3"));
  let manifest_before = contents (Filename.concat directory "manifest.json") in
  let recovered = Journal.load_recovery ~base_path ~bundle_id:id |> ok in
  check bool "restart verifies same bundle" true
    (Yojson.Safe.equal (Journal.receipt_to_json receipt) (Journal.receipt_to_json recovered));
  check bool "copy is never installation authority" false
    Yojson.Safe.Util.(Journal.receipt_to_json recovered |> member "ready_to_install" |> to_bool);
  check string "verification leaves manifest bytes unchanged" manifest_before
    (contents (Filename.concat directory "manifest.json"));
  with_db (Filename.concat directory "prepared.sqlite3") (fun db ->
    check string "unknown prior history retained" "prior_unavailable" (scalar db "SELECT basis FROM input_history"));
  check string "verification leaves live source unchanged" original (contents path))

let test_stale_plan_and_active_owner () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let observed = plan base_path in
  write path (original ^ "changed after assessment");
  expect_failure Journal.Source_changed (Journal.prepare ~run_dir observed);
  write path original;
  let same_bytes = plan base_path in
  let replacement = path ^ ".replacement" in
  write replacement original;
  Unix.rename replacement path;
  expect_failure Journal.Source_changed (Journal.prepare ~run_dir same_bytes);
  let observed = plan base_path in
  match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
  | Base_path_acquired lease ->
    Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease) (fun () ->
      expect_failure Journal.Workspace_in_use (Journal.prepare ~run_dir observed);
      check string "active original preserved" original (contents path))
  | Base_path_already_owned _ | Base_path_rejected _ -> fail "fixture lease unavailable")

let test_companions_are_evidence () = with_workspace (fun ~base_path ~run_dir ~path ->
  let observed = plan base_path in
  let companion = path ^ "-wal" in
  Unix.symlink path companion;
  expect_failure (Journal.Companion_present companion) (Journal.prepare ~run_dir observed);
  check bool "companion is not removed or followed" true ((Unix.lstat companion).st_kind=Unix.S_LNK))

let sync_directory path =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let test_changed_source_after_copy_retains_unpublished_backup () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let observed = plan base_path in
  let changed = original ^ "edited during preparation" in
  let result = Journal.For_testing.prepare ~run_dir observed
    ~before_publication:(fun () -> write path changed) ~sync_manifest_parent:sync_directory in
  expect_failure Journal.Source_changed result;
  let id = match result with
    | Error {Journal.bundle_id=Some id;_} -> id
    | Error {bundle_id=None;_} | Ok _ -> fail "partial bundle identity was lost" in
  let directory = bundle_path base_path id in
  check string "concurrent editor is never overwritten" changed (contents path);
  check string "private original remains inspectable" original (contents (Filename.concat directory "original.sqlite3"));
  check bool "stale source never gets a published manifest" false (Sys.file_exists (Filename.concat directory "manifest.json")))

let test_manifest_sync_uncertainty_is_not_no_publication () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let result = Journal.For_testing.prepare ~run_dir (plan base_path)
    ~before_publication:(fun () -> ())
    ~sync_manifest_parent:(fun _ -> raise (Sys_error "manifest parent sync failed")) |> ok in
  let receipt = match result with
    | Journal.Publication_unconfirmed receipt -> receipt
    | Published _ -> fail "unconfirmed publication was reported confirmed" in
  ignore (Journal.load_recovery ~base_path ~bundle_id:(Journal.bundle_id receipt) |> ok);
  check string "uncertain private publication does not modify source" original (contents path))

let test_hash_rewrite_cannot_hide_changed_prepared_cells () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let receipt = Journal.prepare ~run_dir (plan base_path) |> ok |> published in
  let id = Journal.bundle_id receipt in
  let directory = bundle_path base_path id in
  let prepared = Filename.concat directory "prepared.sqlite3" in
  let next_sequence = with_db prepared (fun db ->
    sql db "UPDATE metadata SET next_sequence=next_sequence+1";
    scalar db "SELECT next_sequence FROM metadata") in
  let manifest_path = Filename.concat directory "manifest.json" in
  let json = Yojson.Safe.from_string (contents manifest_path) in
  let fields = match json with `Assoc fields -> fields | _ -> fail "manifest is not an object" in
  write manifest_path (Yojson.Safe.to_string (`Assoc
    (("prepared_sha256",`String (digest (contents prepared)))::
     ("next_sequence",`String next_sequence)::
     List.remove_assoc "next_sequence" (List.remove_assoc "prepared_sha256" fields))));
  (match Journal.load_recovery ~base_path ~bundle_id:id with
   | Error _ -> () | Ok _ -> fail "rewritten hash hid changed original sequence");
  check string "invalid recovery never replaces source" original (contents path))

let test_cancellation_releases_lease_and_preserves_partial_evidence () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let cancellation = Eio.Cancel.Cancelled (Failure "pre-publication cancellation") in
  (match Journal.For_testing.prepare ~run_dir (plan base_path)
      ~before_publication:(fun () -> raise cancellation) ~sync_manifest_parent:sync_directory with
   | Ok _ | Error _ -> fail "cancellation became a normal publication result"
   | exception (Eio.Cancel.Cancelled _ as cause) ->
     check bool "original cancellation propagates" true (cause==cancellation));
  let directory = Filename.concat (Filename.concat (Filename.concat base_path Common.masc_dirname) "upgrades") "journals" in
  let id = match Sys.readdir directory |> Array.to_list with
    | [id] -> id | [] | _::_::_ -> fail "cancelled preparation lost its evidence bundle" in
  let partial = Filename.concat directory id in
  check string "cancelled preparation retains original backup" original (contents (Filename.concat partial "original.sqlite3"));
  check bool "cancelled preparation published no manifest" false (Sys.file_exists (Filename.concat partial "manifest.json"));
  check string "cancelled preparation never changes source" original (contents path);
  match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
  | Base_path_acquired lease -> Server_startup_takeover.release_base_path_lease lease
  | Base_path_already_owned _ | Base_path_rejected _ -> fail "cancelled preparation retained the Owner lease")

let () = run "Keeper journal offline bundles"
  ["operator preparation",[
    test_case "publish private evidence and recover read-only" `Quick test_bundle_publication_and_readonly_recovery;
    test_case "stale plan and active Owner refuse preparation" `Quick test_stale_plan_and_active_owner;
    test_case "SQLite companions remain evidence" `Quick test_companions_are_evidence;
    test_case "source edit after copy prevents publication" `Quick test_changed_source_after_copy_retains_unpublished_backup;
    test_case "manifest sync uncertainty preserves published evidence" `Quick test_manifest_sync_uncertainty_is_not_no_publication;
    test_case "recomputed hashes cannot hide changed journal cells" `Quick test_hash_rewrite_cannot_hide_changed_prepared_cells;
    test_case "cancellation releases lease and preserves partial evidence" `Quick test_cancellation_releases_lease_and_preserves_partial_evidence]]
