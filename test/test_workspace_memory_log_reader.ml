module Log = Masc.Workspace_memory_log
module Reader = Masc.Workspace_memory_reader

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

let unwrap_plan = function
  | Ok pair -> pair
  | Error err -> Alcotest.fail (Reader.error_to_string err)

let test_reader_cursor_progression_and_sticky_retry () =
  let committed_initial =
    [ make_change ~seq:1 ~batch_id:"b1" ~fact_id:"f1" ~summary:"claim 1"
    ; make_change ~seq:2 ~batch_id:"b1" ~fact_id:"f2" ~summary:"claim 2"
    ]
  in
  let s0 = Reader.init ~keeper:"keeper-alpha" () in
  let s1, delivered1 =
    unwrap_plan (Reader.plan_delivery s0 ~committed:committed_initial ())
  in
  Alcotest.(check (list int))
    "initial plan delivers [1; 2]"
    [ 1; 2 ]
    (List.map (fun (c : Log.change_entry) -> c.seq) delivered1);
  let pending1 =
    match s1.pending with
    | Some p -> p
    | None -> Alcotest.fail "expected pending delivery"
  in
  Alcotest.(check int) "from_seq = 1" 1 pending1.from_seq;
  Alcotest.(check int) "to_seq = 2" 2 pending1.to_seq;
  Alcotest.(check int) "entry_count = 2" 2 pending1.entry_count;
  (* Transient failure keeps acknowledged_seq = 0 and pending sticky *)
  let s_failed =
    match
      Reader.apply_turn_outcome
        s1
        ~committed:committed_initial
        Reader.Turn_failed_transient
    with
    | Ok s -> s
    | Error err -> Alcotest.fail (Reader.error_to_string err)
  in
  Alcotest.(check int)
    "acknowledged_seq remains 0 after transient failure"
    0
    s_failed.acknowledged_seq;
  (* Even when new committed entries [3; 4] arrive, retry delivers the exact sticky pending [1; 2] *)
  let committed_extended =
    committed_initial
    @ [ make_change ~seq:3 ~batch_id:"b2" ~fact_id:"f3" ~summary:"claim 3"
      ; make_change ~seq:4 ~batch_id:"b2" ~fact_id:"f4" ~summary:"claim 4"
      ]
  in
  let s_retry, delivered_retry =
    unwrap_plan (Reader.plan_delivery s_failed ~committed:committed_extended ())
  in
  Alcotest.(check (list int))
    "retry re-delivers exact pending slice [1; 2]"
    [ 1; 2 ]
    (List.map (fun (c : Log.change_entry) -> c.seq) delivered_retry);
  let pending_retry =
    match s_retry.pending with
    | Some p -> p
    | None -> Alcotest.fail "expected pending on retry"
  in
  Alcotest.(check string)
    "pending digest_sha256 is identical across retry"
    pending1.digest_sha256
    pending_retry.digest_sha256;
  (* B4: If committed entries are tampered with, plan_delivery returns Error Digest_mismatch, and recover_corrupted_pending recovers *)
  let committed_tampered =
    [ make_change ~seq:1 ~batch_id:"b1" ~fact_id:"f1" ~summary:"tampered!"
    ; make_change ~seq:2 ~batch_id:"b1" ~fact_id:"f2" ~summary:"claim 2"
    ]
  in
  (match Reader.plan_delivery s_retry ~committed:committed_tampered () with
   | Error (Reader.Digest_mismatch _) -> ()
   | Ok _ -> Alcotest.fail "expected Digest_mismatch on tampered slice"
   | Error err -> Alcotest.fail (Reader.error_to_string err));
  (match Reader.recover_corrupted_pending s_retry ~committed:committed_initial () with
   | Ok (s_rec, slice_rec) ->
     Alcotest.(check int) "recovered state keeps acknowledged_seq = 0" 0 s_rec.acknowledged_seq;
     Alcotest.(check int) "recovered slice has 2 entries" 2 (List.length slice_rec)
   | Error err -> Alcotest.fail (Reader.error_to_string err));
  (* Turn succeeds -> acknowledged_seq advances to 2 and pending clears *)
  let s_ack =
    match
      Reader.apply_turn_outcome
        s_retry
        ~committed:committed_extended
        Reader.Turn_succeeded
    with
    | Ok s -> s
    | Error err -> Alcotest.fail (Reader.error_to_string err)
  in
  Alcotest.(check int)
    "acknowledged_seq advances to 2"
    2
    s_ack.acknowledged_seq;
  Alcotest.(check bool)
    "pending cleared after success"
    true
    (Option.is_none s_ack.pending);
  (* Next turn plans [3; 4] *)
  let s_next, delivered_next =
    unwrap_plan (Reader.plan_delivery s_ack ~committed:committed_extended ())
  in
  Alcotest.(check (list int))
    "next delivery plans [3; 4]"
    [ 3; 4 ]
    (List.map (fun (c : Log.change_entry) -> c.seq) delivered_next);
  match s_next.pending with
  | Some p ->
    Alcotest.(check int) "next from_seq = 3" 3 p.from_seq;
    Alcotest.(check int) "next to_seq = 4" 4 p.to_seq
  | None -> Alcotest.fail "expected pending for [3; 4]"

