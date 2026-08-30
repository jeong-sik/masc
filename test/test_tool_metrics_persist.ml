(** Tests for the tool metrics JSONL stream and startup hydration. *)

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
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let read_records ~base_path =
  let dir = Filename.concat base_path "data/tool-metrics" in
  if not (Sys.file_exists dir)
  then []
  else (
    let records = ref [] in
    let store = Dated_jsonl.create ~base_dir:dir () in
    Dated_jsonl.iter_all store (fun json -> records := json :: !records);
    List.rev !records)

let string_field key json =
  match Safe_ops.json_string_opt key json with
  | Some value -> value
  | None -> Alcotest.failf "missing string field %s" key

let persisted_record ~tool_name ~disposition ~duration_ms =
  `Assoc
    [ "tool_name", `String tool_name
    ; "disposition", `String disposition
    ; "duration_ms", `Float duration_ms
    ; "ts", `Float 1.0
    ]

let append_raw_current_day ~base_path line =
  let dir = Filename.concat base_path "data/tool-metrics" in
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let path = Filename.concat (Filename.concat dir month) day in
  Fs_compat.append_file path (line ^ "\n")

let write_old_record ~base_path json =
  let month_dir = Filename.concat base_path "data/tool-metrics/2020-01" in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_file
    (Filename.concat month_dir "01.jsonl")
    (Yojson.Safe.to_string json ^ "\n")

let test_enqueue_flush_current_records () =
  with_tmp_dir (fun base_path ->
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue (make_result ~name:"alpha" ~success:false ~duration_ms:5.0);
    P.enqueue
      (R.Deferred
         { R.tool_name = "alpha"
         ; data = `Null
         ; metadata = None
         ; duration_ms = 3.0
         });
    P.enqueue (make_result ~name:"beta" ~success:true ~duration_ms:20.0);
    P.flush_now ~base_path;
    let records = read_records ~base_path in
    Alcotest.(check int) "four records written" 4 (List.length records);
    Alcotest.(check (list string))
      "current dispositions only"
      [ "completed"; "failed"; "deferred"; "completed" ]
      (List.map (string_field "disposition") records);
    Alcotest.(check bool)
      "removed success-bit format is not emitted"
      true
      (List.for_all
         (fun json -> Safe_ops.json_bool_opt "success" json = None)
         records))

let test_reset_discards_queued_records () =
  with_tmp_dir (fun base_path ->
    P.enqueue (make_result ~name:"alpha" ~success:true ~duration_ms:1.0);
    P.reset_for_testing ();
    P.flush_now ~base_path;
    Alcotest.(check int)
      "reset leaves no persisted rows"
      0
      (List.length (read_records ~base_path)))

let test_enqueue_drops_when_queue_full () =
  with_tmp_dir (fun base_path ->
    for i = 1 to 4101 do
      P.enqueue
        (make_result
           ~name:(Printf.sprintf "tool-%04d" i)
           ~success:true
           ~duration_ms:1.0)
    done;
    P.flush_now ~base_path;
    Alcotest.(check int)
      "bounded queue persists only capacity"
      4096
      (List.length (read_records ~base_path)))

let test_enqueue_multidomain_drop_is_bounded () =
  with_tmp_dir (fun base_path ->
    let spawn producer =
      Domain.spawn (fun () ->
        for i = 1 to 1500 do
          P.enqueue
            (make_result
               ~name:(Printf.sprintf "domain-%d-tool-%04d" producer i)
               ~success:true
               ~duration_ms:1.0)
        done)
    in
    let domains = List.init 4 spawn in
    List.iter Domain.join domains;
    P.flush_now ~base_path;
    Alcotest.(check int)
      "multi-domain producers persist only capacity"
      4096
      (List.length (read_records ~base_path)))

let test_hydrate_replaces_metrics_and_skips_bad_rows () =
  with_tmp_dir (fun base_path ->
    Tool_metrics.clear ();
    Fun.protect
      ~finally:Tool_metrics.clear
      (fun () ->
        let store =
          Dated_jsonl.create
            ~base_dir:(Filename.concat base_path "data/tool-metrics")
            ()
        in
        Dated_jsonl.append store
          (persisted_record
             ~tool_name:"alpha"
             ~disposition:"completed"
             ~duration_ms:10.0);
        Dated_jsonl.append store
          (persisted_record
             ~tool_name:"alpha"
             ~disposition:"deferred"
             ~duration_ms:20.0);
        Dated_jsonl.append store
          (persisted_record
             ~tool_name:"beta"
             ~disposition:"failed"
             ~duration_ms:30.0);
        Dated_jsonl.append store
          (persisted_record
             ~tool_name:"unknown"
             ~disposition:"cancelled"
             ~duration_ms:40.0);
        Dated_jsonl.append store
          (persisted_record
             ~tool_name:"negative"
             ~disposition:"completed"
             ~duration_ms:(-1.0));
        Dated_jsonl.append store
          (`Assoc
             [ "tool_name", `String "missing-ts"
             ; "disposition", `String "completed"
             ; "duration_ms", `Float 1.0
             ]);
        append_raw_current_day ~base_path "not-json";
        write_old_record
          ~base_path
          (persisted_record
             ~tool_name:"expired"
             ~disposition:"completed"
             ~duration_ms:50.0);
        let report =
          match P.hydrate ~base_path ~retention_days:30 with
          | Ok report -> report
          | Error error ->
            Alcotest.failf
              "hydrate failed: %s"
              (Dated_jsonl.read_error_to_string error)
        in
        Alcotest.(check int) "three current rows loaded" 3 report.loaded_records;
        Alcotest.(check int) "one malformed JSON row skipped" 1 report.malformed_records;
        Alcotest.(check int) "three invalid rows skipped" 3 report.invalid_records;
        Alcotest.(check int) "old day file pruned" 1 report.pruned_files;
        Alcotest.(check bool) "expired row absent" true
          (Option.is_none (Tool_metrics.stats_for "expired"));
        let alpha = Option.get (Tool_metrics.stats_for "alpha") in
        Alcotest.(check int) "alpha calls restored" 2 alpha.call_count;
        Alcotest.(check int) "alpha completed restored" 1 alpha.success_count;
        Alcotest.(check int) "alpha deferred restored" 1 alpha.deferred_count;
        let beta = Option.get (Tool_metrics.stats_for "beta") in
        Alcotest.(check int) "beta failed restored" 1 beta.failure_count;
        let second =
          match P.hydrate ~base_path ~retention_days:30 with
          | Ok report -> report
          | Error error ->
            Alcotest.failf
              "second hydrate failed: %s"
              (Dated_jsonl.read_error_to_string error)
        in
        Alcotest.(check int) "second load still sees three rows" 3 second.loaded_records;
        Alcotest.(check int)
          "second hydration does not double count"
          2
          (Option.get (Tool_metrics.stats_for "alpha")).call_count))

let () =
  Alcotest.run
    "Tool_metrics_persist"
    [ ( "persistence"
      , [ eio_test "enqueue and flush current rows" test_enqueue_flush_current_records
        ; eio_test "reset discards queued records" test_reset_discards_queued_records
        ; eio_test
            "enqueue drops instead of blocking when queue is full"
            test_enqueue_drops_when_queue_full
        ; eio_test
            "enqueue drops safely from multiple domains"
            test_enqueue_multidomain_drop_is_bounded
        ; eio_test
            "startup hydration restores current rows once"
            test_hydrate_replaces_metrics_and_skips_bad_rows
        ] )
    ]
