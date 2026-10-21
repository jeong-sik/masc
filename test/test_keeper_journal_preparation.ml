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
let with_workspace ?(before_close=(fun ~base_path:_ ~store:_ -> ())) f =
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
    before_close ~base_path ~store;
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

let test_workspace_location_is_preserved () = with_workspace (fun ~base_path ~run_dir ~path ->
  let original = contents path in
  let receipt = Journal.prepare ~run_dir (plan base_path) |> ok |> published in
  let id = Journal.bundle_id receipt in
  let files = ["original.sqlite3";"prepared.sqlite3";"manifest.json"] in
  let before = List.map (fun file -> file,contents (Filename.concat (bundle_path base_path id) file)) files in
  let alias = Filename.concat (Filename.dirname base_path) "workspace-alias" in
  Unix.symlink base_path alias;
  let through_alias = Journal.load_recovery ~base_path:alias ~bundle_id:id |> ok in
  check bool "alias of the same physical workspace is accepted" true
    (Yojson.Safe.equal (Journal.receipt_to_json receipt) (Journal.receipt_to_json through_alias));
  Unix.unlink alias;
  let manifest_path = Filename.concat (bundle_path base_path id) "manifest.json" in
  let manifest_before = contents manifest_path in
  let uncached_path = Filename.concat (Filename.dirname base_path) "never-open-recorded-path" in
  let fields = match Yojson.Safe.from_string manifest_before with
    | `Assoc fields -> fields | _ -> fail "manifest is not an object" in
  let recorded_source = Store.path_for_keeper
    ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path:uncached_path) ~keeper_name:"imp" in
  write manifest_path (Yojson.Safe.to_string (`Assoc
    (("base_path",`String uncached_path)::("source_path",`String recorded_source)::
     List.remove_assoc "source_path" (List.remove_assoc "base_path" fields))));
  expect_failure (Journal.Bundle_workspace_mismatch
    {recorded_base_path=uncached_path;current_base_path=base_path})
    (Journal.load_recovery ~base_path ~bundle_id:id);
  check bool "recorded path is never opened or initialized" false (Sys.file_exists uncached_path);
  write manifest_path manifest_before;
  let moved = Filename.concat (Filename.dirname base_path) "moved-workspace" in
  Unix.rename base_path moved;
  expect_failure (Journal.Bundle_workspace_mismatch
    {recorded_base_path=base_path;current_base_path=moved})
    (Journal.load_recovery ~base_path:moved ~bundle_id:id);
  List.iter (fun (file,bytes) -> check string ("relocation preserves " ^ file) bytes
    (contents (Filename.concat (bundle_path moved id) file))) before;
  let moved_source = Store.path_for_keeper
    ~keepers_runtime_dir:(Workspace.keepers_runtime_dir (Workspace.default_config moved)) ~keeper_name:"imp" in
  check string "relocation refusal preserves source" original (contents moved_source);
  (* A damaged relocated bundle is still invalid, not merely a location mismatch. *)
  write (Filename.concat (bundle_path moved id) "prepared.sqlite3") "not a SQLite database";
  (match Journal.load_recovery ~base_path:moved ~bundle_id:id with
   | Error {Journal.failure=Bundle_workspace_mismatch _;_} | Ok _ ->
     fail "damaged bundle was classified as internally valid relocation"
   | Error {failure=(Invalid_keeper _ | Workspace_in_use | Unsafe_path _ | Source_absent
       | Source_changed | Companion_present _ | Store_failed _ | Io_failed _ | Invalid_bundle
       | Input_selection_invalid _ | Input_source_changed _ | Input_history_unresolved _ | Input_retention_unconfirmed _);_} -> ()))

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

module Checkpoint = Keeper_checkpoint_store
module Core = Agent_core
let fixture_ok = function Ok value -> value | Error detail -> fail detail
let input_checkpoint pending =
  let context = Core.Context.create_sync () in
  Core.Context.set context "operator-evidence" (`String "retain this context");
  Core.Checkpoint.
    {version=checkpoint_version;session_id="journal-input-trace";agent_name="imp";
     model="fixture-runtime";system_prompt=Some "Retain original system";
     messages=[Core.Types.{role=User;content=[Text "Retained original history"];
       name=None;tool_call_id=None;metadata=["origin",`String "original"]}];
     usage=Core.Types.empty_usage;turn_count=4;created_at=10.;tools=[];
     tool_choice=Some Core.Types.Auto;disable_parallel_tool_use=true;
     temperature=Some 0.5;top_p=Some 0.8;top_k=Some 20;min_p=Some 0.1;
     enable_thinking=Some true;preserve_thinking=Some true;
     response_format=Core.Types.Off;reasoning_effort=None;cache_system_prompt=true;
     context;mcp_sessions=[];working_context=Some (`Assoc ["retained",`Bool true]);
     pending_input=(if pending then Some Core.Agent_input_request.
       {run_id="original-run";request={request_id="original-request";
        participant_name=Some "operator";question="Original question?";
        schema=Some (`Assoc ["type",`String "string"]);timeout_s=None;created_at=1.}}
       else None)}
