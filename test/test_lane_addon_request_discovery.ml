open Masc
module Owner = Lane_addon_tool_request_owner
module Store = Lane_addon_store
module Progress = Lane_addon_request_progress
let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let owned value = get (Result.map_error Owner.error_to_string value)
let some = function Some value -> value | None -> Alcotest.fail "missing original request"
let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let scope = "workspace-curator"
let request = `Assoc ["input",`String "complete original evidence"]
let with_parent f =
  let parent = Filename.temp_dir "addon-discovery" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Unix.chmod path 0o700;
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Sys.remove path in
  Fun.protect ~finally:(fun () -> remove parent) (fun () -> f parent)
let with_store f = with_parent (fun parent ->
  let root = Filename.concat parent "store" in f root (Store.create ~root))
let retain ?(scope=scope) store id = owned (Owner.retain ~store ~scope ~request_id:id
  ~installation_id:"original-installation" ~package_id:"curator" ~tool:"classify" ~summary:`Null ~request)
let load store id = Owner.load ~store ~scope ~request_id:id
let directory root = Filename.concat root (Filename.concat "tool-request-owners" (Store.digest scope))
let path root id = Filename.concat (directory root) (Store.digest id ^ ".json")
let save path bytes = get (Fs_compat.save_file_atomic_strict path bytes)
let fail_inventory value = match value with Error _ -> () | Ok _ -> Alcotest.fail "failed inventory became complete"
let fail_load value = match value with Error _ -> () | Ok _ -> Alcotest.fail "unsafe original became valid or absent"
let inventory ?(after_listing=fun _ -> ()) ?(sync_file=Unix.fsync) ?(sync_parent=Unix.fsync) store =
  Store.For_testing.tool_request_owner_inventory ~after_listing ~sync_file ~sync_parent store ~scope
let test_restart_discovers_original_input_progress_and_scope () = with_store (fun root store ->
  retain store "a";retain store "b";retain ~scope:"other-owner" store "outside";
  let original = some (owned (load store "a")) in
  let pending = match get (Result.map_error Owner.update_error_to_string
      (Owner.advance ~store ~expected:original ~event:Progress.Dispatch_intended)) with
    | Owner.Stored value -> value
    | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "dispatch intent not stored" in
  let records = owned (Owner.discover ~store:(Store.create ~root) ~scope) in
  let expected = ["a";"b"] |> List.sort (fun a b -> String.compare (Store.digest a) (Store.digest b)) in
  Alcotest.(check (list string)) "only original scope in stable filename order" expected
    (List.map Owner.Record.request_id records);
  let restored = List.find (fun record -> Owner.Record.request_id record="a") records in
  Alcotest.check json "original progress survives restart discovery"
    (Progress.to_json pending.progress) (Progress.to_json (Owner.Record.progress restored));
  Alcotest.check json "complete original input survives a load of what discovery found" request
    (some (owned (load store (Owner.Record.request_id restored)))).request;
  Alcotest.(check string) "destination is the original installation" "original-installation"
    (Owner.Record.installation_id restored))

let test_reload_keeps_the_verified_body_and_refuses_another_digest () = with_store (fun root store ->
  retain store "a";
  owned (Owner.retain ~store ~scope ~request_id:"b" ~installation_id:"original-installation"
    ~package_id:"curator" ~tool:"classify" ~summary:`Null ~request:(`Assoc ["input",`String "another body"]));
  let original = some (owned (load store "a")) in
  let pending = match get (Result.map_error Owner.update_error_to_string
      (Owner.advance ~store ~expected:original ~event:Progress.Dispatch_intended)) with
    | Owner.Stored value -> value
    | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "dispatch intent not stored" in
  let reloaded = some (owned (Owner.reload ~store original)) in
  Alcotest.check json "reload reads the record's current progress"
    (Progress.to_json pending.progress) (Progress.to_json reloaded.progress);
  Alcotest.check json "reload carries the body the first load verified" request reloaded.request;
  let other = some (owned (load store "b")) in
  Alcotest.(check bool) "the other original names another body" false
    (String.equal other.request_digest original.request_digest);
  let record = Yojson.Safe.from_file (path root "a") in
  let renamed = match record with
    | `Assoc fields -> `Assoc (List.map (fun (key,value) ->
        if key="request_digest" then key,`String other.request_digest else key,value) fields)
    | _ -> Alcotest.fail "original record is not an object" in
  save (path root "a") (Yojson.Safe.to_string renamed);
  (match Owner.reload ~store original with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a record naming another body kept the earlier body");
  Sys.remove (path root "a");
  match owned (Owner.reload ~store original) with
  | None -> ()
  | Some _ -> Alcotest.fail "a removed original reloaded")
let test_initial_absence_requires_existing_safe_anchor_without_creation () = with_store (fun root store ->
  Alcotest.(check int) "absent descendant is an empty observation" 0 (List.length (owned (Owner.discover ~store ~scope)));
  Alcotest.(check bool) "known absent key" true (owned (load store "missing")=None);
  Alcotest.(check bool) "read created no store" false (Sys.file_exists root);
  let missing_parent = Filename.concat (Filename.dirname root) "missing-parent" in
  let missing_store = Store.create ~root:(Filename.concat missing_parent "store") in
  fail_inventory (Owner.discover ~store:missing_store ~scope);
  fail_load (load missing_store "missing");
  Alcotest.(check bool) "missing authority is not recreated" false (Sys.file_exists missing_parent);
  let parent = Filename.dirname root in
  Unix.chmod parent 0o777;
  fail_inventory (Owner.discover ~store ~scope);fail_load (load store "missing");
  Unix.chmod parent 0o700;
  fail_inventory (inventory store ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync","injected"))));
  Alcotest.(check bool) "failed absence settlement created nothing" false (Sys.file_exists root);
  save root "not a directory";
  fail_inventory (Owner.discover ~store ~scope);fail_load (load store "missing"))

let test_bad_record_or_unknown_name_never_returns_a_partial_inventory () = with_store (fun root store ->
  retain store "valid";retain store "damaged";
  let record = Fs_compat.load_file (path root "damaged") in
  save (path root "damaged") "{invalid JSON";
  fail_inventory (Owner.discover ~store ~scope);
  fail_load (load store "damaged");
  save (path root "damaged") record;
  let wrong = Filename.concat (directory root) "wrong-key.json" in
  Unix.rename (path root "damaged") wrong;
  fail_inventory (Owner.discover ~store ~scope);
  Unix.rename wrong (path root "damaged");
  let unknown = Filename.concat (directory root) "unrecognized-file" in
  save unknown record;fail_inventory (Owner.discover ~store ~scope);Sys.remove unknown;
  let stage = Filename.concat (directory root) ".atomic_incomplete.tmp" in
  save stage "incomplete unpublished bytes";
  Alcotest.(check int) "canonical unpublished stage is not a request" 2
    (List.length (owned (Owner.discover ~store ~scope)));
  let parsed = Yojson.Safe.from_string record in
  let bad_scope = match parsed with `Assoc fields ->
    `Assoc (List.map (fun (key,value) -> key,if key="scope" then `String "other-owner" else value) fields)
    | _ -> Alcotest.fail "original owner object" in
  save (path root "damaged") (Yojson.Safe.to_string bad_scope);
  fail_inventory (Owner.discover ~store ~scope);
  (* The same summary with its keys out of canonical order is refused, not
     normalized on read. *)
  let unordered = match parsed with `Assoc fields ->
    `Assoc (List.map (fun (key,value) -> key,if key="summary" then `Assoc ["z",`Int 1;"a",`Int 2] else value) fields)
    | _ -> Alcotest.fail "original owner object" in
  save (path root "damaged") (Yojson.Safe.to_string unordered);
  fail_inventory (Owner.discover ~store ~scope);
  fail_load (load store "damaged"))

let test_listed_disappearance_and_same_name_directory_replacement_are_errors () =
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~after_listing:(fun _ -> Sys.remove (path root "original"))));
  with_store (fun root store -> retain store "original";
    let bytes = Fs_compat.load_file (path root "original") in
    fail_inventory (inventory store ~after_listing:(fun directory ->
      Unix.rename directory (directory ^ "-original");Unix.mkdir directory 0o700;
      save (path root "original") bytes)));
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~after_listing:(fun _ ->
      Unix.rename root (root ^ "-original");
      (* The held old scope still contains readable bytes, but its store parent
         has vanished. It cannot become a complete discovery of the new path. *)
      Unix.mkdir root 0o700)))

let test_symlink_hardlink_and_nonregular_records_are_refused () =
  with_store (fun root store -> retain store "original";
    let original = path root "original" and outside = Filename.concat (Filename.dirname root) "outside.json" in
    Unix.rename original outside;Unix.symlink outside original;
    fail_inventory (Owner.discover ~store ~scope);fail_load (load store "original"));
  with_store (fun root store -> retain store "original";
    Unix.link (path root "original") (Filename.concat (Filename.dirname root) "outside-hardlink.json");
    fail_inventory (Owner.discover ~store ~scope);fail_load (load store "original"));
  with_store (fun root store -> retain store "original";
    Sys.remove (path root "original");Unix.mkfifo (path root "original") 0o600;
    fail_inventory (Owner.discover ~store ~scope);fail_load (load store "original"));
  with_store (fun root store -> retain store "original";
    let moved = directory root ^ "-original" in
    Unix.rename (directory root) moved;Unix.symlink moved (directory root);
    fail_inventory (Owner.discover ~store ~scope);fail_load (load store "original"))

let body_path root = Filename.concat root
    (Store.tool_request_body_path ~scope ~request_digest:(get (Owner.request_digest request)))
(* A load reads the body through the same owned descriptors as the record,
   so the same file shapes are refused there. Discovery reads records only. *)
let test_symlink_hardlink_nonregular_and_writable_bodies_are_refused () =
  let refused _ store = fail_load (load store "original") in
  with_store (fun root store -> retain store "original";
    let body = body_path root and outside = Filename.concat (Filename.dirname root) "outside-body.json" in
    Unix.rename body outside;Unix.symlink outside body;
    refused root store);
  with_store (fun root store -> retain store "original";
    Unix.link (body_path root) (Filename.concat (Filename.dirname root) "outside-body-hardlink.json");
    refused root store);
  with_store (fun root store -> retain store "original";
    Sys.remove (body_path root);Unix.mkfifo (body_path root) 0o600;
    refused root store);
  with_store (fun root store -> retain store "original";
    let bodies = Filename.dirname (body_path root) in
    let moved = bodies ^ "-original" in
    Unix.rename bodies moved;Unix.symlink moved bodies;
    refused root store);
  with_store (fun root store -> retain store "original";
    Unix.chmod (body_path root) 0o666;
    refused root store)

let test_sync_failure_and_actual_replacement_preserve_original_read_boundary () =
  with_store (fun _ store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync","injected"))));
    fail_inventory (inventory store ~sync_parent:(fun _ -> raise (Unix.Unix_error (Unix.EIO,"fsync","injected")))));
  with_store (fun root store -> retain store "original";
    let bytes = Fs_compat.load_file (path root "original") in
    fail_inventory (inventory store ~sync_file:(fun fd -> Unix.fsync fd;save (path root "original") bytes)));
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun fd ->
      Unix.fsync fd;
      let directory = directory root in
      let moved = directory ^ "-original" in
      Unix.rename directory moved;Unix.symlink moved directory)))

let test_large_original_reverification_checks_every_chunk_and_eof () =
  with_store (fun root store ->
    let payload=String.init (5 * Sys.io_buffer_size + 17)
      (fun index -> Char.chr (Char.code 'A' + index / Sys.io_buffer_size)) in
    owned (Owner.retain ~store ~scope ~request_id:"large-original"
      ~installation_id:"original-installation" ~package_id:"curator" ~tool:"classify"
      ~summary:(`String payload) ~request);
    let original_path=path root "large-original" in
    let bytes=Fs_compat.load_file original_path in
    let expected=get (inventory store) in
    let payload_offset=String.index bytes 'A' in
    List.iter (fun offset ->
      save original_path bytes;
      fail_inventory (inventory store ~sync_file:(fun fd ->
        Unix.fsync fd;
        let writing=Unix.openfile original_path [Unix.O_WRONLY;Unix.O_CLOEXEC] 0 in
        Fun.protect ~finally:(fun () -> Unix.close writing) (fun () ->
          ignore (Unix.lseek writing offset Unix.SEEK_SET);
          Alcotest.(check int) "changed one still-valid JSON string byte" 1
            (Unix.write_substring writing "Z" 0 1)))))
      [payload_offset; payload_offset + Sys.io_buffer_size; payload_offset + String.length payload - 1];
    save original_path bytes;
    fail_inventory (inventory store ~sync_file:(fun fd ->
      Unix.fsync fd; Unix.truncate original_path (String.length bytes - 1)));
    save original_path bytes;
    fail_inventory (inventory store ~sync_file:(fun fd ->
      Unix.fsync fd;
      Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 original_path
        (fun channel -> output_char channel ' ')));
    save original_path bytes;
    Alcotest.check (Alcotest.list (Alcotest.pair Alcotest.string json))
      "large complete original survives a fresh verified read" expected (get (inventory store)))

