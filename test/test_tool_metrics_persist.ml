(** Tests for the single SQLite tool-metrics store. *)

module P = Masc.Tool_metrics_persist
module R = Tool_result

let make_result ~name ~success ~duration_ms : R.result =
  if success
  then R.Completed { R.tool_name = name; data = `Null; metadata = None; duration_ms }
  else
    R.Failed
      { R.class_ = Runtime_failure
      ; message = ""
      ; data = `Null
      ; metadata = None
      ; tool_name = name
      ; duration_ms
      }

let eio_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn ())

let with_tmp_dir f =
  let dir = Filename.temp_dir "test-tool-metrics-persist-" "" in
  P.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      P.reset_for_testing ();
      Tool_metrics.clear ();
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let get_ok label = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s: %s" label error

let string_field key json =
  match Safe_ops.json_string_opt key json with
  | Some value -> value
  | None -> Alcotest.failf "missing string field %s" key

let test_enqueue_writes_directly_to_sqlite () =
  with_tmp_dir (fun base_path ->
    P.enqueue
      ~base_path
      (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue
      ~base_path
      (make_result ~name:"alpha" ~success:false ~duration_ms:5.0);
    P.enqueue
      ~base_path
      (R.Deferred
         { R.tool_name = "alpha"
         ; data = `Null
         ; metadata = None
         ; duration_ms = 3.0
         });
    P.enqueue
      ~base_path
      (make_result ~name:"beta" ~success:true ~duration_ms:20.0);
    let summary = P.store_summary ~base_path |> get_ok "store summary" in
    Alcotest.(check bool) "database exists" true summary.exists;
    Alcotest.(check int) "four rows committed" 4 summary.entry_count;
    Alcotest.(check string)
      "runtime-state database path"
      (Filename.concat base_path ".masc/tool-metrics.sqlite3")
      summary.path;
    Alcotest.(check bool)
      "no bulk-data metrics copy"
      false
      (Sys.file_exists (Filename.concat base_path "data/tool-metrics"));
    let rows =
      P.read_recent ~base_path ~n:10 () |> get_ok "read recent rows"
    in
    Alcotest.(check int) "four rows readable" 4 (List.length rows);
    Alcotest.(check (list string))
      "all dispositions retained"
      [ "completed"; "completed"; "deferred"; "failed" ]
      (rows
       |> List.map (string_field "disposition")
       |> List.sort String.compare))

let test_restart_hydrates_without_duplicates () =
  with_tmp_dir (fun base_path ->
    P.enqueue
      ~base_path
      (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue
      ~base_path
      (R.Deferred
         { R.tool_name = "alpha"
         ; data = `Null
         ; metadata = None
         ; duration_ms = 20.0
         });
    P.enqueue
      ~base_path
      (make_result ~name:"beta" ~success:false ~duration_ms:30.0);
    P.reset_for_testing ();
    Tool_metrics.clear ();
    let report =
      P.hydrate ~base_path ~retention_days:30 |> get_ok "first hydrate"
    in
    Alcotest.(check int) "three rows loaded" 3 report.loaded_records;
    Alcotest.(check int) "nothing pruned" 0 report.pruned_records;
    let alpha = Option.get (Tool_metrics.stats_for "alpha") in
    Alcotest.(check int) "alpha calls restored" 2 alpha.call_count;
    Alcotest.(check int) "alpha completed restored" 1 alpha.success_count;
    Alcotest.(check int) "alpha deferred restored" 1 alpha.deferred_count;
    let beta = Option.get (Tool_metrics.stats_for "beta") in
    Alcotest.(check int) "beta failed restored" 1 beta.failure_count;
    let second =
      P.hydrate ~base_path ~retention_days:30 |> get_ok "second hydrate"
    in
    Alcotest.(check int) "second load sees same rows" 3 second.loaded_records;
    Alcotest.(check int)
      "second hydration replaces aggregate"
      2
      (Option.get (Tool_metrics.stats_for "alpha")).call_count)

let insert_old_row ~base_path =
  P.reset_for_testing ();
  Tool_metrics_store.insert
    ~base_path
    { record_id = "old-record"
    ; ts = 1.0
    ; tool_name = "expired"
    ; disposition = "completed"
    ; duration_ms = 1.0
    }
  |> get_ok "insert old row"

let test_hydrate_prunes_expired_rows () =
  with_tmp_dir (fun base_path ->
    P.enqueue
      ~base_path
      (make_result ~name:"current" ~success:true ~duration_ms:2.0);
    insert_old_row ~base_path;
    let report =
      P.hydrate ~base_path ~retention_days:30 |> get_ok "hydrate after prune"
    in
    Alcotest.(check int) "one expired row pruned" 1 report.pruned_records;
    Alcotest.(check int) "one current row loaded" 1 report.loaded_records;
    Alcotest.(check bool)
      "expired metric absent"
      true
      (Option.is_none (Tool_metrics.stats_for "expired"));
    Alcotest.(check int)
      "database contains current row only"
      1
      (P.store_summary ~base_path |> get_ok "summary after prune").entry_count)

let test_multidomain_writes_are_serialized () =
  with_tmp_dir (fun base_path ->
    P.enqueue
      ~base_path
      (make_result ~name:"seed" ~success:true ~duration_ms:1.0);
    let spawn producer =
      Domain.spawn (fun () ->
        for i = 1 to 250 do
          P.enqueue
            ~base_path
            (make_result
               ~name:(Printf.sprintf "domain-%d-tool-%03d" producer i)
               ~success:true
               ~duration_ms:1.0)
        done)
    in
    let domains = List.init 4 spawn in
    List.iter Domain.join domains;
    let summary =
      P.store_summary ~base_path |> get_ok "multidomain store summary"
    in
    Alcotest.(check int) "all concurrent rows committed" 1001 summary.entry_count)

let test_duplicate_record_id_is_idempotent () =
  with_tmp_dir (fun base_path ->
    let row : Tool_metrics_store.row =
      { record_id = "same-record"
      ; ts = 1.0
      ; tool_name = "alpha"
      ; disposition = "completed"
      ; duration_ms = 1.0
      }
    in
    Tool_metrics_store.insert ~base_path row |> get_ok "first insert";
    Tool_metrics_store.insert ~base_path row |> get_ok "duplicate insert";
    Alcotest.(check int)
      "duplicate record id keeps one row"
      1
      (P.store_summary ~base_path |> get_ok "summary after duplicate").entry_count)

let test_write_failure_does_not_raise () =
  with_tmp_dir (fun base_path ->
    let masc_path = Filename.concat base_path ".masc" in
    Fs_compat.append_file masc_path "not-a-directory";
    P.enqueue
      ~base_path
      (make_result ~name:"unpersisted" ~success:true ~duration_ms:1.0);
    Alcotest.(check bool)
      "database was not created"
      false
      (Sys.file_exists (P.database_path ~base_path)))

let crash_child_arg = "--tool-metrics-crash-child"
let crash_child_rows = 250

let test_sigkill_recovery () =
  with_tmp_dir (fun base_path ->
    let argv = [| Sys.executable_name; crash_child_arg; base_path |] in
    let pid =
      Unix.create_process
        Sys.executable_name
        argv
        Unix.stdin
        Unix.stdout
        Unix.stderr
    in
    let rec wait_for_child () =
      try Unix.waitpid [] pid with
      | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
    in
    let _, status = wait_for_child () in
    (match status with
     | Unix.WSIGNALED signal ->
       Alcotest.(check int) "child stopped by SIGKILL" Sys.sigkill signal
     | Unix.WEXITED code -> Alcotest.failf "crash child exited %d" code
     | Unix.WSTOPPED signal ->
       Alcotest.failf "crash child stopped by signal %d" signal);
    Tool_metrics.clear ();
    let report =
      P.hydrate ~base_path ~retention_days:30
      |> get_ok "hydrate after SIGKILL"
    in
    Alcotest.(check int)
      "all committed rows survive SIGKILL"
      crash_child_rows
      report.loaded_records)

let run_crash_child base_path =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  for i = 1 to crash_child_rows do
    P.enqueue
      ~base_path
      (make_result
         ~name:(Printf.sprintf "crash-tool-%03d" i)
         ~success:true
         ~duration_ms:1.0)
  done;
  Unix.kill (Unix.getpid ()) Sys.sigkill;
  Stdlib.exit 2

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) crash_child_arg
  then run_crash_child Sys.argv.(2)
  else
    Alcotest.run
      "Tool_metrics_persist"
      [ ( "persistence"
        , [ eio_test
              "enqueue commits directly to SQLite"
              test_enqueue_writes_directly_to_sqlite
          ; eio_test
              "restart hydration replaces the aggregate"
              test_restart_hydrates_without_duplicates
          ; eio_test
              "startup hydration prunes expired rows"
              test_hydrate_prunes_expired_rows
          ; eio_test
              "writes from multiple domains are serialized"
              test_multidomain_writes_are_serialized
          ; eio_test
              "duplicate record ids are idempotent"
              test_duplicate_record_id_is_idempotent
          ; eio_test
              "storage failure does not change tool completion"
              test_write_failure_does_not_raise
          ; eio_test
              "committed rows survive SIGKILL"
              test_sigkill_recovery
          ] )
      ]