let input_directory base_path id =
  Filename.concat (Filename.concat (Filename.concat (Filename.concat base_path Common.masc_dirname)
    "upgrades") "journal-inputs") id
let with_input_result ?(before_close=(fun ~base_path:_ ~store:_ ~snapshot:_ -> ())) ~pending f =
  let checkpoint = input_checkpoint pending in
  let trace = Keeper_id.Trace_id.of_string checkpoint.session_id |> fixture_ok in
  let snapshot = match Checkpoint.exact_snapshot_of_value ~expected_session_id:trace checkpoint with
    | Ok snapshot -> snapshot | Error cause -> fail (Checkpoint.checkpoint_ref_load_error_to_string cause) in
  with_workspace ~before_close:(fun ~base_path ~store -> before_close ~base_path ~store ~snapshot)
    (fun ~base_path ~run_dir ~path ->
  let session_dir = Filename.concat (Keeper_fs.session_store_path_for_runtime_root
    (Filename.concat base_path Common.masc_dirname)) checkpoint.session_id in
  Fs_compat.mkdir_p session_dir;
  let canonical = Checkpoint.agent_core_checkpoint_path ~session_dir ~session_id:checkpoint.session_id in
  write canonical (Checkpoint.exact_snapshot_canonical_bytes snapshot); Unix.chmod canonical 0o600;
  let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String "imp";
    "trace_id",`String checkpoint.session_id;"activation_mode",`String "manual"]) |> fixture_ok in
  let metadata = Filename.concat (Common.keepers_runtime_dir_of_base ~base_path)
    (Keeper_runtime_root_entry.keeper_basename ~keeper_name:"imp" Keeper_runtime_root_entry.Metadata) in
  write metadata (Keeper_meta_json.current_write_json meta |> fixture_ok |> Yojson.Safe.to_string);
  Unix.chmod metadata 0o600;
  let bundle = Journal.prepare ~run_dir (plan base_path) |> ok |> published in
  let observed = Journal.assess_input ~base_path ~bundle_id:(Journal.bundle_id bundle)
    ~trace_id:checkpoint.session_id in
  f ~base_path ~run_dir ~path ~session_dir ~canonical ~metadata ~snapshot ~bundle observed)
let with_input ~pending f = with_input_result ~pending (fun ~base_path ~run_dir ~path ~session_dir
    ~canonical ~metadata ~snapshot ~bundle observed ->
  f ~base_path ~run_dir ~path ~session_dir ~canonical ~metadata ~snapshot ~bundle (ok observed))
let adopted = function Journal.Input_adopted receipt -> receipt
  | Input_adoption_unconfirmed _ -> fail "normal input adoption was not confirmed"
let adopt run_dir observed = Journal.adopt_input ~run_dir
  ~expected_checkpoint_sha256:(Journal.input_checkpoint_sha256 observed) observed
let input_retained_path session_dir snapshot =
  Filename.concat (Filename.concat session_dir Checkpoint.retained_dirname)
    ((Checkpoint.exact_snapshot_reference snapshot).sha256 ^ ".json")
