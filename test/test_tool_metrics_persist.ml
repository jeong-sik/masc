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

let eio_clock_test name fn =
  Alcotest.test_case name `Quick (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    fn (Eio.Stdenv.clock env))

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

let pending_records ~base_path =
  let dir = Filename.concat base_path "data/tool-metrics-pending" in
  if Sys.file_exists dir then Fs_compat.read_dir dir else []

let loss_marker_path ~base_path = function
  | `Bulk_data -> Filename.concat base_path "data/tool-metrics-loss-marker.json"
  | `Runtime_state_fallback ->
    Filename.concat base_path ".masc/tool-metrics-loss-marker.json"

let write_loss_marker ~source ~base_path ~observed_at_unix =
  let path = loss_marker_path ~base_path source in
  Fs_compat.mkdir_p (Filename.dirname path);
  match
    Fs_compat.save_file_atomic path
      (Yojson.Safe.to_string
         (`Assoc
            [ "schema", `String "masc.tool_metrics.loss_marker.v1"
            ; "reason", `String "queue_full"
            ; "observed_at_unix", `Float observed_at_unix
            ; "runtime_instance_id", `String "test-runtime"
            ])
       ^ "\n")
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "loss marker write failed: %s" error

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
    P.enqueue ~base_path (make_result ~name:"alpha" ~success:true ~duration_ms:10.0);
    P.enqueue ~base_path (make_result ~name:"alpha" ~success:false ~duration_ms:5.0);
    P.enqueue ~base_path
      (R.Deferred
         { R.tool_name = "alpha"
         ; data = `Null
         ; metadata = None
         ; duration_ms = 3.0
         });
    P.enqueue ~base_path (make_result ~name:"beta" ~success:true ~duration_ms:20.0);
    Alcotest.(check int)
      "four durable pending files published before flush"
      4
      (List.length (pending_records ~base_path));
    P.flush_now ~base_path;
    let records = read_records ~base_path in
    Alcotest.(check int) "four records written" 4 (List.length records);
    Alcotest.(check (list string))
      "current dispositions only"
      [ "completed"; "failed"; "deferred"; "completed" ]
      (List.map (string_field "disposition") records);
    Alcotest.(check bool)
      "every current row carries a durable record id"
      true
      (List.for_all
         (fun json ->
           String.length (string_field "record_id" json) = 36)
         records);
    Alcotest.(check bool)
      "removed success-bit format is not emitted"
      true
      (List.for_all
         (fun json -> Safe_ops.json_bool_opt "success" json = None)
         records);
    let snapshot = P.persistence_snapshot () in
    Alcotest.(check int) "queue drained" 0 snapshot.queue_depth;
    Alcotest.(check int)
      "pending files removed after final append"
      0
      (List.length (pending_records ~base_path));
    Alcotest.(check int) "four records flushed" 4 snapshot.flushed_records;
    Alcotest.(check int) "one flush batch" 1 snapshot.flush_batches;
    Alcotest.(check int) "no append failures" 0 snapshot.append_failed_records;
    Alcotest.(check (option string))
      "manual trigger visible"
      (Some "manual")
      snapshot.last_flush_trigger;
    Alcotest.(check (option int))
      "last flush row count visible"
      (Some 4)
      snapshot.last_flush_rows)

let test_reset_discards_queued_records () =
  with_tmp_dir (fun base_path ->
    P.enqueue ~base_path (make_result ~name:"alpha" ~success:true ~duration_ms:1.0);
    P.reset_for_testing ();
    P.flush_now ~base_path;
    Alcotest.(check int)
      "reset leaves no persisted rows"
      0
      (List.length (read_records ~base_path));
    Alcotest.(check int)
      "reset only discards memory and preserves durable pending row"
      1
      (List.length (pending_records ~base_path)))

let test_enqueue_drops_when_queue_full () =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content -> Ok ());
    for i = 1 to 4101 do
      P.enqueue ~base_path
        (make_result
           ~name:(Printf.sprintf "tool-%04d" i)
           ~success:true
           ~duration_ms:1.0)
    done;
    let full_snapshot = P.persistence_snapshot () in
    Alcotest.(check int) "queue capacity visible" 4096 full_snapshot.queue_capacity;
    Alcotest.(check int)
      "high watermark visible"
      2048
      full_snapshot.queue_high_watermark;
    Alcotest.(check int) "queue depth bounded" 4096 full_snapshot.queue_depth;
    Alcotest.(check int)
      "five queue-full drops visible"
      5
      full_snapshot.queue_full_dropped_records;
    Alcotest.(check int)
      "loss marker publication succeeded"
      0
      full_snapshot.loss_marker_write_failed_records;
    Alcotest.(check bool)
      "aggregate is known incomplete"
      true
      ((P.aggregate_integrity_snapshot ()).status = `Known_incomplete);
    Alcotest.(check bool)
      "bulk data marker is selected"
      true
      ((P.aggregate_integrity_snapshot ()).loss_marker_source = Some `Bulk_data);
    P.flush_now ~base_path;
    Alcotest.(check int)
      "bounded queue persists only capacity"
      4096
      (List.length (read_records ~base_path));
    let drained_snapshot = P.persistence_snapshot () in
    Alcotest.(check int) "full queue drained" 0 drained_snapshot.queue_depth;
    Alcotest.(check int)
      "queue-full drops remain visible after drain"
      5
      drained_snapshot.queue_full_dropped_records;
    P.reset_for_testing ();
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check int)
      "loss markers are current format"
      0
      (List.length report.invalid_loss_marker_sources);
    Alcotest.(check bool)
      "durable loss marker survives memory reset"
      true
      ((P.aggregate_integrity_snapshot ()).status = `Known_incomplete))