let test_fresh_ancestor_and_file_permissions_are_checked_after_io () =
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun fd -> Unix.fsync fd;Unix.chmod root 0o777)));
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun fd -> Unix.fsync fd;Unix.chmod (path root "original") 0o666)));
  with_store (fun root store -> retain store "original";
    let relative = get (Fs_compat.owned_relative_path
      [Filename.basename root; "tool-request-owners"; Store.digest scope; Store.digest "original" ^ ".json"]) in
    let result = Fs_compat.with_owned_inventory_root (Filename.dirname root) (fun held ->
      Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid () + 1) held
        relative (fun ~file:_ ~parent:_ ~stat:_ -> ())) in
    fail_inventory result)

let test_original_publication_waits_for_actual_read_across_store_aliases () =
  with_store (fun root store ->
    retain store "original";
    let original=some (owned (load store "original")) in
    let original_json=some (get (Store.load_tool_request_owner store ~scope ~request_id:"original")) in
    let alias=Filename.concat (Filename.dirname root) "parent-alias" in
    Unix.symlink (Filename.dirname root) alias;
    let writer=Store.create ~root:(Filename.concat alias (Filename.basename root)) in
    Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      let gate=Stdlib.Mutex.create () and changed=Condition.create () and released=ref false in
      let release ()=Stdlib.Mutex.protect gate (fun () -> released:=true;Condition.broadcast changed) in
      let entered,entered_resolver=Eio.Promise.create () in
      let reading,reading_resolver=Eio.Promise.create () in
      let writing,writing_resolver=Eio.Promise.create () in
      (* The real descriptor stays open across sync and final verification.
         The timeout is a hang guard; the lock's actual waiter state orders the
         actors, rather than a sleep or an expected elapsed-time threshold. *)
      Fun.protect ~finally:release (fun () ->
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
          Eio.Fiber.fork ~sw (fun () ->
            let result=Eio_unix.run_in_systhread (fun () ->
              inventory store ~sync_file:(fun fd ->
                Unix.fsync fd;
                Eio.Promise.resolve entered_resolver ();
                Stdlib.Mutex.protect gate (fun () ->
                  while not !released do Condition.wait changed gate done))) in
            Eio.Promise.resolve reading_resolver result);
          Eio.Promise.await entered;
          Eio.Fiber.fork ~sw (fun () ->
            let result=Eio_unix.run_in_systhread (fun () ->
              Owner.advance ~store:writer ~expected:original ~event:Progress.Dispatch_intended) in
            Eio.Promise.resolve writing_resolver result);
          let key=directory (Unix.realpath root) in
          let rec await_writer ()=
            if File_lock_eio.For_testing.holders_and_waiters ~lock_path:key=2 then ()
            else (Eio.Fiber.yield ();await_writer ()) in
          await_writer ();
          Eio_unix.run_in_systhread (fun () -> retain ~scope:"unrelated-scope" writer "independent");
          release ();
          let read=get (Eio.Promise.await reading) in
          Alcotest.check json "held original inventory confirms the pre-publication bytes" original_json
            (match read with [(_,record)] -> record | [] | _::_::_ -> Alcotest.fail "one original required");
          (match Eio.Promise.await writing |> Result.map_error Owner.update_error_to_string |> get with
           | Owner.Stored _ -> ()
           | Already_stored _ | Unconfirmed _ -> Alcotest.fail "original progress must be durably published");
          let fresh=some (owned (load store "original")) in
          Alcotest.(check bool) "fresh known-ID read sees the exact new original progress" true
            (Progress.phase fresh.progress=Progress.Dispatch_pending None))))))