let test_input_adoption_preserves_originals_and_full_payload () =
  List.iter (fun pending -> with_input ~pending (fun ~base_path ~run_dir ~path ~session_dir
      ~canonical ~metadata ~snapshot ~bundle observed ->
    let source = contents path in
    let canonical_bytes = contents canonical and metadata_bytes = contents metadata in
    let original_directory = bundle_path base_path (Journal.bundle_id bundle) in
    let before = List.map (fun file -> file,contents (Filename.concat original_directory file))
      ["original.sqlite3";"prepared.sqlite3";"manifest.json"] in
    let receipt = adopt run_dir observed |> ok |> adopted in
    let id = Journal.input_adoption_id receipt in
    let directory = input_directory base_path id in
    let recovered = Journal.load_input_adoption ~base_path ~adoption_id:id |> ok in
    check bool "restart verifies the same explicit selection" true
      (Yojson.Safe.equal (Journal.input_adoption_to_json receipt) (Journal.input_adoption_to_json recovered));
    check string "complete canonical bytes retained" canonical_bytes
      (contents (input_retained_path session_dir snapshot));
    check string "private checkpoint is the exact source" canonical_bytes
      (contents (Filename.concat directory "checkpoint.json"));
    check string "private metadata is exact" metadata_bytes (contents (Filename.concat directory "metadata.json"));
    check int "adoption directory private" 0o700 (Unix.stat directory).st_perm;
    List.iter (fun file -> check int (file ^ " private") 0o600
      (Unix.stat (Filename.concat directory file)).st_perm)
      ["metadata.json";"checkpoint.json";"adopted.sqlite3";"manifest.json"];
    with_db (Filename.concat directory "adopted.sqlite3") (fun db ->
      check string "one selected input reference" "1" (scalar db "SELECT count(*) FROM input_checkpoints");
      check string "omitted traces still lack prior input" "prior_unavailable" (scalar db "SELECT basis FROM input_history"));
    ignore (Journal.load_recovery ~base_path ~bundle_id:(Journal.bundle_id bundle) |> ok);
    List.iter (fun (file,bytes) -> check string ("source bundle preserves " ^ file) bytes
      (contents (Filename.concat original_directory file))) before;
    check string "live journal remains v2 and unchanged" source (contents path);
    check string "canonical is never replaced" canonical_bytes (contents canonical);
    check string "metadata is never replaced" metadata_bytes (contents metadata);
    check bool "adoption does not authorize installation" false
      Yojson.Safe.Util.(Journal.input_adoption_to_json recovered |> member "ready_to_install" |> to_bool)))
    [false;true]
let test_input_selection_revalidation_and_active_owner () =
  with_input ~pending:true (fun ~base_path ~run_dir ~path:_ ~session_dir:_ ~canonical
      ~metadata:_ ~snapshot:_ ~bundle:_ observed ->
    (match Journal.adopt_input ~run_dir ~expected_checkpoint_sha256:(String.make 64 '0') observed with
     | Error cause ->
       check bool "wrong selection creates no bundle" true (cause.Journal.bundle_id=None);
       (match cause.failure with Input_selection_invalid _ -> ()
        | Invalid_keeper _ | Workspace_in_use | Unsafe_path _ | Source_absent | Source_changed
         | Companion_present _ | Store_failed _ | Io_failed _ | Invalid_bundle | Bundle_workspace_mismatch _
         | Input_source_changed _ | Input_history_unresolved _ | Input_retention_unconfirmed _ -> fail "wrong selection failure was lost")
     | Ok _ -> fail "unreviewed checkpoint selection was accepted");
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Base_path_acquired lease ->
       Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease) (fun () ->
         expect_failure Journal.Workspace_in_use (adopt run_dir observed))
     | Base_path_already_owned _ | Base_path_rejected _ -> fail "fixture lease unavailable");
    write canonical (contents canonical ^ " ");
    expect_failure (Journal.Input_source_changed canonical) (adopt run_dir observed));
  with_input ~pending:false (fun ~base_path:_ ~run_dir ~path:_ ~session_dir:_ ~canonical:_
      ~metadata ~snapshot:_ ~bundle:_ observed ->
    write metadata (contents metadata ^ " ");
    expect_failure (Journal.Input_source_changed metadata) (adopt run_dir observed))
let test_input_prepublication_change_preserves_partial_evidence () =
  with_input ~pending:true (fun ~base_path ~run_dir ~path ~session_dir ~canonical
      ~metadata:_ ~snapshot ~bundle:_ observed ->
    let original = contents path in
    let changed = contents canonical ^ " " in
    let result = Journal.For_testing.adopt_input ~run_dir
      ~expected_checkpoint_sha256:(Journal.input_checkpoint_sha256 observed) observed
      ~before_publication:(fun () -> write canonical changed) ~sync_manifest_parent:sync_directory in
    expect_failure (Journal.Input_source_changed canonical) result;
    let id = match result with Error {Journal.bundle_id=Some id;_} -> id
      | Error {bundle_id=None;_} | Ok _ -> fail "partial adoption identity was lost" in
    check bool "partial derivative retained" true
      (Sys.file_exists (Filename.concat (input_directory base_path id) "adopted.sqlite3"));
    check bool "changed source prevents manifest" false
      (Sys.file_exists (Filename.concat (input_directory base_path id) "manifest.json"));
    check bool "retained checkpoint is not removed" true (Sys.file_exists (input_retained_path session_dir snapshot));
    check string "concurrent canonical edit preserved" changed (contents canonical);
    check string "original journal preserved" original (contents path))