let test_enqueue_multidomain_drop_is_bounded () =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content -> Ok ());
    P.For_testing.set_loss_marker_write_guard (fun _path _content -> Ok ());
    let spawn producer =
      Domain.spawn (fun () ->
        for i = 1 to 1500 do
          P.enqueue ~base_path
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

let test_expired_loss_marker_is_not_current_evidence () =
  with_tmp_dir (fun base_path ->
    write_loss_marker ~source:`Bulk_data ~base_path ~observed_at_unix:1.0;
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check int)
      "expired marker is valid"
      0
      (List.length report.invalid_loss_marker_sources);
    let integrity = P.aggregate_integrity_snapshot () in
    Alcotest.(check bool) "expired marker does not stay current" true
      (integrity.status = `Unknown);
    Alcotest.(check (option int))
      "retention window visible"
      (Some 30)
      integrity.retention_days)

let test_invalid_loss_marker_is_explicit () =
  with_tmp_dir (fun base_path ->
    let path = Filename.concat base_path "data/tool-metrics-loss-marker.json" in
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file path "not-json";
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check bool)
      "invalid marker source reported"
      true
      (report.invalid_loss_marker_sources = [ `Bulk_data ]);
    Alcotest.(check bool) "invalid marker stays distinct from absence" true
      ((P.aggregate_integrity_snapshot ()).status = `Invalid_marker))

let test_unreadable_loss_marker_does_not_block_hydration () =
  with_tmp_dir (fun base_path ->
    let marker_path =
      Filename.concat base_path "data/tool-metrics-loss-marker.json"
    in
    Fs_compat.mkdir_p marker_path;
    let store =
      Dated_jsonl.create
        ~base_dir:(Filename.concat base_path "data/tool-metrics")
        ()
    in
    Dated_jsonl.append store
      (persisted_record
         ~tool_name:"survives-marker-read-failure"
         ~disposition:"completed"
         ~duration_ms:1.0);
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check bool)
      "unreadable marker source reported"
      true
      (report.invalid_loss_marker_sources = [ `Bulk_data ]);
    Alcotest.(check int) "metric hydration continues" 1 report.loaded_records;
    Alcotest.(check bool) "read failure projects invalid marker" true
      ((P.aggregate_integrity_snapshot ()).status = `Invalid_marker))

let test_valid_fallback_keeps_invalid_primary_explicit () =
  with_tmp_dir (fun base_path ->
    let primary_path = loss_marker_path ~base_path `Bulk_data in
    Fs_compat.mkdir_p (Filename.dirname primary_path);
    Fs_compat.save_file primary_path "not-json";
    write_loss_marker
      ~source:`Runtime_state_fallback
      ~base_path
      ~observed_at_unix:(Time_compat.now ());
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check bool)
      "invalid primary remains visible"
      true
      (report.invalid_loss_marker_sources = [ `Bulk_data ]);
    let integrity = P.aggregate_integrity_snapshot () in
    Alcotest.(check bool)
      "valid fallback retains incomplete status"
      true
      (integrity.status = `Known_incomplete);
    Alcotest.(check bool)
      "fallback is selected"
      true
      (integrity.loss_marker_source = Some `Runtime_state_fallback);
    Alcotest.(check bool)
      "invalid source is projected beside valid fallback"
      true
      (integrity.invalid_loss_marker_sources = [ `Bulk_data ]))

