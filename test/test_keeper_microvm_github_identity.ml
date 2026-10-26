open Alcotest
module Store = Masc.Keeper_microvm_github_identity
module Lifecycle = Masc.Keeper_microvm_lifecycle
module Github = Masc.Keeper_github_identity
module Backend = Masc.Keeper_microvm_backend
module Names = Masc.Keeper_sandbox_container_name

let value = function Ok value -> value | Error error -> fail (Store.error_message error)
let captured_value = function Ok value -> value | Error detail -> fail detail
let keeper_name = "identity-store-fixture"
let backend = Backend.Apple_container
let network_mode = Keeper_types_profile_sandbox.Network_none

let write path content =
  let out = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr out) (fun () -> output_string out content)

let read path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec writable path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Unix.chmod path 0o700;
    Sys.readdir path |> Array.iter (fun leaf -> writable (Filename.concat path leaf))
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR | Unix.S_BLK -> ()

type fixture =
  { fs : Eio.Fs.dir_ty Eio.Path.t
  ; base_path : string
  ; coordinator : Lifecycle.t
  ; listing : string
  ; status : string
  ; calls : string
  }

let with_fixture callback =
  Eio_main.run @@ fun env ->
  let base_path = Filename.temp_dir "masc-identity-store-" "" in
  let previous_path = Sys.getenv "PATH" in
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init ~cwd_default:Eio.Path.(fs / base_path)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:(fun () ->
    Process_eio.reset_for_testing ();
    Fs_compat.clear_fs ();
    Unix.putenv "PATH" previous_path;
    writable base_path;
    Fs_compat.remove_tree base_path) (fun () ->
      Unix.mkdir (Config_dir_resolver.masc_root ~base_path) 0o700;
      let bin = Filename.concat base_path "bin" in
      Unix.mkdir bin 0o700;
      let listing = Filename.concat base_path "listing.json" in
      let status = Filename.concat base_path "status" in
      let calls = Filename.concat base_path "calls" in
      write listing "[]"; write status "0"; write calls "";
      let cli = Filename.concat bin "container" in
      write cli (Printf.sprintf
        "#!/bin/sh\nprintf '%%s\\n' \"$*\" >> %s\n/bin/cat %s\nexit \"$(/bin/cat %s)\"\n"
        (Filename.quote calls) (Filename.quote listing) (Filename.quote status));
      Unix.chmod cli 0o700;
      Unix.putenv "PATH" (bin ^ ":" ^ previous_path);
      callback {fs; base_path; coordinator=Lifecycle.create (); listing; status; calls})

let path f = Store.host_path ~base_path:f.base_path ~keeper_name ~backend ~network_mode
let owner f callback = Lifecycle.with_keeper_scope f.coordinator ~keeper_name callback
let load f scope = Store.load ~fs:f.fs ~coordinator:f.coordinator ~scope
    ~base_path:f.base_path ~keeper_name ~backend ~network_mode
let publish f scope captured = Store.publish_if_guest_absent ~fs:f.fs
    ~coordinator:f.coordinator ~scope ~base_path:f.base_path ~keeper_name ~backend ~network_mode
    ~timeout_sec:5. captured
let remove f scope = Store.remove_if_guest_absent ~fs:f.fs
    ~coordinator:f.coordinator ~scope ~base_path:f.base_path ~keeper_name ~backend ~network_mode
    ~timeout_sec:5.
let unconfigured () = captured_value (Github.captured_tool_identity_of_files [])

let configured f =
  let config = Masc.Workspace.default_config f.base_path in
  let keepers = Masc.Workspace.keepers_runtime_dir config in
  if not (Sys.file_exists keepers) then Unix.mkdir keepers 0o700;
  let directory = captured_value (Github.ensure_config_dir ~config ~keeper_name) in
  let hosts = "github.com:\n    user: fixture\n    oauth_token: fake-identity-store-token\n    git_protocol: https\n" in
  write (Filename.concat directory "hosts.yml") hosts;
  write (Filename.concat directory "config.yml") "git_protocol: https\r\n";
  List.iter (fun leaf -> Unix.chmod (Filename.concat directory leaf) 0o600)
    ["hosts.yml"; "config.yml"];
  captured_value (Github.capture_tool_identity ~config ~keeper_name), directory, hosts