let test_input_manifest_uncertainty_and_missing_retained_payload () =
  with_input ~pending:true (fun ~base_path ~run_dir ~path:_ ~session_dir ~canonical
      ~metadata:_ ~snapshot ~bundle:_ observed ->
    let result = Journal.For_testing.adopt_input ~run_dir
      ~expected_checkpoint_sha256:(Journal.input_checkpoint_sha256 observed) observed
      ~before_publication:(fun () -> ())
      ~sync_manifest_parent:(fun _ -> raise (Sys_error "adoption manifest parent sync failed")) |> ok in
    let receipt = match result with Journal.Input_adoption_unconfirmed receipt -> receipt
      | Input_adopted _ -> fail "uncertain adoption was reported durable" in
    let id = Journal.input_adoption_id receipt in
    ignore (Journal.load_input_adoption ~base_path ~adoption_id:id |> ok);
    let retained = input_retained_path session_dir snapshot in
    Unix.unlink retained;
    (match Journal.load_input_adoption ~base_path ~adoption_id:id with
     | Error _ -> () | Ok _ -> fail "missing retained input borrowed canonical authority");
    check bool "restart did not recreate missing evidence" false (Sys.file_exists retained);
    check bool "canonical was present during refusal" true (Sys.file_exists canonical))
let test_input_corrupt_retention_is_not_repaired () =
  with_input ~pending:true (fun ~base_path:_ ~run_dir ~path:_ ~session_dir ~canonical:_
      ~metadata:_ ~snapshot ~bundle:_ observed ->
    let retained = input_retained_path session_dir snapshot in
    Fs_compat.mkdir_p (Filename.dirname retained); write retained "corrupt retained evidence";
    Unix.chmod retained 0o600;
    (match adopt run_dir observed with
     | Error cause -> (match cause.Journal.failure with
       | Input_retention_unconfirmed outcome -> (match outcome with
         | Checkpoint.Not_installed _ -> ()
         | Installed _ -> fail "corrupt input was installed")
       | Invalid_keeper _ | Workspace_in_use | Unsafe_path _ | Source_absent | Source_changed
         | Companion_present _ | Store_failed _ | Io_failed _ | Invalid_bundle | Bundle_workspace_mismatch _
         | Input_selection_invalid _ | Input_source_changed _ | Input_history_unresolved _ -> fail "retention failure evidence was lost")
     | Ok _ -> fail "corrupt retained evidence was adopted");
    check string "corrupt evidence was not overwritten" "corrupt retained evidence" (contents retained))
let test_input_rehash_cannot_hide_changed_derivative () =
  with_input ~pending:false (fun ~base_path ~run_dir ~path:_ ~session_dir:_ ~canonical:_
      ~metadata:_ ~snapshot:_ ~bundle:_ observed ->
    let receipt = adopt run_dir observed |> ok |> adopted in
    let id = Journal.input_adoption_id receipt in
    let directory = input_directory base_path id in
    let derivative = Filename.concat directory "adopted.sqlite3" in
    let next = with_db derivative (fun db -> sql db "UPDATE metadata SET next_sequence=next_sequence+1";
      scalar db "SELECT next_sequence FROM metadata") in
    let manifest = Filename.concat directory "manifest.json" in
    let fields = match Yojson.Safe.from_string (contents manifest) with
      | `Assoc fields -> fields | _ -> fail "manifest is not an object" in
    write manifest (Yojson.Safe.to_string (`Assoc (("derivative_sha256",`String (digest (contents derivative)))::
      ("next_sequence",`String next)::List.remove_assoc "next_sequence" (List.remove_assoc "derivative_sha256" fields))));
    (match Journal.load_input_adoption ~base_path ~adoption_id:id with
     | Error _ -> () | Ok _ -> fail "rewritten hash hid original journal cell changes"))