let test_context_overflow_bisection_and_persistence () =
  with_temp_dir "workspace-memory-reader-test" (fun dir ->
    let committed =
      [ make_change ~seq:1 ~batch_id:"b1" ~fact_id:"f1" ~summary:"c1"
      ; make_change ~seq:2 ~batch_id:"b1" ~fact_id:"f2" ~summary:"c2"
      ; make_change ~seq:3 ~batch_id:"b1" ~fact_id:"f3" ~summary:"c3"
      ; make_change ~seq:4 ~batch_id:"b1" ~fact_id:"f4" ~summary:"c4"
      ]
    in
    let s0 = Reader.init ~keeper:"keeper-beta" () in
    let s4, slice4 = unwrap_plan (Reader.plan_delivery s0 ~committed ()) in
    Alcotest.(check int) "initial slice has 4 entries" 4 (List.length slice4);
    (* 1st Context_overflow: 4 -> 2 *)
    let s2 =
      match
        Reader.apply_turn_outcome s4 ~committed Reader.Context_overflow
      with
      | Ok s -> s
      | Error err -> Alcotest.fail (Reader.error_to_string err)
    in
    (match s2.pending with
     | Some p ->
       Alcotest.(check int) "bisected entry_count = 2" 2 p.entry_count;
       Alcotest.(check int) "bisected from_seq = 1" 1 p.from_seq;
       Alcotest.(check int) "bisected to_seq = 2" 2 p.to_seq;
       Alcotest.(check string)
         "digest matches first 2 entries"
         (Reader.compute_digest (List.filter (fun (e : Log.change_entry) -> e.seq <= 2) committed))
         p.digest_sha256
     | None -> Alcotest.fail "expected pending after 1st overflow");
    (* 2nd Context_overflow: 2 -> 1 *)
    let s1 =
      match
        Reader.apply_turn_outcome s2 ~committed Reader.Context_overflow
      with
      | Ok s -> s
      | Error err -> Alcotest.fail (Reader.error_to_string err)
    in
    (match s1.pending with
     | Some p ->
       Alcotest.(check int) "bisected entry_count = 1" 1 p.entry_count;
       Alcotest.(check int) "bisected from_seq = 1" 1 p.from_seq;
       Alcotest.(check int) "bisected to_seq = 1" 1 p.to_seq;
       Alcotest.(check bool) "mode is Full_entries" true (p.mode = Reader.Full_entries)
     | None -> Alcotest.fail "expected pending after 2nd overflow");
    (* 3rd Context_overflow at entry_count = 1 (B3): transitions mode to Reference_only *)
    let s1_ref =
      match
        Reader.apply_turn_outcome s1 ~committed Reader.Context_overflow
      with
      | Ok s -> s
      | Error err -> Alcotest.fail (Reader.error_to_string err)
    in
    (match s1_ref.pending with
     | Some p ->
       Alcotest.(check bool) "mode transitions to Reference_only" true (p.mode = Reader.Reference_only)
     | None -> Alcotest.fail "expected Reference_only pending");
    (* 4th Context_overflow while already Reference_only returns terminal Single_entry_context_overflow *)
    (match Reader.apply_turn_outcome s1_ref ~committed Reader.Context_overflow with
     | Error (Reader.Single_entry_context_overflow { seq = 1; fact_id = "f1"; _ }) -> ()
     | Ok _ -> Alcotest.fail "expected Single_entry_context_overflow on overflow of Reference_only"
     | Error err -> Alcotest.fail (Reader.error_to_string err));
    (* Persist and reload s1_ref atomically *)
    let path = Reader.reader_path ~base_path:dir ~keeper:"keeper-beta" in
    (match Reader.save_reader_state ~path s1_ref with
     | Ok () -> ()
     | Error err -> Alcotest.fail (Reader.error_to_string err));
    let s1_loaded =
      match Reader.load_reader_state ~path with
      | Ok s -> s
      | Error err -> Alcotest.fail (Reader.error_to_string err)
    in
    Alcotest.(check bool)
      "loaded reader state equals saved state"
      true
      (s1_loaded = s1_ref);
    (* Delivering s1_loaded delivers [1]; succeeding advances acknowledged_seq to 1 *)
    let s1_planned, slice1 = unwrap_plan (Reader.plan_delivery s1_loaded ~committed ()) in
    Alcotest.(check (list int))
      "delivers [1] after bisection"
      [ 1 ]
      (List.map (fun (c : Log.change_entry) -> c.seq) slice1);
    let s_after_1 =
      match
        Reader.apply_turn_outcome
          s1_planned
          ~committed
          Reader.Turn_succeeded
      with
      | Ok s -> s
      | Error err -> Alcotest.fail (Reader.error_to_string err)
    in
    Alcotest.(check int)
      "acknowledged_seq is 1 after first bisected chunk succeeds"
      1
      s_after_1.acknowledged_seq;
    (* Next plan_delivery delivers remaining [2; 3; 4] without losing position *)
    let _, remaining_slice = unwrap_plan (Reader.plan_delivery s_after_1 ~committed ()) in
    Alcotest.(check (list int))
      "remaining slice [2; 3; 4] delivered next"
      [ 2; 3; 4 ]
      (List.map (fun (c : Log.change_entry) -> c.seq) remaining_slice))

let () =
  Alcotest.run
    "Workspace_memory_log_reader"
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
    ; ( "reader"
      , [ Alcotest.test_case
            "cursor progression and sticky pending retry"
            `Quick
            test_reader_cursor_progression_and_sticky_retry
        ; Alcotest.test_case
            "context overflow bisection (4 -> 2 -> 1) and atomic persistence"
            `Quick
            test_context_overflow_bisection_and_persistence
        ] )
    ]