let test_owned_relative_path_refuses_non_names () =
  List.iter (fun components ->
    Alcotest.(check bool) (String.concat "|" components ^ " is refused") true
      (Result.is_error (Fs_compat.owned_relative_path components)))
    [[]; [""]; ["."]; [".."]; ["a/b"]; ["a"; ".."]];
  Alcotest.(check string) "names join below the root" "a/b"
    (Fs_compat.owned_relative_path_to_string (get (Fs_compat.owned_relative_path ["a"; "b"])))

(* #45130: the held root is canonical. A root reached through a symbolic link
   (macOS /var is /private/var) must still read its entries. *)
let test_held_root_through_a_symlink_reads_entries_by_relative_path () =
  with_store (fun root store -> retain store "original";
    let parent = Filename.dirname root in
    let alias = Filename.concat parent "alias" in
    Unix.symlink parent alias;
    let relative = get (Fs_compat.owned_relative_path
      [Filename.basename root; "tool-request-owners"; Store.digest scope; Store.digest "original" ^ ".json"]) in
    let read = Fs_compat.with_owned_inventory_root alias (fun held ->
      Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid ()) held relative
        (fun ~file:_ ~parent:_ ~stat -> stat.Unix.st_size)) in
    match read with
    | Ok bytes -> Alcotest.(check int) "the entry is read below the canonical root"
        (String.length (Fs_compat.load_file (path root "original"))) bytes
    | Error error -> Alcotest.fail (Fs_compat.owned_regular_file_read_error_to_string error))

