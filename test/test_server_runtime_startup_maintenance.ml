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

let () =
  Alcotest.run "server_runtime_startup_maintenance"
    [
      ( "prune_children_dirs",
        [
          Alcotest.test_case "missing root counts zero" `Quick
            test_missing_root_counts_zero;
          Alcotest.test_case "subdirs pruned, stray files skipped" `Quick
            test_subdirs_pruned_and_stray_files_skipped;
        ] );
      ( "prune_flat_jsonl_older_than",
        [
          Alcotest.test_case "populated trajectories dir prunes old files" `Quick
            test_prune_flat_jsonl_removes_old_files;
        ] );
    ]