let test_loss_marker_write_failure_is_observable () =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content -> Ok ());
    P.For_testing.set_loss_marker_write_guard (fun _path _content ->
      Error "forced loss marker failure");
    P.For_testing.set_loss_marker_fallback_write_guard (fun _path _content ->
      Error "forced loss marker fallback failure");
    for i = 1 to 4097 do
      P.enqueue ~base_path
        (make_result
           ~name:(Printf.sprintf "loss-marker-failure-%04d" i)
           ~success:true
           ~duration_ms:1.0)
    done;
    let snapshot = P.persistence_snapshot () in
    Alcotest.(check int) "one queue-full row" 1 snapshot.queue_full_dropped_records;
    Alcotest.(check int)
      "marker failure counted"
      1
      snapshot.loss_marker_write_failed_records;
    Alcotest.(check int)
      "fallback marker failure counted"
      1
      snapshot.loss_marker_fallback_write_failed_records;
    Alcotest.(check bool)
      "marker error visible"
      true
      (Option.is_some snapshot.last_loss_marker_error);
    Alcotest.(check bool)
      "fallback marker error visible"
      true
      (Option.is_some snapshot.last_loss_marker_fallback_error);
    Alcotest.(check bool)
      "failed marker does not fabricate integrity evidence"
      true
      ((P.aggregate_integrity_snapshot ()).status = `Unknown))

let test_loss_marker_fallback_survives_bulk_root_failure () =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content -> Ok ());
    P.For_testing.set_loss_marker_write_guard (fun _path _content ->
      Error "forced bulk data root failure");
    for i = 1 to 4097 do
      P.enqueue ~base_path
        (make_result
           ~name:(Printf.sprintf "loss-marker-fallback-%04d" i)
           ~success:true
           ~duration_ms:1.0)
    done;
    let snapshot = P.persistence_snapshot () in
    Alcotest.(check int)
      "primary marker failure counted"
      1
      snapshot.loss_marker_write_failed_records;
    Alcotest.(check int)
      "fallback marker write succeeds"
      0
      snapshot.loss_marker_fallback_write_failed_records;
    let before_restart = P.aggregate_integrity_snapshot () in
    Alcotest.(check bool)
      "fallback establishes incomplete status"
      true
      (before_restart.status = `Known_incomplete);
    Alcotest.(check bool)
      "fallback source is explicit"
      true
      (before_restart.loss_marker_source = Some `Runtime_state_fallback);
    Alcotest.(check bool)
      "fallback marker exists outside bulk data root"
      true
      (Sys.file_exists
         (loss_marker_path ~base_path `Runtime_state_fallback));
    P.reset_for_testing ();
    let report =
      match P.hydrate ~base_path ~retention_days:30 with
      | Ok report -> report
      | Error error ->
        Alcotest.failf
          "hydrate failed: %s"
          (Dated_jsonl.read_error_to_string error)
    in
    Alcotest.(check int)
      "both marker files remain readable"
      0
      (List.length report.invalid_loss_marker_sources);
    let after_restart = P.aggregate_integrity_snapshot () in
    Alcotest.(check bool)
      "fallback survives memory reset"
      true
      (after_restart.status = `Known_incomplete);
    Alcotest.(check bool)
      "hydration retains fallback source"
      true
      (after_restart.loss_marker_source = Some `Runtime_state_fallback))