let test_publish_reload () = with_fixture @@ fun f ->
  let captured, central, hosts = configured f in
  let snapshot = owner f (fun scope -> value (publish f scope captured)) in
  check string "deterministic mount source" (path f) (Store.path snapshot);
  check string "original exact credential bytes" hosts (read (Filename.concat (path f) "hosts.yml"));
  check int "sealed guest" 0o500 (Unix.lstat (path f)).st_perm;
  List.iter (fun leaf -> check int "sealed regular file" 0o400
      (Unix.lstat (Filename.concat (path f) leaf)).st_perm) ["hosts.yml"; "config.yml"; "gitconfig"];
  let rec parents directory =
    if directory <> Config_dir_resolver.masc_root ~base_path:f.base_path then (
      check int "private parent" 0o700 (Unix.lstat directory).st_perm;
      parents (Filename.dirname directory)) in
  parents (Filename.dirname (path f));
  write (Filename.concat central "hosts.yml") "github.com:\n    oauth_token: changed-fake-token\n";
  let coordinator = Lifecycle.create () in
  let reloaded = Lifecycle.with_keeper_scope coordinator ~keeper_name (fun scope ->
    value (Store.load ~fs:f.fs ~coordinator ~scope ~base_path:f.base_path ~keeper_name ~backend ~network_mode)) in
  let reloaded = match reloaded with Some snapshot -> snapshot | None -> fail "snapshot lost" in
  check string "fresh owner derives revision from mounted bytes" (Store.revision snapshot) (Store.revision reloaded);
  check (list (pair string string)) "captured credential environment survives central mutation"
    (Store.environment snapshot ~container_config_dir:"/guest/github")
    (Store.environment reloaded ~container_config_dir:"/guest/github");
  check string "central mutation cannot change mounted credentials" hosts (read (Filename.concat (path f) "hosts.yml"));
  let inode = (Unix.lstat (path f)).st_ino in
  (match owner f (fun scope -> publish f scope captured) with
   | Error Store.Snapshot_already_exists -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "existing immutable snapshot overwritten");
  check int "repeat preserves inode" inode (Unix.lstat (path f)).st_ino

let test_missing_and_empty () = with_fixture @@ fun f ->
  check bool "missing differs from empty" true (owner f (fun scope -> value (load f scope)) = None);
  let snapshot = owner f (fun scope -> value (publish f scope (unconfigured ()))) in
  check (list string) "existing empty payload" [] (Sys.readdir (path f) |> Array.to_list);
  let loaded = owner f (fun scope -> value (load f scope)) in
  match loaded with
  | None -> fail "empty published snapshot read as missing"
  | Some loaded -> check string "stable unconfigured revision" (Store.revision snapshot) (Store.revision loaded)

let check_refused result = match result with
  | Error _ -> ()
  | Ok _ -> fail "unsafe snapshot accepted"

