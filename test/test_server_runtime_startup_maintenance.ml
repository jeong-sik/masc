(** Unit tests for [Server_runtime_startup_maintenance.prune_children_dirs]. *)

module SM = Server_runtime_startup_maintenance

let counter = ref 0

let fresh_dir prefix =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%.0f" prefix (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let record_prune dir =
  incr counter;
  String.length dir

let test_missing_root_counts_zero () =
  counter := 0;
  let n =
    SM.prune_children_dirs ~prune_dir:record_prune "/nonexistent/masc-prune-children"
  in
  Alcotest.(check int) "missing root counts 0" 0 n;
  Alcotest.(check int) "prune_dir never called" 0 !counter

let test_subdirs_pruned_and_stray_files_skipped () =
  counter := 0;
  let root = fresh_dir "masc_prune_children" in
  let keeper_a = Filename.concat root "keeper-a" in
  let keeper_b = Filename.concat root "keeper-b" in
  Fs_compat.mkdir_p keeper_a;
  Fs_compat.mkdir_p keeper_b;
  let stray = Filename.concat root "stray.txt" in
  let oc = open_out stray in
  output_string oc "x";
  close_out oc;
  let n = SM.prune_children_dirs ~prune_dir:record_prune root in
  Alcotest.(check int) "prune called for both subdirs" 2 !counter;
  Alcotest.(check bool)
    "return sums prune_dir results" true (n = String.length keeper_a + String.length keeper_b)

let test_prune_flat_jsonl_removes_old_files () =
  (* Regression guard for the trajectories no-op: populated
     trajectories/<keeper>/ layout must yield pruned > 0. *)
  let root = fresh_dir "masc_prune_flat" in
  let keeper = Filename.concat root "keeper-a" in
  Fs_compat.mkdir_p keeper;
  let write path =
    let oc = open_out path in
    output_string oc "{}\n";
    close_out oc
  in
  let old_file = Filename.concat keeper "trace-old.jsonl" in
  let recent_file = Filename.concat keeper "trace-recent.jsonl" in
  let stray = Filename.concat keeper "notes.txt" in
  write old_file;
  write recent_file;
  write stray;
  let old_ts = Unix.gettimeofday () -. (40. *. 86400.) in
  Unix.utimes old_file old_ts old_ts;
  let n =
    SM.prune_children_dirs
      ~prune_dir:(SM.prune_flat_jsonl_older_than ~days:30)
      root
  in
  Alcotest.(check int) "old trajectory pruned" 1 n;
  Alcotest.(check bool) "old file removed" false (Sys.file_exists old_file);
  Alcotest.(check bool) "recent file kept" true (Sys.file_exists recent_file);
  Alcotest.(check bool) "non-jsonl file kept" true (Sys.file_exists stray)

(* Regression: a symlinked child must NOT be followed. [prune_dir] leads to
   day-file deletion, so following a symlink here would prune the link target
   outside the workspace. The symlink points at a real external directory, so
   the previous [Sys.is_directory] guard (which follows symlinks) would call
   [prune_dir] on the external target — reverting the [lstat]-based
   [is_real_directory] guard turns this test RED (counter 2 instead of 1). *)
let test_symlinked_child_not_followed () =
  counter := 0;
  let root = fresh_dir "masc_prune_children_symlink" in
  let real_child = Filename.concat root "real-keeper" in
  Fs_compat.mkdir_p real_child;
  let external_target = fresh_dir "masc_prune_external_target" in
  let link = Filename.concat root "linked-keeper" in
  Unix.symlink external_target link;
  let n = SM.prune_children_dirs ~prune_dir:record_prune root in
  Alcotest.(check int) "prune called only for the real child" 1 !counter;
  Alcotest.(check bool)
    "return counts only the real child" true (n = String.length real_child)

(* Regression: the traversal ROOT itself may be the symlink. Guarding only the
   children does not help — [Sys.readdir] resolves a symlinked root, so the
   target's real directories arrive as ordinary children and every one of them
   gets pruned. Dropping the root [is_real_directory] check turns this RED
   (counter 1 instead of 0). *)
let test_symlinked_root_not_followed () =
  counter := 0;
  let external_target = fresh_dir "masc_prune_external_root_target" in
  Fs_compat.mkdir_p (Filename.concat external_target "victim");
  let link = Filename.concat (fresh_dir "masc_prune_root_link_parent") "linked-root" in
  Unix.symlink external_target link;
  let n = SM.prune_children_dirs ~prune_dir:record_prune link in
  Alcotest.(check int) "prune never called through a symlinked root" 0 !counter;
  Alcotest.(check int) "symlinked root counts zero" 0 n

(* Regression: a real keeper dir can still hold a symlinked [metrics] store.
   The keeper-level guard says nothing about its children, so without
   [prune_store_dir] the external target is pruned. *)
let test_symlinked_store_not_followed () =
  counter := 0;
  let keeper_dir = fresh_dir "masc_prune_keeper_store" in
  let real_store = Filename.concat keeper_dir "crash-events" in
  Fs_compat.mkdir_p real_store;
  let external_target = fresh_dir "masc_prune_external_store_target" in
  let linked_store = Filename.concat keeper_dir "metrics" in
  Unix.symlink external_target linked_store;
  let n =
    SM.prune_store_dir ~prune_dir:record_prune linked_store
    + SM.prune_store_dir ~prune_dir:record_prune real_store
  in
  Alcotest.(check int) "prune called only for the real store" 1 !counter;
  Alcotest.(check bool)
    "return counts only the real store"
    true
    (n = String.length real_store)

let () =
  Alcotest.run "server_runtime_startup_maintenance"
    [
      ( "prune_children_dirs",
        [
          Alcotest.test_case "missing root counts zero" `Quick
            test_missing_root_counts_zero;
          Alcotest.test_case "subdirs pruned, stray files skipped" `Quick
            test_subdirs_pruned_and_stray_files_skipped;
          Alcotest.test_case "symlinked child is not followed" `Quick
            test_symlinked_child_not_followed;
          Alcotest.test_case "symlinked root is not followed" `Quick
            test_symlinked_root_not_followed;
        ] );
      ( "prune_store_dir",
        [
          Alcotest.test_case "symlinked store is not followed" `Quick
            test_symlinked_store_not_followed;
        ] );
      ( "prune_flat_jsonl_older_than",
        [
          Alcotest.test_case "populated trajectories dir prunes old files" `Quick
            test_prune_flat_jsonl_removes_old_files;
        ] );
    ]
