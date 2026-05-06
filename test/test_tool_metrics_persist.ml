(** Tests for Tool_metrics_persist — JSONL disk persistence round-trip *)

module P = Masc_mcp.Tool_metrics_persist
module M = Masc_mcp.Tool_metrics
module R = Masc_mcp.Tool_result

let make_result ~name ~success ~duration_ms =
  { R.success; data = `Null; legacy_message = ""; tool_name = name; duration_ms }

(** Wrap each test in Eio_main.run for Eio.Mutex support. *)
let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

(** Create a temp directory for test isolation. *)
let with_tmp_dir f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test-tool-metrics-persist-%d-%d"
       (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1000.0))) in
  Fs_compat.mkdir_p (Filename.concat dir "data/tool-metrics");
  P.reset_for_testing ();
  Fun.protect ~finally:(fun () ->
    P.reset_for_testing ();
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let test_enqueue_flush_restore () =
  with_tmp_dir (fun base_path ->
    M.clear ();
    (* Initialize the store by triggering restore on the empty dir *)
    ignore (P.restore ~base_path);
    (* Enqueue some records *)
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue (make_result ~name:"alpha" ~success:false ~duration_ms:5.0);
    P.enqueue (make_result ~name:"beta" ~success:true ~duration_ms:20.0);
    (* flush_now drains the queue to disk *)
    P.flush_now ();
    (* Clear in-memory metrics to verify restore works from disk *)
    M.clear ();
    Alcotest.(check bool) "cleared" true (Option.is_none (M.stats_for "alpha"));
    (* Restore from disk *)
    let n = P.restore ~base_path in
    Alcotest.(check int) "restored 3 records" 3 n;
    (* Verify metrics are restored *)
    (match M.stats_for "alpha" with
     | Some s ->
       Alcotest.(check int) "alpha call_count" 2 s.call_count;
       Alcotest.(check int) "alpha success" 1 s.success_count;
       Alcotest.(check int) "alpha failure" 1 s.failure_count
     | None -> Alcotest.fail "expected alpha stats");
    (match M.stats_for "beta" with
     | Some s ->
       Alcotest.(check int) "beta call_count" 1 s.call_count;
       Alcotest.(check int) "beta success" 1 s.success_count
     | None -> Alcotest.fail "expected beta stats"))

let test_restore_empty_dir () =
  with_tmp_dir (fun base_path ->
    M.clear ();
    let n = P.restore ~base_path in
    Alcotest.(check int) "no records" 0 n)

let test_malformed_lines_skipped () =
  with_tmp_dir (fun base_path ->
    M.clear ();
    (* Write a malformed line directly to the JSONL file *)
    let dir = Filename.concat base_path "data/tool-metrics" in
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    let month_dir = Filename.concat dir
      (Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)) in
    Fs_compat.mkdir_p month_dir;
    let day_file = Filename.concat month_dir
      (Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday) in
    (* One valid, one malformed *)
    let valid_line = Yojson.Safe.to_string
      (`Assoc [
        ("tool_name", `String "good");
        ("success", `Bool true);
        ("duration_ms", `Float 7.0);
        ("ts", `Float 1000.0);
      ]) in
    let malformed_line = "{\"garbage\": true}" in
    let content = valid_line ^ "\n" ^ malformed_line ^ "\n" in
    Fs_compat.append_file day_file content;
    let n = P.restore ~base_path in
    Alcotest.(check int) "only valid record" 1 n;
    (match M.stats_for "good" with
     | Some s -> Alcotest.(check int) "good count" 1 s.call_count
     | None -> Alcotest.fail "expected good stats"))

let test_reset_clears_cached_store () =
  with_tmp_dir (fun base_path ->
    ignore (P.restore ~base_path);
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:1.0);
    P.reset_for_testing ();
    P.flush_now ();
    let restored = P.restore ~base_path in
    Alcotest.(check int) "reset drops queued records and cache" 0 restored)

let () =
  Alcotest.run "Tool_metrics_persist" [
    "persistence", [
      eio_test "enqueue, flush, restore round-trip"
        test_enqueue_flush_restore;
      eio_test "restore from empty dir"
        test_restore_empty_dir;
      eio_test "malformed lines skipped"
        test_malformed_lines_skipped;
      eio_test "reset clears cached store"
        test_reset_clears_cached_store;
    ];
  ]