let test_guest_present () = with_fixture @@ fun f ->
  let guest = Names.make (Names.Micro_vm_persistent
    {base_path=f.base_path; keeper_name; network_mode}) |> Names.to_string in
  write f.listing (Yojson.Safe.to_string (`List [`Assoc
    ["id", `String guest; "configuration", `Assoc ["labels", `String "malformed foreign labels"]]]));
  (match owner f (fun scope -> publish f scope (unconfigured ())) with
   | Error Store.Guest_present -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "running guest credentials published");
  check bool "no snapshot parent mutation" false
    (Sys.file_exists (Filename.concat (Config_dir_resolver.masc_root ~base_path:f.base_path) "microvm"));
  check string "one full unfiltered list only" "list --all --format json\n" (read f.calls)

let test_inventory_unavailable () = with_fixture @@ fun f ->
  write f.status "1";
  (match owner f (fun scope -> publish f scope (unconfigured ())) with
   | Error (Store.Inventory_unavailable _) -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "failed listing authorized publication");
  check bool "snapshot absent after failed inventory" false (Sys.file_exists (path f))

let test_modes () = with_fixture @@ fun f ->
  let captured, _, _ = configured f in
  ignore (owner f (fun scope -> value (publish f scope captured)));
  let hosts = Filename.concat (path f) "hosts.yml" in
  Unix.chmod hosts 0o600;
  check_refused (owner f (fun scope -> load f scope));
  Unix.chmod hosts 0o400;
  Unix.chmod (path f) 0o700;
  check_refused (owner f (fun scope -> load f scope));
  Unix.chmod (path f) 0o500;
  let parent = Filename.dirname (path f) in
  Unix.chmod parent 0o755;
  check_refused (owner f (fun scope -> load f scope));
  check int "no chmod repair" 0o755 (Unix.lstat parent).st_perm

let test_shared_microvm_parent () = with_fixture @@ fun f ->
  let microvm = Filename.concat (Config_dir_resolver.masc_root ~base_path:f.base_path) "microvm" in
  Unix.mkdir microvm 0o755;
  let shim = Filename.concat microvm "shim" in
  Unix.mkdir shim 0o755;
  write (Filename.concat shim "installed-shim") "existing shared sibling";
  ignore (owner f (fun scope -> value (publish f scope (unconfigured ()))));
  check int "existing installer parent stays0755" 0o755 (Unix.lstat microvm).st_perm;
  check string "existing shim sibling remains" "existing shared sibling" (read (Filename.concat shim "installed-shim"));
  check int "credential-only identity parent stays0700" 0o700
    (Unix.lstat (Filename.concat microvm "identity")).st_perm;
  check bool "shared layout reload succeeds" true (Option.is_some (owner f (fun scope -> value (load f scope))))

let test_unknown_and_links () = with_fixture @@ fun f ->
  ignore (owner f (fun scope -> value (publish f scope (unconfigured ()))));
  Unix.chmod (path f) 0o700;
  let unknown = Filename.concat (path f) "unknown" in
  write unknown "private fixture";
  Unix.chmod (path f) 0o500;
  check_refused (owner f (fun scope -> load f scope));
  Unix.chmod (path f) 0o700; Unix.unlink unknown;
  Unix.symlink f.listing (Filename.concat (path f) "hosts.yml");
  Unix.chmod (path f) 0o500;
  check_refused (owner f (fun scope -> load f scope));
  check string "link target unchanged" "[]" (read f.listing)

let test_parent_link () = with_fixture @@ fun f ->
  let outside = Filename.concat f.base_path "outside" in Unix.mkdir outside 0o700;
  Unix.symlink outside (Filename.concat (Config_dir_resolver.masc_root ~base_path:f.base_path) "microvm");
  check_refused (owner f (fun scope -> publish f scope (unconfigured ())));
  check (list string) "no symlink traversal" [] (Sys.readdir outside |> Array.to_list)

let test_root_link () = with_fixture @@ fun f ->
  let root = Config_dir_resolver.masc_root ~base_path:f.base_path in
  let moved = Filename.concat f.base_path "moved-state" in
  Unix.rename root moved;
  Unix.symlink moved root;
  check_refused (owner f (fun scope -> load f scope));
  check (list string) "root symlink does not authorize recovery writes" [] (Sys.readdir moved |> Array.to_list)

let test_hardlink_and_changed_bytes () = with_fixture @@ fun f ->
  let captured, _, original = configured f in
  ignore (owner f (fun scope -> value (publish f scope captured)));
  let hosts = Filename.concat (path f) "hosts.yml" in
  let alias = Filename.concat f.base_path "credential-alias" in
  Unix.link hosts alias;
  check_refused (owner f (fun scope -> load f scope));
  check string "hardlink rejection preserves bytes" original (read hosts);
  Unix.unlink alias;
  Unix.chmod hosts 0o600;
  write hosts "enterprise.example:\n    oauth_token: changed-fake-token\n";
  Unix.chmod hosts 0o400;
  check_refused (owner f (fun scope -> load f scope))

let test_scope () = with_fixture @@ fun f ->
  let expired = owner f (fun scope -> scope) in
  (match publish f expired (unconfigured ()) with
   | Error (Store.Scope_unavailable Lifecycle.Scope_closed) -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "expired owner accepted");
  Lifecycle.with_keeper_scope f.coordinator ~keeper_name:"other-keeper" (fun scope ->
    match publish f scope (unconfigured ()) with
    | Error (Store.Scope_unavailable Lifecycle.Other_keeper) -> ()
    | Error error -> fail (Store.error_message error)
    | Ok _ -> fail "other keeper accepted");
  let other = Lifecycle.create () in
  Lifecycle.with_keeper_scope other ~keeper_name (fun scope ->
    match publish f scope (unconfigured ()) with
    | Error (Store.Scope_unavailable Lifecycle.Other_coordinator) -> ()
    | Error error -> fail (Store.error_message error)
    | Ok _ -> fail "other coordinator accepted");
  check string "refused scopes perform no inventory calls" "" (read f.calls)

let removed = function
  | Ok Store.Removed -> ()
  | Ok Store.Already_absent -> fail "existing snapshot reported as already absent"
  | Error error -> fail (Store.error_message error)

let test_remove_empty_and_repeat () = with_fixture @@ fun f ->
  (match owner f (fun scope -> remove f scope) with
   | Ok Store.Already_absent -> ()
   | Ok Store.Removed -> fail "missing snapshot reported as removed"
   | Error error -> fail (Store.error_message error));
  ignore (owner f (fun scope -> value (publish f scope (unconfigured ()))));
  let parent = Filename.dirname (path f) in
  let parent_before = Unix.lstat parent in
  removed (owner f (fun scope -> remove f scope));
  check bool "empty sealed target removed" false (Sys.file_exists (path f));
  (match owner f (fun scope -> remove f scope) with
   | Ok Store.Already_absent -> ()
   | Ok Store.Removed -> fail "repeat removal invented an existing target"
   | Error error -> fail (Store.error_message error));
  let parent_after = Unix.lstat parent in
  check int "parent identity retained" parent_before.st_ino parent_after.st_ino;
  check int "parent permissions retained" parent_before.st_perm parent_after.st_perm;
  check string "every remove reads a new complete inventory"
    (String.concat "" (List.init 4 (fun _ -> "list --all --format json\n"))) (read f.calls)

let test_remove_configured_and_unknown_entries () = with_fixture @@ fun f ->
  let captured, central, hosts = configured f in
  ignore (owner f (fun scope -> value (publish f scope captured)));
  let outside = Filename.concat f.base_path "external-credential-target" in
  write outside "external bytes must survive";
  Unix.chmod (path f) 0o700;
  let orphan = Filename.concat (path f) "unknown-orphan" in
  write orphan "old private fixture bytes";
  Unix.chmod orphan 0o400;
  Unix.symlink outside (Filename.concat (path f) "unknown-link");
  Unix.chmod (path f) 0o500;
  removed (owner f (fun scope -> remove f scope));
  check bool "configured immutable snapshot removed" false (Sys.file_exists (path f));
  check string "unknown link was not followed" "external bytes must survive" (read outside);
  check string "central credentials preserved" hosts (read (Filename.concat central "hosts.yml"))

let test_remove_present_or_failed_inventory () = with_fixture @@ fun f ->
  let captured, _, hosts = configured f in
  ignore (owner f (fun scope -> value (publish f scope captured)));
  let original = Unix.lstat (path f) in
  let guest = Names.make (Names.Micro_vm_persistent
    {base_path=f.base_path; keeper_name; network_mode}) |> Names.to_string in
  write f.listing (Yojson.Safe.to_string (`List [`Assoc ["id", `String guest]]));
  (match owner f (fun scope -> remove f scope) with
   | Error Store.Guest_present -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "present guest authorized removal");
  check int "present guest keeps sealed mode" 0o500 (Unix.lstat (path f)).st_perm;
  write f.listing "[]";
  write f.status "1";
  (match owner f (fun scope -> remove f scope) with
   | Error (Store.Inventory_unavailable _) -> ()
   | Error error -> fail (Store.error_message error)
   | Ok _ -> fail "failed inventory authorized removal");
  check int "failed inventory keeps target identity" original.st_ino (Unix.lstat (path f)).st_ino;
  check int "failed inventory keeps sealed mode" 0o500 (Unix.lstat (path f)).st_perm;
  check string "refused removal preserves credential bytes" hosts (read (Filename.concat (path f) "hosts.yml"))

let test_remove_rejects_parent_link () = with_fixture @@ fun f ->
  let outside = Filename.concat f.base_path "external-tree" in
  Unix.mkdir outside 0o700;
  write (Filename.concat outside "preserved") "outside owned identity chain";
  let shared = Filename.concat (Config_dir_resolver.masc_root ~base_path:f.base_path) "microvm" in
  Unix.symlink outside shared;
  check_refused (owner f (fun scope -> remove f scope));
  check bool "parent link not removed" true ((Unix.lstat shared).st_kind = Unix.S_LNK);
  check string "external parent target not traversed" "outside owned identity chain"
    (read (Filename.concat outside "preserved"));
  check int "external mode unchanged" 0o700 (Unix.lstat outside).st_perm

let test_remove_rejects_target_link () = with_fixture @@ fun f ->
  ignore (owner f (fun scope -> value (publish f scope (unconfigured ()))));
  let outside = Filename.concat f.base_path "moved-snapshot" in
  (* Construct the hostile state with owner authority. Linux requires write
     access to a moved directory when rename updates its parent entry. *)
  Unix.chmod (path f) 0o700;
  Unix.rename (path f) outside;
  Unix.chmod outside 0o500;
  Unix.symlink outside (path f);
  check_refused (owner f (fun scope -> remove f scope));
  check bool "target link retained" true ((Unix.lstat (path f)).st_kind = Unix.S_LNK);
  check int "external target stays sealed" 0o500 (Unix.lstat outside).st_perm;
  check (list string) "external target untouched" [] (Sys.readdir outside |> Array.to_list)

let test_remove_resumes_partial_writable_target () = with_fixture @@ fun f ->
  let captured, central, hosts = configured f in
  ignore (owner f (fun scope -> value (publish f scope captured)));
  (* An interrupted earlier removal may have prepared the owned directory and
     removed some entries. This is a fixture state, never a load-time repair. *)
  Unix.chmod (path f) 0o700;
  Unix.unlink (Filename.concat (path f) "config.yml");
  check_refused (owner f (fun scope -> load f scope));
  check_refused (owner f (fun scope -> publish f scope captured));
  check int "ordinary operations did not reseal partial target" 0o700 (Unix.lstat (path f)).st_perm;
  removed (owner f (fun scope -> remove f scope));
  check bool "new absence allows exact partial target removal" false (Sys.file_exists (path f));
  check string "partial cleanup preserved central credentials" hosts (read (Filename.concat central "hosts.yml"));
  check string "partial retry obtains another actual inventory"
    (String.concat "" (List.init 3 (fun _ -> "list --all --format json\n"))) (read f.calls)

let () = run "microvm guest credential store"
  ["actual immutable publication and reload", [
    test_case "configured bytes survive central mutation and fresh owner" `Quick test_publish_reload;
    test_case "missing and sealed empty differ" `Quick test_missing_and_empty;
    test_case "full inventory present before mutation" `Quick test_guest_present;
    test_case "failed inventory preserves missing snapshot" `Quick test_inventory_unavailable;
    test_case "exact file guest and parent modes" `Quick test_modes;
    test_case "existing0755 microvm and shim sibling are preserved" `Quick test_shared_microvm_parent;
    test_case "unknown entries and file symlinks refuse" `Quick test_unknown_and_links;
    test_case "parent symlink refuses" `Quick test_parent_link;
    test_case "workspace state root symlink refuses" `Quick test_root_link;
    test_case "hardlinked or noncanonical credential files refuse" `Quick test_hardlink_and_changed_bytes;
    test_case "expired and foreign scope cannot mutate" `Quick test_scope;
    test_case "remove sealed empty target and distinguish missing repeats" `Quick test_remove_empty_and_repeat;
    test_case "remove configured target without following unknown links" `Quick test_remove_configured_and_unknown_entries;
    test_case "removal preserves sealed bytes on present or failed inventory" `Quick test_remove_present_or_failed_inventory;
    test_case "removal refuses parent symlinks" `Quick test_remove_rejects_parent_link;
    test_case "removal refuses target symlinks" `Quick test_remove_rejects_target_link;
    test_case "new absence resumes partial0700 target without Ready promotion" `Quick test_remove_resumes_partial_writable_target]]