let test_append_failure_and_recovery_are_observable () =
  with_tmp_dir (fun base_path ->
    let run_append f = f () in
    Fun.protect
      ~finally:(fun () -> Dated_jsonl.set_append_guard run_append)
      (fun () ->
        Dated_jsonl.set_append_guard (fun _ -> raise (Failure "forced append failure"));
        P.enqueue ~base_path
          (make_result ~name:"failed-write" ~success:true ~duration_ms:1.0);
        P.flush_now ~base_path;
        let failed = P.persistence_snapshot () in
        Alcotest.(check int) "failed row not counted as flushed" 0 failed.flushed_records;
        Alcotest.(check int) "failed row remains pending" 1 failed.queue_depth;
        Alcotest.(check int) "failed row enters retry queue" 1 failed.retry_queue_depth;
        Alcotest.(check int) "no record remains in flight" 0 failed.in_flight_records;
        Alcotest.(check int) "append failure counted" 1 failed.append_failed_records;
        Alcotest.(check int)
          "failed row remains spool-backed"
          1
          failed.spool_backed_queue_depth;
        Alcotest.(check int)
          "pending file remains until final append"
          1
          (List.length (pending_records ~base_path));
        Alcotest.(check (option int))
          "failed row visible on last batch"
          (Some 1)
          failed.last_flush_failed_rows;
        Alcotest.(check bool)
          "append error visible"
          true
          (Option.is_some failed.last_append_error);
        Dated_jsonl.set_append_guard run_append;
        P.flush_now ~base_path;
        let recovered = P.persistence_snapshot () in
        Alcotest.(check int) "retained row flushed after recovery" 1 recovered.flushed_records;
        Alcotest.(check int) "retry queue drained" 0 recovered.retry_queue_depth;
        Alcotest.(check int) "no pending rows after recovery" 0 recovered.queue_depth;
        Alcotest.(check int)
          "recovery removes pending file"
          0
          (List.length (pending_records ~base_path));
        Alcotest.(check int)
          "historical append failure retained"
          1
          recovered.append_failed_records;
        Alcotest.(check (option int))
          "latest batch recovered"
          (Some 0)
          recovered.last_flush_failed_rows;
        Alcotest.(check bool)
          "last append error clears after recovery"
          true
          (Option.is_none recovered.last_append_error);
        Alcotest.(check (list string))
          "the originally failed row is persisted"
          [ "failed-write" ]
          (read_records ~base_path |> List.map (string_field "tool_name"))))

let test_pending_spool_recovers_after_memory_loss () =
  with_tmp_dir (fun base_path ->
    Tool_metrics.clear ();
    Fun.protect
      ~finally:Tool_metrics.clear
      (fun () ->
        P.enqueue ~base_path
          (make_result ~name:"crash-window" ~success:true ~duration_ms:7.0);
        Alcotest.(check int)
          "accepted row is durable before final flush"
          1
          (List.length (pending_records ~base_path));
        P.reset_for_testing ();
        let report =
          match P.hydrate ~base_path ~retention_days:30 with
          | Ok report -> report
          | Error error ->
            Alcotest.failf
              "hydrate failed: %s"
              (Dated_jsonl.read_error_to_string error)
        in
        Alcotest.(check int) "no final rows existed" 0 report.loaded_records;
        Alcotest.(check int)
          "pending row recovered"
          1
          report.recovered_pending_records;
        Alcotest.(check int)
          "recovered row restored in aggregate"
          1
          (Option.get (Tool_metrics.stats_for "crash-window")).call_count;
        Alcotest.(check int)
          "recovered row re-enters retry queue"
          1
          (P.persistence_snapshot ()).retry_queue_depth;
        P.flush_now ~base_path;
        Alcotest.(check int)
          "recovered row reaches final JSONL"
          1
          (List.length (read_records ~base_path));
        Alcotest.(check int)
          "pending file removed after recovery flush"
          0
          (List.length (pending_records ~base_path))))

let test_pending_spool_deduplicates_final_row () =
  with_tmp_dir (fun base_path ->
    Tool_metrics.clear ();
    Fun.protect
      ~finally:Tool_metrics.clear
      (fun () ->
        P.enqueue ~base_path
          (make_result ~name:"dedup-window" ~success:true ~duration_ms:9.0);
        let pending_name = List.hd (pending_records ~base_path) in
        let pending_path =
          Filename.concat
            (Filename.concat base_path "data/tool-metrics-pending")
            pending_name
        in
        let json = Yojson.Safe.from_string (Fs_compat.load_file pending_path) in
        let store =
          Dated_jsonl.create
            ~base_dir:(Filename.concat base_path "data/tool-metrics")
            ()
        in
        Dated_jsonl.append store json;
        P.reset_for_testing ();
        let report =
          match P.hydrate ~base_path ~retention_days:30 with
          | Ok report -> report
          | Error error ->
            Alcotest.failf
              "hydrate failed: %s"
              (Dated_jsonl.read_error_to_string error)
        in
        Alcotest.(check int) "final row loaded once" 1 report.loaded_records;
        Alcotest.(check int)
          "stale pending row deduplicated"
          1
          report.deduplicated_pending_records;
        Alcotest.(check int)
          "deduplicated row not queued again"
          0
          (P.persistence_snapshot ()).queue_depth;
        Alcotest.(check int)
          "stale pending file removed"
          0
          (List.length (pending_records ~base_path));
        Alcotest.(check int)
          "aggregate contains one call"
          1
          (Option.get (Tool_metrics.stats_for "dedup-window")).call_count))

