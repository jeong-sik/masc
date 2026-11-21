module Log = Masc.Workspace_memory_log

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let with_temp_dir prefix f =
  let dir = temp_dir prefix in
  Fun.protect
    ~finally:(fun () -> try Fs_compat.remove_tree dir with _ -> ())
    (fun () -> f dir)

let make_change ~seq ~batch_id ~fact_id ~summary : Log.change_entry =
  { seq
  ; batch_id
  ; fact_id
  ; summary
  ; payload = `Assoc [ "fact_id", `String fact_id; "seq", `Int seq ]
  ; recorded_at = Printf.sprintf "2026-10-14T09:00:%02dZ" seq
  }

let test_codec_round_trip_and_errors () =
  let records : Log.log_record list =
    [ Log.Prepared
        { batch_id = "batch-1"
        ; author = "curator"
        ; started_at = "2026-10-14T09:00:00Z"
        ; expected_changes = 1
        }
    ; Log.Change
        (make_change
           ~seq:1
           ~batch_id:"batch-1"
           ~fact_id:"fact-1"
           ~summary:"Claim c1 created by writer")
    ; Log.Committed
        { batch_id = "batch-1"
        ; committed_at = "2026-10-14T09:00:02Z"
        ; final_seq = 1
        }
    ; Log.Aborted
        { batch_id = "batch-2"
        ; aborted_at = "2026-10-14T09:01:00Z"
        ; reason = "ledger_save_failed"
        }
    ]
  in
  List.iter
    (fun record ->
       let line = Log.record_to_json_line record in
       match Log.record_of_json_line line with
       | Ok decoded ->
         Alcotest.(check bool)
           "round-trip record equality"
           true
           (decoded = record)
       | Error err -> Alcotest.fail (Log.error_to_string err))
    records;
  (match Log.record_of_yojson (`Assoc [ "kind", `String "mystery" ]) with
   | Error (Log.Unknown_record_kind "mystery") -> ()
   | _ -> Alcotest.fail "expected Unknown_record_kind");
  (match Log.record_of_yojson (`Assoc [ "kind", `String "committed" ]) with
   | Error (Log.Missing_field "batch_id") -> ()
   | _ -> Alcotest.fail "expected Missing_field batch_id");
  (match
     Log.record_of_yojson
       (`Assoc
          [ "kind", `String "prepared"
          ; "batch_id", `String "b1"
          ; "author", `String "curator"
          ; "started_at", `String "2026-10-14T09:00:00Z"
          ; "expected_changes", `Int (-1)
          ])
   with
   | Error (Log.Invalid_field { field = "expected_changes"; _ }) -> ()
   | _ -> Alcotest.fail "expected Invalid_field expected_changes");
  match Log.record_of_json_line "{not valid json" with
  | Error (Log.Malformed_json _) -> ()
  | _ -> Alcotest.fail "expected Malformed_json"

let test_batch_visibility_and_isolation () =
  let c1 =
    make_change ~seq:1 ~batch_id:"b-commit-1" ~fact_id:"f1" ~summary:"line 1"
  in
  let c2 =
    make_change ~seq:2 ~batch_id:"b-commit-1" ~fact_id:"f2" ~summary:"line 2"
  in
  let c_aborted =
    make_change
      ~seq:3
      ~batch_id:"b-aborted"
      ~fact_id:"f3"
      ~summary:"aborted line"
  in
  let c_commit_2 =
    make_change ~seq:3 ~batch_id:"b-commit-2" ~fact_id:"f4" ~summary:"line 3"
  in
  let c_dangling =
    make_change
      ~seq:4
      ~batch_id:"b-incomplete"
      ~fact_id:"f5"
      ~summary:"dangling line"
  in
  let records : Log.log_record list =
    [ Log.Prepared
        { batch_id = "b-commit-1"
        ; author = "curator"
        ; started_at = "2026-10-14T09:00:00Z"
        ; expected_changes = 2
        }
    ; Log.Change c1
    ; Log.Change c2
    ; Log.Committed
        { batch_id = "b-commit-1"
        ; committed_at = "2026-10-14T09:00:05Z"
        ; final_seq = 2
        }
    ; Log.Prepared
        { batch_id = "b-aborted"
        ; author = "curator"
        ; started_at = "2026-10-14T09:01:00Z"
        ; expected_changes = 1
        }
    ; Log.Change c_aborted
    ; Log.Aborted
        { batch_id = "b-aborted"
        ; aborted_at = "2026-10-14T09:01:02Z"
        ; reason = "transient_failure"
        }
    ; Log.Prepared
        { batch_id = "b-commit-2"
        ; author = "curator"
        ; started_at = "2026-10-14T09:02:00Z"
        ; expected_changes = 1
        }
    ; Log.Change c_commit_2
    ; Log.Committed
        { batch_id = "b-commit-2"
        ; committed_at = "2026-10-14T09:02:05Z"
        ; final_seq = 3
        }
    ; Log.Prepared
        { batch_id = "b-incomplete"
        ; author = "curator"
        ; started_at = "2026-10-14T09:03:00Z"
        ; expected_changes = 2
        }
    ; Log.Change c_dangling
    ]
  in
  let report = Log.recover records in
  Alcotest.(check (list int))
    "only committed changes are visible"
    [ 1; 2; 3 ]
    (List.map (fun (c : Log.change_entry) -> c.seq) report.committed_changes);
  Alcotest.(check (list string))
    "committed summaries match b-commit-1 and b-commit-2 only"
    [ "line 1"; "line 2"; "line 3" ]
    (List.map
       (fun (c : Log.change_entry) -> c.summary)
       report.committed_changes);
  Alcotest.(check int) "last_committed_seq is 3" 3 report.last_committed_seq;
  Alcotest.(check (list string))
    "incomplete batch detected at EOF"
    [ "b-incomplete" ]
    (List.map
       (fun (h : Log.batch_header) -> h.batch_id)
       report.incomplete_batches);
  Alcotest.(check (list string))
    "aborted batch recorded"
    [ "b-aborted" ]
    report.aborted_batches

let test_file_crash_recovery_aborts_incomplete () =
  with_temp_dir "workspace-memory-log-test" (fun dir ->
    let path = Log.log_path ~base_path:dir in
    let header_ok : Log.batch_header =
      { batch_id = "batch-ok"
      ; author = "curator"
      ; started_at = "2026-10-14T09:00:00Z"
      ; expected_changes = 2
      }
    in
    let changes_ok =
      [ make_change ~seq:1 ~batch_id:"batch-ok" ~fact_id:"f1" ~summary:"s1"
      ; make_change ~seq:2 ~batch_id:"batch-ok" ~fact_id:"f2" ~summary:"s2"
      ]
    in
    (match
       Log.append_batch
         ~path
         ~header:header_ok
         ~changes:changes_ok
         ~committed_at:"2026-10-14T09:00:10Z"
     with
     | Ok final_seq -> Alcotest.(check int) "final_seq is 2" 2 final_seq
     | Error err -> Alcotest.fail (Log.error_to_string err));
    (* Simulate writer crash after Prepared + 1 complete Change + a cut-off newline-less line (B2) *)
    let header_crash : Log.batch_header =
      { batch_id = "batch-crash"
      ; author = "curator"
      ; started_at = "2026-10-14T09:05:00Z"
      ; expected_changes = 2
      }
    in
    let dangling_change =
      make_change
        ~seq:3
        ~batch_id:"batch-crash"
        ~fact_id:"f3"
        ~summary:"uncommitted"
    in
    (match Log.append_record ~path (Log.Prepared header_crash) with
     | Ok () -> ()
     | Error err -> Alcotest.fail (Log.error_to_string err));
    (match Log.append_record ~path (Log.Change dangling_change) with
     | Ok () -> ()
     | Error err -> Alcotest.fail (Log.error_to_string err));
    (* Append a truncated newline-less JSON fragment simulating crash mid-write *)
    Fs_compat.append_file path "{\"kind\":\"change\",\"seq\":4,\"batch_id\":\"batch-crash";
    let before_abort =
      match Log.recover_file ~path with
      | Ok r -> r
      | Error err -> Alcotest.fail (Log.error_to_string err)
    in
    Alcotest.(check int)
      "2 committed changes before abort"
      2
      (List.length before_abort.committed_changes);
    Alcotest.(check (list string))
      "batch-crash is incomplete before abort despite cut-off tail"
      [ "batch-crash" ]
      (List.map
         (fun (h : Log.batch_header) -> h.batch_id)
         before_abort.incomplete_batches);
    let after_abort =
      match
        Log.abort_incomplete_batches
          ~path
          ~aborted_at:"2026-10-14T09:06:00Z"
          ~reason:"crash_recovery"
          before_abort
      with
      | Ok r -> r
      | Error err -> Alcotest.fail (Log.error_to_string err)
    in
    Alcotest.(check int)
      "incomplete_batches cleared in returned report"
      0
      (List.length after_abort.incomplete_batches);
    Alcotest.(check (list string))
      "aborted_batches contains batch-crash"
      [ "batch-crash" ]
      after_abort.aborted_batches;
    (* Reload from disk to verify the cut-off tail was truncated and Aborted record was durably appended *)
    let reloaded =
      match Log.recover_file ~path with
      | Ok r -> r
      | Error err -> Alcotest.fail (Log.error_to_string err)
    in
    Alcotest.(check int)
      "reloaded log has 0 incomplete batches"
      0
      (List.length reloaded.incomplete_batches);
    Alcotest.(check (list string))
      "reloaded log records batch-crash as aborted"
      [ "batch-crash" ]
      reloaded.aborted_batches;
    Alcotest.(check int)
      "reloaded log keeps last_committed_seq = 2"
      2
      reloaded.last_committed_seq;
    (* B1: Appending a batch with stale seq (<= last_committed_seq = 2) or duplicate batch_id is rejected *)
    let stale_header : Log.batch_header =
      { batch_id = "batch-stale"
      ; author = "curator"
      ; started_at = "2026-10-14T09:07:00Z"
      ; expected_changes = 1
      }
    in
    let stale_change =
      make_change ~seq:2 ~batch_id:"batch-stale" ~fact_id:"f-stale" ~summary:"stale"
    in
    (match
       Log.append_batch
         ~path
         ~header:stale_header
         ~changes:[ stale_change ]
         ~committed_at:"2026-10-14T09:07:01Z"
     with
     | Error (Log.Invalid_batch _) -> ()
     | Ok seq ->
       Alcotest.fail (Printf.sprintf "expected stale seq to fail, got Ok %d" seq)
     | Error err -> Alcotest.fail (Log.error_to_string err))
  )

let () =
  Alcotest.run
    "Workspace_memory_log"
    [ ( "log"
      , [ Alcotest.test_case
            "JSONL codec round-trip and strict error variants"
            `Quick
            test_codec_round_trip_and_errors
        ; Alcotest.test_case
            "committed batch visibility vs uncommitted and aborted isolation"
            `Quick
            test_batch_visibility_and_isolation
        ; Alcotest.test_case
            "file crash recovery aborts incomplete batches"
            `Quick
            test_file_crash_recovery_aborts_incomplete
        ] )
    ]