let native_input_fixture ~terminal ~conflicting_seed ~base_path ~store ~snapshot =
  let latest = Checkpoint.exact_snapshot_checkpoint snapshot in
  let seed_value = {latest with pending_input=(input_checkpoint (Option.is_none latest.pending_input)).pending_input} in
  let seed_value = if conflicting_seed then {seed_value with messages=[Core.Types.
    {role=User;content=[Text "conflicting admission history"];name=None;tool_call_id=None;metadata=[]}]} else seed_value in
  let trace = (Checkpoint.exact_snapshot_reference snapshot).trace_id in
  let seed = match Checkpoint.exact_snapshot_of_value ~expected_session_id:trace seed_value with
    | Ok seed -> seed | Error cause -> fail (Checkpoint.checkpoint_ref_load_error_to_string cause) in
  let session_dir = Filename.concat (Keeper_fs.session_store_path_for_runtime_root
    (Filename.concat base_path Common.masc_dirname)) latest.session_id in
  List.iter (fun checkpoint -> match Checkpoint.retain_exact_snapshot ~session_dir checkpoint with
    | Checkpoint.Installed {auxiliary=[];_} -> ()
    | Installed {auxiliary=_::_;_} | Not_installed _ -> fail "native fixture retention failed") [seed;snapshot];
  let operation = match Store.claim_next store ~now:2. |> store_ok with
    | Some operation -> operation | None -> fail "native fixture did not claim operation" in
  let call_id = "019a0010-1000-7000-8000-0000000000d1" in
  let locator = Core.Agent.execution_locator_of_yojson
    (`Assoc ["version",`Int 1;"run_id",`String "journal-input-native-run"]) |> fixture_ok in
  let seed_reference = Checkpoint.exact_snapshot_reference seed in
  let call = Keeper_native_call.create ~call_id ~runtime_id:"native.primary"
    ~operation_digest:operation.execution_digest ~api:Continue_from_checkpoint
    ~seed_checkpoint:seed_reference ~locator |> fixture_ok in
  let commit change = Store.update_direct_native_call store ~now:3. ~operation_id:operation.operation_id
    ~execution_digest:operation.execution_digest change |> store_ok in
  commit (Keeper_native_call.Bind {observed=No_native_call;call});
  commit (Keeper_native_call.Checkpoint {call_id;observed=seed_reference;
    checkpoint=Checkpoint.exact_snapshot_reference snapshot});
  Option.iter (fun recovery -> commit (Keeper_native_call.Terminal {call_id;
    disposition=Core.Agent.{outcome=Terminal_succeeded;recovery}})) terminal
let test_native_seed_is_history_not_current_input_authority () =
  List.iter (fun pending -> with_input_result ~pending
    ~before_close:(native_input_fixture ~terminal:(Some Core.Agent.Retire) ~conflicting_seed:false)
    (fun ~base_path ~run_dir ~path:_ ~session_dir:_ ~canonical:_ ~metadata:_ ~snapshot ~bundle:_ result ->
      let observed = ok result in
      let receipt = adopt run_dir observed |> ok |> adopted in
      check bool "latest pending may differ from immutable seed" pending
        (Option.is_some (Checkpoint.exact_snapshot_checkpoint snapshot).pending_input);
      ignore (Journal.load_input_adoption ~base_path ~adoption_id:(Journal.input_adoption_id receipt) |> ok)))
    [false;true];
  List.iter (fun (terminal,conflicting_seed) ->
    with_input_result ~pending:true ~before_close:(native_input_fixture ~terminal ~conflicting_seed)
      (fun ~base_path:_ ~run_dir:_ ~path:_ ~session_dir:_ ~canonical:_ ~metadata:_ ~snapshot:_ ~bundle:_ result ->
        match result with
        | Error cause -> (match cause.Journal.failure with
          | Input_history_unresolved _ -> ()
          | Invalid_keeper _ | Workspace_in_use | Unsafe_path _ | Source_absent | Source_changed
          | Companion_present _ | Store_failed _ | Io_failed _ | Invalid_bundle | Bundle_workspace_mismatch _
          | Input_selection_invalid _ | Input_source_changed _ | Input_retention_unconfirmed _ ->
            fail "native history refusal lost its reason")
        | Ok _ -> fail "unsafe native history was accepted"))
    [None,false;Some (Core.Agent.Operator_repair_required Core.Agent.Effect_outcome_unknown),false;
     Some Core.Agent.Retire,true]
let test_retention_post_commit_cancel_propagates_with_evidence () =
  with_input ~pending:true (fun ~base_path:_ ~run_dir:_ ~path:_ ~session_dir ~canonical:_
      ~metadata:_ ~snapshot ~bundle:_ _ ->
    let cancellation = Eio.Cancel.Cancelled (Failure "after retained durable commit") in
    let writer ~on_durable_commit ~ownership_root ~path ~bytes =
      match Keeper_fs.save_bytes_durable_atomic_observed ~on_durable_commit ~ownership_root path bytes with
      | Ok Keeper_fs.Committed -> raise cancellation
      | (Ok (Committed_but_observer_failed _) | Error _) as result -> result in
    let outcome = Checkpoint.For_testing.retain_exact_snapshot_with_writer
      ~write_checkpoint_bytes:writer ~session_dir snapshot in
    let original_backtrace = match outcome with
      | Checkpoint.Installed installed ->
        (match List.find_map (function
          | Checkpoint.Post_commit_unwind_interrupted (cause,bt) ->
            if cause==cancellation then Some bt else None
          | Commit_durability_unknown _ | Commit_observer_failed _ | Release_process_lock_failed _ -> None)
            installed.auxiliary with
         | Some bt -> bt | None -> fail "fixture did not retain cancellation")
      | Not_installed _ -> fail "fixture did not commit retained artifact" in
    (match Journal.For_testing.confirm_input_retention outcome with
     | Ok _ | Error _ -> fail "post-commit cancellation became normal adoption result"
     | exception (Eio.Cancel.Cancelled _ as cause) ->
       check bool "same cancellation propagates" true (cause==cancellation));
    check string "committed artifact remains" (Checkpoint.exact_snapshot_canonical_bytes snapshot)
      (contents (input_retained_path session_dir snapshot));
    let failure = Checkpoint.Installed {installed_ref=Checkpoint.exact_snapshot_reference snapshot;
      auxiliary=[Checkpoint.Commit_observer_failed (Failure "observer failed",original_backtrace)]} in
    (match Journal.For_testing.confirm_input_retention failure with
     | Error cause -> (match cause.Journal.failure with
       | Input_retention_unconfirmed preserved ->
         check bool "full installation evidence retained" true (preserved==failure)
       | Invalid_keeper _ | Workspace_in_use | Unsafe_path _ | Source_absent | Source_changed
         | Companion_present _ | Store_failed _ | Io_failed _ | Invalid_bundle | Bundle_workspace_mismatch _
         | Input_selection_invalid _ | Input_source_changed _ | Input_history_unresolved _ -> fail "installation evidence was discarded")
     | Ok _ -> fail "failed retention was accepted"))

let () = run "Keeper journal offline bundles"
  ["operator preparation",[
    test_case "publish private evidence and recover read-only" `Quick test_bundle_publication_and_readonly_recovery;
    test_case "stale plan and active Owner refuse preparation" `Quick test_stale_plan_and_active_owner;
    test_case "workspace aliases resolve and relocation preserves evidence" `Quick test_workspace_location_is_preserved;
    test_case "SQLite companions remain evidence" `Quick test_companions_are_evidence;
    test_case "source edit after copy prevents publication" `Quick test_changed_source_after_copy_retains_unpublished_backup;
    test_case "manifest sync uncertainty preserves published evidence" `Quick test_manifest_sync_uncertainty_is_not_no_publication;
    test_case "recomputed hashes cannot hide changed journal cells" `Quick test_hash_rewrite_cannot_hide_changed_prepared_cells;
    test_case "cancellation releases lease and preserves partial evidence" `Quick test_cancellation_releases_lease_and_preserves_partial_evidence];
   "operator input adoption",[
    test_case "explicit selection preserves complete original payloads" `Quick test_input_adoption_preserves_originals_and_full_payload;
    test_case "reviewed SHA, current source and active Owner are required" `Quick test_input_selection_revalidation_and_active_owner;
    test_case "late source edit preserves unpublished evidence" `Quick test_input_prepublication_change_preserves_partial_evidence;
    test_case "manifest uncertainty and missing retained payload remain distinct" `Quick test_input_manifest_uncertainty_and_missing_retained_payload;
    test_case "corrupt retained input is never repaired" `Quick test_input_corrupt_retention_is_not_repaired;
    test_case "rehashed derivative cannot hide changed source cells" `Quick test_input_rehash_cannot_hide_changed_derivative;
    test_case "native seed history differs from current input authority" `Quick test_native_seed_is_history_not_current_input_authority;
    test_case "post-commit cancellation preserves exception and durable artifact" `Quick test_retention_post_commit_cancel_propagates_with_evidence]]