let test_spool_failure_falls_back_to_observable_memory_queue () =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content ->
      Error "forced spool failure");
    P.enqueue ~base_path
      (make_result ~name:"spool-failed" ~success:true ~duration_ms:1.0);
    let snapshot = P.persistence_snapshot () in
    Alcotest.(check int) "row remains queued" 1 snapshot.queue_depth;
    Alcotest.(check int) "row is not spool-backed" 0 snapshot.spool_backed_queue_depth;
    Alcotest.(check int) "spool failure counted" 1 snapshot.spool_write_failed_records;
    Alcotest.(check bool)
      "spool error visible"
      true
      (Option.is_some snapshot.last_spool_error);
    P.flush_now ~base_path;
    Alcotest.(check int)
      "memory fallback still reaches final JSONL"
      1
      (List.length (read_records ~base_path)))

let test_high_watermark_wakes_flush_waiter clock =
  with_tmp_dir (fun base_path ->
    P.For_testing.set_pending_write_guard (fun _path _content -> Ok ());
    Eio.Switch.run (fun sw ->
      let observed, resolve_observed = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        let trigger =
          P.For_testing.await_flush_trigger ~clock ~interval_s:10.0
        in
        Eio.Promise.resolve resolve_observed trigger);
      Eio.Fiber.yield ();
      let producer =
        Domain.spawn (fun () ->
          for i = 1 to P.For_testing.high_watermark do
            P.enqueue ~base_path
              (make_result
                 ~name:(Printf.sprintf "wake-tool-%04d" i)
                 ~success:true
                 ~duration_ms:1.0)
          done)
      in
      Domain.join producer;
      Alcotest.(check int)
        "high-watermark records remain queued for the writer"
        P.For_testing.high_watermark
        (P.For_testing.queued_record_count ());
      let trigger =
        Eio.Time.with_timeout_exn clock 1.0 (fun () -> Eio.Promise.await observed)
      in
      Alcotest.(check bool)
        "waiter wakes before the ten-second timer"
        true
        (trigger = `High_watermark)))

let test_timer_wakes_below_high_watermark clock =
  with_tmp_dir (fun _base_path ->
    let trigger =
      P.For_testing.await_flush_trigger ~clock ~interval_s:0.01
    in
    Alcotest.(check bool)
      "timer remains the maximum flush delay"
      true
      (trigger = `Timer))

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
        Alcotest.(check int)
          "no pending rows recovered"
          0
          report.recovered_pending_records;
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
            "append failure and recovery remain observable"
            test_append_failure_and_recovery_are_observable
        ; eio_test
            "pending spool recovers after in-memory state is lost"
            test_pending_spool_recovers_after_memory_loss
        ; eio_test
            "startup deduplicates final rows with stale pending files"
            test_pending_spool_deduplicates_final_row
        ; eio_test
            "spool failures stay observable with memory fallback"
            test_spool_failure_falls_back_to_observable_memory_queue
        ; eio_test
            "expired loss markers are not current evidence"
            test_expired_loss_marker_is_not_current_evidence
        ; eio_test
            "invalid loss markers remain explicit"
            test_invalid_loss_marker_is_explicit
        ; eio_test
            "unreadable loss markers do not block metric hydration"
            test_unreadable_loss_marker_does_not_block_hydration
        ; eio_test
            "valid fallback keeps an invalid primary marker explicit"
            test_valid_fallback_keeps_invalid_primary_explicit
        ; eio_test
            "loss marker write failures stay observable"
            test_loss_marker_write_failure_is_observable
        ; eio_test
            "runtime-state loss marker fallback survives bulk root failure"
            test_loss_marker_fallback_survives_bulk_root_failure
        ; eio_clock_test
            "cross-domain high watermark wakes the flush waiter"
            test_high_watermark_wakes_flush_waiter
        ; eio_clock_test
            "timer wakes below the high watermark"
            test_timer_wakes_below_high_watermark
        ; eio_test
            "startup hydration restores current rows once"
            test_hydrate_replaces_metrics_and_skips_bad_rows
        ] )
    ]
