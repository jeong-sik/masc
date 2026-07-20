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
    ]