(* Each original with its own body, so settling one moves no body another
   record names. *)
let request_of id = `Assoc ["input",`String ("original evidence of " ^ id)]
let retain_own store id = owned (Owner.retain ~store ~scope ~request_id:id
  ~installation_id:"original-installation" ~package_id:"curator" ~tool:"classify" ~summary:`Null
  ~request:(request_of id))
let own_body root id = Filename.concat root
    (Store.tool_request_body_path ~scope ~request_digest:(get (Owner.request_digest (request_of id))))
let day = "2026-10-23"
let settled_path root id = Filename.concat root (Store.tool_request_archive_record_path ~scope ~date:day ~request_id:id)
let settled_body root id = Filename.concat root
    (Store.tool_request_archive_body_path ~scope ~date:day ~request_digest:(get (Owner.request_digest (request_of id))))
let listed store id = match List.find_opt (fun record -> Owner.Record.request_id record=id)
    (owned (Owner.discover ~store ~scope)) with
  | Some record -> record | None -> Alcotest.fail "the original is not in its scope"
let settle ?(date=day) store record = Owner.settle ~store ~date record
let settled_ok value = match value with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Owner.settle_error_to_string error)
let is_settled ?(date=day) store id = owned (Owner.settled ~store ~scope ~date ~request_id:id)

let test_a_settled_original_leaves_the_scope_with_its_body () = with_store (fun root store ->
  retain_own store "settled";retain_own store "kept";
  let record = listed store "settled" in
  let record_bytes = Fs_compat.load_file (path root "settled")
  and body_bytes = Fs_compat.load_file (own_body root "settled") in
  settled_ok (settle store record);
  Alcotest.(check (list string)) "discovery no longer lists it" ["kept"]
    (List.map Owner.Record.request_id (owned (Owner.discover ~store ~scope)));
  Alcotest.(check bool) "a load finds no original" true (owned (load store "settled")=None);
  Alcotest.(check bool) "its record is under the date" true (is_settled store "settled");
  Alcotest.(check bool) "and under no other date" false (is_settled ~date:"2026-10-24" store "settled");
  Alcotest.(check string) "the record moved unchanged" record_bytes (Fs_compat.load_file (settled_path root "settled"));
  Alcotest.(check string) "the body moved unchanged" body_bytes (Fs_compat.load_file (settled_body root "settled"));
  Alcotest.(check bool) "no body is left beside the scope" false (Sys.file_exists (own_body root "settled"));
  Alcotest.check json "the other original keeps its body" (request_of "kept") (some (owned (load store "kept"))).request;
  settled_ok (settle store record);
  Alcotest.(check string) "settling again finds it moved and changes nothing" record_bytes
    (Fs_compat.load_file (settled_path root "settled")))

let test_a_changed_record_is_not_settled () = with_store (fun root store ->
  retain_own store "original";
  let read = listed store "original" in
  (match get (Result.map_error Owner.update_error_to_string
      (Owner.advance ~store ~expected:(some (owned (load store "original"))) ~event:Progress.Dispatch_intended)) with
   | Owner.Stored _ -> ()
   | Owner.Already_stored _ | Owner.Unconfirmed _ -> Alcotest.fail "dispatch intent not stored");
  (match settle store read with
   | Error Owner.Settle_changed -> ()
   | Error (Owner.Settle_unavailable detail) -> Alcotest.fail detail
   | Ok () -> Alcotest.fail "a record that changed after it was read was settled");
  Alcotest.(check bool) "the record stays in its scope" true (Sys.file_exists (path root "original"));
  Alcotest.(check bool) "its body stays" true (Sys.file_exists (own_body root "original"));
  Alcotest.(check bool) "nothing is under the date" false (is_settled store "original"))

let test_settling_again_finishes_a_move_that_stopped_after_the_record () = with_store (fun root store ->
  retain_own store "original";
  let record = listed store "original" in
  settled_ok (settle store record);
  (* What a settle interrupted between its two moves leaves: the record under
     the date, the body still beside the scope. *)
  Unix.rename (settled_body root "original") (own_body root "original");
  Alcotest.(check int) "the scope no longer lists it" 0 (List.length (owned (Owner.discover ~store ~scope)));
  settled_ok (settle store record);
  Alcotest.(check bool) "the body is under the date" true (Sys.file_exists (settled_body root "original"));
  Alcotest.(check bool) "and no longer beside the scope" false (Sys.file_exists (own_body root "original")))

(* The record moves first, so a settle that cannot move it moves nothing:
   the original stays whole in its scope, never a record without its body. *)
let test_a_settle_that_cannot_move_the_record_moves_nothing () = with_store (fun root store ->
  retain_own store "earlier";retain_own store "original";
  settled_ok (settle store (listed store "earlier"));
  let records = Filename.dirname (settled_path root "original") in
  Unix.chmod records 0o500;
  let result = settle store (listed store "original") in
  Unix.chmod records 0o700;
  (match result with
   | Error (Owner.Settle_unavailable _) -> ()
   | Error Owner.Settle_changed | Ok () -> Alcotest.fail "a settle that could not move its record succeeded");
  Alcotest.check json "the original still loads with its body" (request_of "original")
    (some (owned (load store "original"))).request;
  Alcotest.(check bool) "its body is not under the date" false (Sys.file_exists (settled_body root "original")))

let test_a_settle_refuses_a_date_that_is_not_a_day_and_a_missing_original () = with_store (fun root store ->
  retain_own store "original";
  let record = listed store "original" in
  List.iter (fun date ->
    (match settle ~date store record with
     | Error (Owner.Settle_unavailable _) -> ()
     | Error Owner.Settle_changed | Ok () -> Alcotest.fail ("a settle under " ^ date ^ " was not refused"));
    match Owner.settled ~store ~scope ~date ~request_id:"original" with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail ("a lookup under " ^ date ^ " was not refused"))
    ["2026-10-2";"../escaped";"2026/10/23";"2026-10-23/x"];
  Alcotest.(check bool) "nothing moved" true (Sys.file_exists (path root "original"));
  Sys.remove (path root "original");Sys.remove (own_body root "original");
  match settle store record with
  | Error (Owner.Settle_unavailable _) -> ()
  | Error Owner.Settle_changed | Ok () -> Alcotest.fail "an original in neither place was settled")

let test_all_scopes_survive_restart_without_metadata () = with_store (fun root store ->
  retain store "original-a";
  retain ~scope:"history-physical-owner" store "original-b";
  let records=owned (Owner.discover_all ~store:(Store.create ~root)) in
  let folded=owned (Owner.fold_all ~store:(Store.create ~root) ~init:[]
    ~f:(fun acc (record:Owner.retained) -> (record.scope,record.request_id)::acc)) in
  Alcotest.(check (list string)) "every actual scope is discovered without a Keeper/profile index"
    ["original-a";"original-b"]
    (List.map (fun (record:Owner.retained) -> record.request_id) records |> List.sort String.compare);
  Alcotest.(check (list (pair string string))) "fold_all visits the exact validated originals across all scopes"
    (List.sort Stdlib.compare [scope,"original-a";"history-physical-owner","original-b"])
    (List.sort Stdlib.compare folded);
  List.iter (fun (record:Owner.retained) ->
    Alcotest.check json "original evidence and destination survive the sweep" request record.request;
    Alcotest.(check bool) "the original scope remains its own binding" true
      (record.scope=(if record.request_id="original-a" then scope else "history-physical-owner"))) records)

let test_sweep_barrier_serializes_settlement_across_store_aliases () = with_store (fun root store ->
  retain_own store "original"; retain_own store "kept";
  let record = listed store "original" in
  let alias = Filename.concat (Filename.dirname root) "parent-alias" in
  Unix.symlink (Filename.dirname root) alias;
  let writer = Store.create ~root:(Filename.concat alias (Filename.basename root)) in
  let other = Store.create ~root:(Filename.concat (Filename.dirname root) "independent-store") in
  retain_own other "independent";
  let other_record = listed other "independent" in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let gate = Stdlib.Mutex.create () and changed = Condition.create () and released = ref false in
    let release () = Stdlib.Mutex.protect gate (fun () -> released:=true; Condition.broadcast changed) in
    let inventoried, inventoried_resolver = Eio.Promise.create () in
    let reading, reading_resolver = Eio.Promise.create () in
    let moving, moving_resolver = Eio.Promise.create () in
    Fun.protect ~finally:release (fun () ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
        Eio.Fiber.fork ~sw (fun () ->
          let result = Store.with_tool_request_settlement_barrier store (fun () ->
              Owner.For_testing.fold_all ~store ~init:[]
                ~after_inventory:(fun () ->
                  Eio.Promise.resolve inventoried_resolver ();
                  Stdlib.Mutex.protect gate (fun () ->
                    while not !released do Condition.wait changed gate done))
                ~f:(fun found (original:Owner.retained) ->
                  (* Wake's admission callback re-enters this scope. *)
                  let nested = owned (Owner.load_scope ~store ~scope) in
                  Alcotest.(check int) "nested scope read remains available" 2 (List.length nested);
                  original.request_id :: found)) in
          Eio.Promise.resolve reading_resolver result);
        Eio.Promise.await inventoried;
        let key = Filename.concat (Unix.realpath root) "tool-request-settlement-barrier" in
        let rec await_mover () =
          if File_lock_eio.For_testing.holders_and_waiters ~lock_path:key=2 then ()
          else (Eio.Fiber.yield (); await_mover ()) in
        let context,resolve_context=Eio.Promise.create () in
        let cancelled=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun context ->
          Eio.Promise.resolve resolve_context context;
          settle writer record)) in
        let context=Eio.Promise.await context in
        await_mover ();
        Eio.Cancel.cancel context Exit;
        (match Eio.Promise.await cancelled with
         | Error (Eio.Cancel.Cancelled _) -> ()
         | Error exn -> raise exn
         | Ok _ -> Alcotest.fail "cancelled waiter performed a settle");
        Alcotest.(check bool) "cancelled settle leaves the original active" true
          (Sys.file_exists (path root "original"));
        Eio.Fiber.fork ~sw (fun () ->
          let result = settle writer record in
          Eio.Promise.resolve moving_resolver result);
        await_mover ();
        Alcotest.(check bool) "inventoried original has not moved" true (Sys.file_exists (path root "original"));
        Eio_unix.run_in_systhread (fun () -> settled_ok (settle other other_record));
        release ();
        let found = Eio.Promise.await reading |> get |> owned |> List.sort String.compare in
        Alcotest.(check (list string)) "both originals reach the completed sweep" ["kept";"original"] found;
        settled_ok (Eio.Promise.await moving);
        Alcotest.(check bool) "the waiting settle completes after the sweep" true (is_settled store "original"))))))

let test_barrier_does_not_hide_an_external_disappearance () = with_store (fun root store ->
  retain_own store "lost";
  let result = Store.with_tool_request_settlement_barrier store (fun () ->
    Owner.For_testing.fold_all ~store ~init:[]
      ~after_inventory:(fun () -> Sys.remove (path root "lost"))
      ~f:(fun found original -> original::found)) |> get in
  fail_inventory result)

let test_admitted_barrier_survives_cancellation () = with_store (fun root store ->
  retain_own store "original";
  let record = listed store "original" in
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let gate=Stdlib.Mutex.create () and changed=Condition.create () and released=ref false in
    let release ()=Stdlib.Mutex.protect gate (fun () -> released:=true; Condition.broadcast changed) in
    let entered,resolve_entered=Eio.Promise.create () in
    let context,resolve_context=Eio.Promise.create () in
    let moved,resolve_moved=Eio.Promise.create () in
    let completed=Atomic.make false in
    Fun.protect ~finally:release (fun () ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10. (fun () ->
        let admitted=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun context ->
          Eio.Promise.resolve resolve_context context;
          Store.with_tool_request_settlement_barrier store (fun () ->
            Eio.Promise.resolve resolve_entered ();
            Stdlib.Mutex.protect gate (fun () ->
              while not !released do Condition.wait changed gate done);
            Atomic.set completed true))) in
        let context=Eio.Promise.await context in
        Eio.Promise.await entered;
        Eio.Cancel.cancel context Exit;
        Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve_moved (settle store record));
        let key=Filename.concat (Unix.realpath root) "tool-request-settlement-barrier" in
        let rec await_mover () =
          if File_lock_eio.For_testing.holders_and_waiters ~lock_path:key=2 then ()
          else (Eio.Fiber.yield (); await_mover ()) in
        await_mover ();
        Alcotest.(check bool) "cancelled admitted work remains protected" false (Atomic.get completed);
        Alcotest.(check bool) "settle still waits for admitted work" true (Sys.file_exists (path root "original"));
        release ();
        (match Eio.Promise.await admitted with
         | Error (Eio.Cancel.Cancelled _) -> ()
         | Error exn -> raise exn
         | Ok _ -> Alcotest.fail "pending cancellation did not propagate");
        Alcotest.(check bool) "admitted work finished before release" true (Atomic.get completed);
        settled_ok (Eio.Promise.await moved))))))

let test_barrier_released_after_exception () = with_store (fun _root store ->
  Eio_main.run (fun _env ->
    (try ignore (Store.with_tool_request_settlement_barrier store (fun () -> raise Exit));
         Alcotest.fail "exception did not escape"
     with Exit -> ());
    ignore (get (Store.with_tool_request_settlement_barrier store (fun () -> ())))))

let test_all_scope_refusals_never_become_partial_success () =
  with_store (fun root store ->
    Alcotest.(check int) "initial absence is read-only" 0 (List.length (owned (Owner.discover_all ~store)));
    Alcotest.(check bool) "the sweep creates no store" false (Sys.file_exists root);
    retain store "valid";
    retain ~scope:"another-scope" store "bad";
    let namespace=Filename.concat root Store.tool_request_owners_directory in
    let other=Filename.concat namespace (Store.digest "another-scope") in
    let original=Filename.concat other (Store.digest "bad" ^ ".json") in
    let wrong=Filename.concat other (Store.digest "another-id" ^ ".json") in
    Unix.rename original wrong;
    fail_inventory (Owner.discover_all ~store);
    fail_inventory (Owner.fold_all ~store ~init:[] ~f:(fun acc r -> r::acc));
    Unix.rename wrong original;
    let moved=Filename.concat (Filename.dirname root) "original-scope-moved" in
    Unix.rename other moved;
    Unix.symlink moved other;
    fail_inventory (Owner.discover_all ~store);
    fail_inventory (Owner.fold_all ~store ~init:[] ~f:(fun acc r -> r::acc)))

(* The work under test can block inside a system-thread mutex. An Eio timeout
   cannot join a truly deadlocked system thread, so run this one scenario in
   its own process group and kill it if the outer hang guard expires. *)
let run_guarded_scenario key =
  let program = "import os,signal,subprocess,sys\n" ^
    "env=os.environ.copy(); env[sys.argv[2]]='1'\n" ^
    "child=subprocess.Popen([sys.argv[1]],env=env,start_new_session=True)\n" ^
    "try: code=child.wait(timeout=180)\n" ^
    "except subprocess.TimeoutExpired:\n" ^
    " os.killpg(child.pid,signal.SIGKILL); child.wait(); sys.exit(124)\n" ^
    "sys.exit(code if code>=0 else 128-code)\n" in
  let exe = Unix.realpath Sys.executable_name in
  let pid=Unix.create_process "python3" [|"python3";"-c";program;exe;key|]
    Unix.stdin Unix.stdout Unix.stderr in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED 124 -> Alcotest.fail "scenario exceeded the process hang guard"
  | Unix.WEXITED code -> Alcotest.fail (Printf.sprintf "scenario exited %d" code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Alcotest.fail (Printf.sprintf "scenario ended with signal %d" signal)

let () =
  if Sys.getenv_opt "MASC_TEST_46252_SWEEP" = Some "1" then (
    test_sweep_barrier_serializes_settlement_across_store_aliases (); exit 0);
  if Sys.getenv_opt "MASC_TEST_46252_ADMITTED" = Some "1" then (
    test_admitted_barrier_survives_cancellation (); exit 0);
  if Sys.getenv_opt "MASC_TEST_46252_EXCEPTION" = Some "1" then (
    test_barrier_released_after_exception (); exit 0);
  Alcotest.run "Original Add-on request discovery" ["inventory",[
  Alcotest.test_case "all original scopes survive restart without a metadata index" `Quick
    test_all_scopes_survive_restart_without_metadata;
  Alcotest.test_case "sweep barrier waits for settle across store aliases" `Quick
    (fun () -> run_guarded_scenario "MASC_TEST_46252_SWEEP");
  Alcotest.test_case "barrier does not hide external disappearance" `Quick
    test_barrier_does_not_hide_an_external_disappearance;
  Alcotest.test_case "admitted barrier finishes before cancellation releases it" `Quick
    (fun () -> run_guarded_scenario "MASC_TEST_46252_ADMITTED");
  Alcotest.test_case "barrier is released after an exception" `Quick
    (fun () -> run_guarded_scenario "MASC_TEST_46252_EXCEPTION");
  Alcotest.test_case "all-scope key and symlink refusals never return partial success" `Quick
    test_all_scope_refusals_never_become_partial_success;
  Alcotest.test_case "owned relative paths are names only" `Quick test_owned_relative_path_refuses_non_names;
  Alcotest.test_case "a held root reached through a symlink reads by relative path" `Quick
    test_held_root_through_a_symlink_reads_entries_by_relative_path;
  Alcotest.test_case "restart discovers original input and progress" `Quick test_restart_discovers_original_input_progress_and_scope;
  Alcotest.test_case "reload keeps the verified body and refuses another digest" `Quick
    test_reload_keeps_the_verified_body_and_refuses_another_digest;
  Alcotest.test_case "absence requires owned settled authority and creates nothing" `Quick test_initial_absence_requires_existing_safe_anchor_without_creation;
  Alcotest.test_case "bad record and unknown entry refuse complete inventory" `Quick test_bad_record_or_unknown_name_never_returns_a_partial_inventory;
  Alcotest.test_case "listed disappearance and directory replacement" `Quick test_listed_disappearance_and_same_name_directory_replacement_are_errors;
  Alcotest.test_case "symlink hardlink and nonregular records" `Quick test_symlink_hardlink_and_nonregular_records_are_refused;
  Alcotest.test_case "symlink hardlink nonregular and writable bodies" `Quick
    test_symlink_hardlink_nonregular_and_writable_bodies_are_refused;
  Alcotest.test_case "sync failure and replacement through actual descriptors" `Quick test_sync_failure_and_actual_replacement_preserve_original_read_boundary;
  Alcotest.test_case "large originals verify every chunk and EOF" `Quick
    test_large_original_reverification_checks_every_chunk_and_eof;
  Alcotest.test_case "fresh ownership and permissions after I/O" `Quick test_fresh_ancestor_and_file_permissions_are_checked_after_io;
  Alcotest.test_case "actual held read serializes aliased publication without blocking other scopes" `Quick
    test_original_publication_waits_for_actual_read_across_store_aliases];
  "settle",[
  Alcotest.test_case "a settled original leaves the scope with its body" `Quick
    test_a_settled_original_leaves_the_scope_with_its_body;
  Alcotest.test_case "a changed record is not settled" `Quick test_a_changed_record_is_not_settled;
  Alcotest.test_case "settling again finishes a move that stopped after the record" `Quick
    test_settling_again_finishes_a_move_that_stopped_after_the_record;
  Alcotest.test_case "a settle that cannot move the record moves nothing" `Quick
    test_a_settle_that_cannot_move_the_record_moves_nothing;
  Alcotest.test_case "a date that is not a day and a missing original are refused" `Quick
    test_a_settle_refuses_a_date_that_is_not_a_day_and_a_missing_original]]
