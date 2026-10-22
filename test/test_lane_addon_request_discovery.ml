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
  ~installation_id:"original-installation" ~package_id:"curator" ~tool:"classify" ~request)
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
    (List.map (fun (r : Owner.retained) -> r.request_id) records);
  let restored = List.find (fun (r : Owner.retained) -> r.request_id="a") records in
  Alcotest.check json "original progress survives restart discovery"
    (Progress.to_json pending.progress) (Progress.to_json restored.progress);
  Alcotest.check json "complete original input survives" request restored.request;
  Alcotest.(check string) "destination is the original installation" "original-installation" restored.installation_id)

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
  fail_inventory (Owner.discover ~store ~scope))

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

let test_fresh_ancestor_and_file_permissions_are_checked_after_io () =
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun fd -> Unix.fsync fd;Unix.chmod root 0o777)));
  with_store (fun root store -> retain store "original";
    fail_inventory (inventory store ~sync_file:(fun fd -> Unix.fsync fd;Unix.chmod (path root "original") 0o666)));
  with_store (fun root store -> retain store "original";
    let result = Fs_compat.with_owned_inventory_root (Filename.dirname root) (fun held ->
      Fs_compat.with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid () + 1) held
        (path root "original") (fun ~file:_ ~parent:_ ~stat:_ -> ())) in
    fail_inventory result)

let () = Alcotest.run "Original Add-on request discovery" ["inventory",[
  Alcotest.test_case "restart discovers original input and progress" `Quick test_restart_discovers_original_input_progress_and_scope;
  Alcotest.test_case "absence requires owned settled authority and creates nothing" `Quick test_initial_absence_requires_existing_safe_anchor_without_creation;
  Alcotest.test_case "bad record and unknown entry refuse complete inventory" `Quick test_bad_record_or_unknown_name_never_returns_a_partial_inventory;
  Alcotest.test_case "listed disappearance and directory replacement" `Quick test_listed_disappearance_and_same_name_directory_replacement_are_errors;
  Alcotest.test_case "symlink hardlink and nonregular records" `Quick test_symlink_hardlink_and_nonregular_records_are_refused;
  Alcotest.test_case "sync failure and replacement through actual descriptors" `Quick test_sync_failure_and_actual_replacement_preserve_original_read_boundary;
  Alcotest.test_case "fresh ownership and permissions after I/O" `Quick test_fresh_ancestor_and_file_permissions_are_checked_after_io]]
