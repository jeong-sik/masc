(** Durable Keeper memory-lane regression tests (RFC-0257). *)

module Lane = Masc.Keeper_memory_lane
module Store = Masc.Keeper_memory_job_store

let with_temp_dir label f =
  let path = Filename.temp_file ("masc-" ^ label ^ "-") "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)
;;

let make_job
      ?(keeper_name = "k1")
      ?payload
      ?enqueued_at
      turn
  =
  let trace_id = "trace-" ^ keeper_name in
  let payload =
    Option.value
      payload
      ~default:(`Assoc [ "turn", `Int turn ])
  in
  match
    Store.make_job
      ~keeper_name
      ~trace_id
      ~generation:1
      ~turn
      ~oas_turn_count:turn
      ~enqueued_at:
        (Option.value enqueued_at ~default:(float_of_int turn))
      ~payload
  with
  | Ok job -> job
  | Error error ->
    Alcotest.failf "job construction failed: %s" (Store.error_to_string error)
;;

let execution_ok job =
  Ok (`Assoc [ "turn", `Int job.Store.turn ])
;;

let admitted = function
  | Lane.Admitted { job_id; activation; worker } -> job_id, activation, worker
  | Lane.Rejected error ->
    Alcotest.failf "admission rejected: %s" (Store.error_to_string error)
;;

let staged = function
  | Lane.Staged { job_id; durable } -> job_id, durable
  | Lane.Stage_rejected error ->
    Alcotest.failf "staging rejected: %s" (Store.error_to_string error)
;;

let submit_committed ~base_path job =
  ignore (Lane.stage ~base_path job |> staged);
  Lane.activate ~base_path job |> admitted
;;

let check_backlog ~base_path ~keeper_name expected =
  match Lane.For_testing.backlog_count ~base_path ~keeper_name with
  | Ok actual -> Alcotest.(check int) "durable backlog" expected actual
  | Error error ->
    Alcotest.failf "backlog read failed: %s" (Store.error_to_string error)
;;

let read_receipt ~base_path job =
  let path = Store.For_testing.receipt_path ~base_path job in
  match Safe_ops.read_json_file_safe path with
  | Error error -> Alcotest.failf "receipt read failed: %s" error
  | Ok json ->
    (match Store.receipt_of_json json with
     | Ok receipt -> receipt
     | Error error -> Alcotest.failf "receipt decode failed: %s" error)
;;

let write_json path json =
  match Fs_compat.save_file_atomic path (Yojson.Safe.pretty_to_string json) with
  | Ok () -> ()
  | Error error -> Alcotest.failf "json write failed path=%s: %s" path error
;;

let write_text path text =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc text)
;;

let rec json_contains_string needle = function
  | `String value -> String.equal value needle
  | `Assoc fields ->
    List.exists (fun (_, value) -> json_contains_string needle value) fields
  | `List values -> List.exists (json_contains_string needle) values
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null -> false
;;

let replace_assoc_field name value = function
  | `Assoc fields ->
    `Assoc
      ((name, value)
       :: List.filter (fun (field, _) -> not (String.equal field name)) fields)
  | _ -> Alcotest.fail "expected JSON object"
;;

let pending_path ~base_path job =
  Filename.concat
    (Store.For_testing.pending_dir
       ~base_path
       ~keeper_name:job.Store.keeper_name)
    (job.id ^ ".json")
;;

let awaiting_path ~base_path job =
  Filename.concat
    (Store.For_testing.awaiting_dir
       ~base_path
       ~keeper_name:job.Store.keeper_name)
    (job.id ^ ".json")
;;

let execution_receipt_path ~base_path job =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Filename.concat
             (Masc.Common.keepers_runtime_dir_of_base ~base_path)
             job.Store.keeper_name)
          Masc.Keeper_types_support.execution_receipts_dirname)
       "2026-01")
    "01.jsonl"
;;

let write_execution_receipt_commit ~base_path job =
  let path = execution_receipt_path ~base_path job in
  ignore (Masc.Keeper_fs.ensure_dir (Filename.dirname path));
  Fs_compat.append_file_durable
    path
    (Yojson.Safe.to_string
       (`Assoc
          [ "schema", `String Masc.Keeper_types_support.execution_receipt_schema
          ; "keeper_name", `String job.keeper_name
          ; "post_turn_memory_job_id", `String job.id
          ])
     ^ "\n")
;;

let test_staged_before_init_recovers_only_from_turn_receipt () =
  with_temp_dir "memory-lane-uninitialized" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    let _job_id, durable = Lane.stage ~base_path job |> staged in
    (match durable with
     | Store.Staged_awaiting_turn_commit -> ()
     | _ -> Alcotest.fail "expected awaiting-turn-commit staging");
    let awaiting = awaiting_path ~base_path job in
    let awaiting_mode = (Unix.stat awaiting).Unix.st_perm land 0o777 in
    let awaiting_dir_mode =
      (Unix.stat (Filename.dirname awaiting)).Unix.st_perm land 0o777
    in
    let jobs_root_mode =
      (Unix.stat (Filename.dirname (Filename.dirname awaiting))).Unix.st_perm
      land 0o777
    in
    Alcotest.(check int) "awaiting payload mode" 0o600 awaiting_mode;
    Alcotest.(check int) "awaiting queue directory mode" 0o700 awaiting_dir_mode;
    Alcotest.(check int) "memory job root mode" 0o700 jobs_root_mode;
    check_backlog ~base_path ~keeper_name:"k1" 1;
    write_execution_receipt_commit ~base_path job;
    let completed = ref false in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let done_p, done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          completed := true;
          Eio.Promise.resolve done_r ();
          execution_ok job
        in
        let report = Lane.init ~sw ~clock ~base_path ~execute in
        Alcotest.(check int) "discovered keeper" 1 report.discovered_keepers;
        Eio.Promise.await done_p));
    Alcotest.(check bool) "persisted job replayed" true !completed;
    check_backlog ~base_path ~keeper_name:"k1" 0;
    let receipt = read_receipt ~base_path job in
    Alcotest.(check bool)
      "terminal success"
      true
      (receipt.outcome = Store.Succeeded))
;;

let test_duplicate_admission_is_idempotent () =
  with_temp_dir "memory-lane-dedup" (fun base_path ->
    Lane.For_testing.reset ();
    let first = make_job ~enqueued_at:1.0 1 in
    let duplicate = make_job ~enqueued_at:2.0 1 in
    let _, first_durable = Lane.stage ~base_path first |> staged in
    let _, duplicate_durable = Lane.stage ~base_path duplicate |> staged in
    Alcotest.(check bool)
      "first enqueue"
      true
      (first_durable = Store.Staged_awaiting_turn_commit);
    Alcotest.(check bool)
      "duplicate awaiting"
      true
      (duplicate_durable = Store.Already_awaiting);
    check_backlog ~base_path ~keeper_name:"k1" 1;
    let conflict = make_job ~payload:(`String "different") 1 in
    (match Lane.stage ~base_path conflict with
     | Lane.Stage_rejected (Store.Identity_conflict _) -> ()
     | Lane.Stage_rejected error ->
       Alcotest.failf "wrong conflict error: %s" (Store.error_to_string error)
     | Lane.Staged _ -> Alcotest.fail "conflicting payload was admitted"))
;;

let test_malformed_execution_receipt_preserves_awaiting_outbox () =
  with_temp_dir "memory-lane-malformed-turn-receipt" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    ignore (Lane.stage ~base_path job |> staged);
    let receipt_path = execution_receipt_path ~base_path job in
    ignore (Masc.Keeper_fs.ensure_dir (Filename.dirname receipt_path));
    write_text receipt_path "{malformed-receipt\n";
    let executed = ref false in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let execute ~base_path:_ _job =
          executed := true;
          Ok `Null
        in
        let report = Lane.init ~sw ~clock ~base_path ~execute in
        (match report.keeper_discovery_errors with
         | [ Store.Turn_receipt_error _ ] -> ()
         | [ error ] ->
           Alcotest.failf
             "wrong strict receipt error: %s"
             (Store.error_to_string error)
         | errors ->
           Alcotest.failf
             "expected one strict receipt error, got %d"
             (List.length errors));
        Eio.Fiber.yield ()));
    Alcotest.(check bool) "malformed receipt never authorizes work" false !executed;
    Alcotest.(check bool)
      "awaiting payload preserved"
      true
      (Sys.file_exists (awaiting_path ~base_path job)))
;;

let test_admission_rejects_wrong_state_in_pending_directory () =
  with_temp_dir "memory-lane-state" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    ignore (submit_committed ~base_path job);
    let path = pending_path ~base_path job in
    let envelope =
      match Safe_ops.read_json_file_safe path with
      | Ok json -> json
      | Error error -> Alcotest.failf "pending read failed: %s" error
    in
    write_json
      path
      (replace_assoc_field
         "state"
         (`Assoc
            [ "kind", `String "inflight"
            ; "started_at", `Float 1.0
            ])
         envelope);
    match Lane.stage ~base_path job with
    | Lane.Stage_rejected (Store.Decode_error _) -> ()
    | Lane.Stage_rejected error ->
      Alcotest.failf "wrong state error: %s" (Store.error_to_string error)
    | Lane.Staged _ ->
      Alcotest.fail "pending directory accepted an inflight envelope")
;;

let test_store_rejects_symlinked_memory_job_root () =
  with_temp_dir "memory-lane-symlink-root" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    let awaiting_dir =
      Store.For_testing.awaiting_dir
        ~base_path
        ~keeper_name:job.keeper_name
    in
    let jobs_root = Filename.dirname awaiting_dir in
    let target = Filename.concat base_path "outside-job-root" in
    Unix.mkdir target 0o700;
    ignore (Masc.Keeper_fs.ensure_dir (Filename.dirname jobs_root));
    Unix.symlink target jobs_root;
    (match Lane.stage ~base_path job with
     | Lane.Stage_rejected
         (Store.Io_error { operation = Store.Inspect; _ }) -> ()
     | Lane.Stage_rejected error ->
       Alcotest.failf
         "wrong symlink rejection: %s"
         (Store.error_to_string error)
     | Lane.Staged _ -> Alcotest.fail "symlinked memory-jobs root was accepted");
    Alcotest.(check int)
      "symlink target remains untouched"
      0
      (Array.length (Sys.readdir target)))
;;

let test_receipt_backed_inflight_is_acknowledged_without_replay () =
  with_temp_dir "memory-lane-receipt-recovery" (fun base_path ->
    let job = make_job 1 in
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Ok Store.Staged_awaiting_turn_commit -> ()
     | Ok _ -> Alcotest.fail "expected new durable job"
     | Error error ->
       Alcotest.failf "job admission failed: %s" (Store.error_to_string error));
    (match Store.activate ~base_path job with
     | Ok (Store.Activated, _) -> ()
     | Ok _ -> Alcotest.fail "expected job activation"
     | Error error -> Alcotest.fail (Store.error_to_string error));
    let lease =
      match Store.claim_all ~base_path ~keeper_name:"k1" ~now:2.0 with
      | Ok { leases = [ lease ]; _ } -> lease
      | Ok _ -> Alcotest.fail "expected one claimed job"
      | Error error ->
        Alcotest.failf "job claim failed: %s" (Store.error_to_string error)
    in
    let receipt : Store.terminal_receipt =
      { identity = Store.receipt_identity_of_job job
      ; started_at = lease.started_at
      ; ended_at = 3.0
      ; outcome = Store.Succeeded
      ; detail = `Assoc [ "test", `Bool true ]
      }
    in
    let operation_stage_path =
      Store.operation_stage_path_for_keepers_dir
        ~keepers_dir:(Masc.Common.keepers_runtime_dir_of_base ~base_path)
        ~keeper_name:job.keeper_name
        ~operation_id:job.id
    in
    ignore (Masc.Keeper_fs.ensure_dir (Filename.dirname operation_stage_path));
    write_text operation_stage_path "staged provider payload";
    write_json
      (Store.For_testing.receipt_path ~base_path job)
      (Store.receipt_to_json receipt);
    (match Store.recover_inflight ~base_path ~keeper_name:"k1" with
     | Ok recovery ->
       Alcotest.(check int)
         "receipt-backed job was not replayed"
         0
         recovery.replayed
     | Error error ->
       Alcotest.failf "recovery failed: %s" (Store.error_to_string error));
    Alcotest.(check bool)
      "receipt acknowledgement removes operation stage"
      false
      (Sys.file_exists operation_stage_path);
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_terminal_receipt_cleanup_debt_does_not_block_lane () =
  with_temp_dir "memory-lane-cleanup-debt" (fun base_path ->
    let job = make_job 1 in
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Ok Store.Staged_awaiting_turn_commit -> ()
     | Ok _ -> Alcotest.fail "expected staged job"
     | Error error -> Alcotest.fail (Store.error_to_string error));
    (match Store.activate ~base_path job with
     | Ok (Store.Activated, _) -> ()
     | Ok _ -> Alcotest.fail "expected activated job"
     | Error error -> Alcotest.fail (Store.error_to_string error));
    let lease =
      match Store.claim_all ~base_path ~keeper_name:"k1" ~now:2.0 with
      | Ok { leases = [ lease ]; _ } -> lease
      | Ok _ -> Alcotest.fail "expected one claimed job"
      | Error error -> Alcotest.fail (Store.error_to_string error)
    in
    let operation_stage_path =
      Store.operation_stage_path_for_keepers_dir
        ~keepers_dir:(Masc.Common.keepers_runtime_dir_of_base ~base_path)
        ~keeper_name:job.keeper_name
        ~operation_id:job.id
    in
    ignore (Masc.Keeper_fs.ensure_dir operation_stage_path);
    let receipt : Store.terminal_receipt =
      { identity = Store.receipt_identity_of_job job
      ; started_at = lease.started_at
      ; ended_at = 3.0
      ; outcome = Store.Succeeded
      ; detail = `Null
      }
    in
    (match Store.finish ~base_path receipt with
     | Error error ->
       Alcotest.failf
         "terminal receipt was incorrectly blocked by cleanup: %s"
         (Store.error_to_string error)
     | Ok report ->
       Alcotest.(check bool)
         "cleanup debt surfaced"
         true
         (report.cleanup_errors <> []));
    Alcotest.(check bool)
      "terminal receipt committed"
      true
      (Sys.file_exists (Store.For_testing.receipt_path ~base_path job));
    check_backlog ~base_path ~keeper_name:job.keeper_name 0)
;;

let test_malformed_keeper_discovery_does_not_block_healthy_keeper () =
  with_temp_dir "memory-lane-discovery-isolation" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    ignore (submit_committed ~base_path job);
    let malformed_jobs_dir =
      Filename.concat
        (Filename.concat
           (Masc.Common.keepers_runtime_dir_of_base ~base_path)
           "bad.name")
        "memory-jobs"
    in
    let (_ : string) = Masc.Keeper_fs.ensure_dir malformed_jobs_dir in
    let completed = ref false in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let done_p, done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          completed := true;
          Eio.Promise.resolve done_r ();
          execution_ok job
        in
        let report = Lane.init ~sw ~clock ~base_path ~execute in
        Alcotest.(check int) "healthy keeper discovered" 1 report.discovered_keepers;
        Alcotest.(check int)
          "malformed keeper isolated"
          1
          (List.length report.keeper_discovery_errors);
        Eio.Promise.await done_p));
    Alcotest.(check bool) "healthy keeper replayed" true !completed;
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_receipt_omits_job_payload () =
  let secret = "secret-checkpoint-payload" in
  let job = make_job ~payload:(`Assoc [ "secret", `String secret ]) 1 in
  let receipt : Store.terminal_receipt =
    { identity = Store.receipt_identity_of_job job
    ; started_at = 1.0
    ; ended_at = 2.0
    ; outcome = Store.Succeeded
    ; detail = `Assoc [ "status", `String "ok" ]
    }
  in
  let json = Store.receipt_to_json receipt in
  Alcotest.(check bool)
    "receipt does not retain payload string"
    false
    (json_contains_string secret json);
  match json with
  | `Assoc fields ->
    Alcotest.(check bool)
      "receipt has no job payload object"
      false
      (List.mem_assoc "job" fields)
  | _ -> Alcotest.fail "receipt must be an object"
;;

let test_queue_rejects_filename_coordinate_mismatch () =
  with_temp_dir "memory-lane-coordinate" (fun base_path ->
    let job = make_job 1 in
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Ok Store.Staged_awaiting_turn_commit -> ()
     | Ok _ -> Alcotest.fail "expected new durable job"
     | Error error -> Alcotest.fail (Store.error_to_string error));
    let source = awaiting_path ~base_path job in
    let destination =
      Filename.concat
        (Filename.dirname source)
        (String.make 64 'a' ^ ".json")
    in
    Sys.rename source destination;
    match Store.backlog_count ~base_path ~keeper_name:job.keeper_name with
    | Error (Store.Decode_error _) -> ()
    | Error error ->
      Alcotest.failf "wrong coordinate error: %s" (Store.error_to_string error)
    | Ok _ -> Alcotest.fail "queue accepted a mismatched filename coordinate")
;;

let test_queue_reconciles_atomic_write_orphans () =
  with_temp_dir "memory-lane-atomic-orphan" (fun base_path ->
    let job = make_job 1 in
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Ok Store.Staged_awaiting_turn_commit -> ()
     | Ok _ -> Alcotest.fail "expected new durable job"
     | Error error -> Alcotest.fail (Store.error_to_string error));
    let awaiting_dir =
      Store.For_testing.awaiting_dir ~base_path ~keeper_name:job.keeper_name
    in
    let empty_orphan = Filename.concat awaiting_dir ".atomic_empty.tmp" in
    let nonempty_orphan = Filename.concat awaiting_dir ".atomic_data.tmp" in
    write_text empty_orphan "";
    write_text nonempty_orphan "forensic payload";
    (match Store.backlog_count ~base_path ~keeper_name:job.keeper_name with
     | Ok count -> Alcotest.(check int) "real backlog remains" 1 count
     | Error error -> Alcotest.fail (Store.error_to_string error));
    Alcotest.(check bool) "zero orphan removed" false (Sys.file_exists empty_orphan);
    Alcotest.(check bool)
      "nonempty orphan moved"
      false
      (Sys.file_exists nonempty_orphan);
    let recovered =
      Filename.concat
        (Filename.concat
           (Filename.dirname awaiting_dir)
           "recovered-atomic-writes/awaiting-turn-commit")
        ".atomic_data.tmp"
    in
    Alcotest.(check bool) "nonempty orphan preserved" true (Sys.file_exists recovered))
;;

let test_receipt_failure_with_concurrent_wake_replays_and_continues () =
  with_temp_dir "memory-lane-lost-wake" (fun base_path ->
    Lane.For_testing.reset ();
    let first = make_job 1 in
    let second = make_job 2 in
    let receipts_dir =
      Store.For_testing.receipts_dir ~base_path ~keeper_name:first.keeper_name
    in
    Fun.protect
      ~finally:(fun () ->
        if Sys.file_exists receipts_dir then Unix.chmod receipts_dir 0o700)
      (fun () ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             let clock = Eio.Stdenv.clock env in
             let first_started, first_started_r = Eio.Promise.create () in
             let release_first, release_first_r = Eio.Promise.create () in
             let second_done, second_done_r = Eio.Promise.create () in
             let first_calls = ref 0 in
             let execute ~base_path:_ job =
               if job.Store.turn = first.turn
               then (
                 incr first_calls;
                 if !first_calls = 1
                 then (
                   Eio.Promise.resolve first_started_r ();
                   Eio.Promise.await release_first)
                 else Unix.chmod receipts_dir 0o700;
                 execution_ok job)
               else (
                 Eio.Promise.resolve second_done_r ();
                 execution_ok job)
             in
             ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
             ignore (submit_committed ~base_path first);
             Eio.Promise.await first_started;
             ignore (submit_committed ~base_path second);
             Unix.chmod receipts_dir 0o500;
             Eio.Promise.resolve release_first_r ();
             Eio.Promise.await second_done;
             Alcotest.(check int) "failed receipt job replayed" 2 !first_calls));
         check_backlog ~base_path ~keeper_name:first.keeper_name 0;
         Alcotest.(check bool)
           "first terminal receipt committed after replay"
           true
           ((read_receipt ~base_path first).outcome = Store.Succeeded);
         Alcotest.(check bool)
           "concurrent wake job completed"
           true
           ((read_receipt ~base_path second).outcome = Store.Succeeded)))
;;

let test_serializes_within_keeper () =
  with_temp_dir "memory-lane-serial" (fun base_path ->
    Lane.For_testing.reset ();
    let order = ref [] in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let first_started, first_started_r = Eio.Promise.create () in
        let release_first, release_first_r = Eio.Promise.create () in
        let second_done, second_done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          if job.Store.turn = 1
          then (
            order := !order @ [ "first-start" ];
            Eio.Promise.resolve first_started_r ();
            Eio.Promise.await release_first;
            order := !order @ [ "first-end" ])
          else (
            order := !order @ [ "second" ];
            Eio.Promise.resolve second_done_r ());
          execution_ok job
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        ignore (submit_committed ~base_path (make_job 1));
        Eio.Promise.await first_started;
        ignore (submit_committed ~base_path (make_job 2));
        Eio.Fiber.yield ();
        Alcotest.(check (list string))
          "second has not started"
          [ "first-start" ]
          !order;
        Eio.Promise.resolve release_first_r ();
        Eio.Promise.await second_done));
    Alcotest.(check (list string))
      "FIFO order"
      [ "first-start"; "first-end"; "second" ]
      !order;
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_independent_keepers_run_concurrently () =
  with_temp_dir "memory-lane-independent" (fun base_path ->
    Lane.For_testing.reset ();
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let k1_started, k1_started_r = Eio.Promise.create () in
        let release_k1, release_k1_r = Eio.Promise.create () in
        let k2_done, k2_done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          if String.equal job.Store.keeper_name "k1"
          then (
            Eio.Promise.resolve k1_started_r ();
            Eio.Promise.await release_k1)
          else Eio.Promise.resolve k2_done_r ();
          execution_ok job
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        ignore (submit_committed ~base_path (make_job ~keeper_name:"k1" 1));
        Eio.Promise.await k1_started;
        ignore (submit_committed ~base_path (make_job ~keeper_name:"k2" 1));
        Eio.Promise.await k2_done;
        Eio.Promise.resolve release_k1_r ())))
;;

let test_failed_job_receipt_does_not_block_next () =
  with_temp_dir "memory-lane-failure" (fun base_path ->
    Lane.For_testing.reset ();
    let first = make_job 1 in
    let second = make_job 2 in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let second_done, second_done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          if job.Store.turn = 1
          then
            Error
              Lane.
                { retryability = Lane.Terminal
                ; kind = "test_failure"
                ; message = "expected"
                ; detail = `Null
                }
          else (
            Eio.Promise.resolve second_done_r ();
            execution_ok job)
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        ignore (submit_committed ~base_path first);
        ignore (submit_committed ~base_path second);
        Eio.Promise.await second_done));
    Alcotest.(check bool)
      "first failed"
      true
      ((read_receipt ~base_path first).outcome = Store.Failed);
    Alcotest.(check bool)
      "second succeeded"
      true
      ((read_receipt ~base_path second).outcome = Store.Succeeded);
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_cancelled_inflight_replays_after_restart () =
  with_temp_dir "memory-lane-restart" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let started, started_r = Eio.Promise.create () in
        let never, _never_r = Eio.Promise.create () in
        let execute ~base_path:_ _job =
          Eio.Promise.resolve started_r ();
          Eio.Promise.await never;
          Ok `Null
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        ignore (submit_committed ~base_path job);
        Eio.Promise.await started));
    check_backlog ~base_path ~keeper_name:"k1" 1;
    Lane.For_testing.reset ();
    let replayed = ref false in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let done_p, done_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          replayed := true;
          Eio.Promise.resolve done_r ();
          execution_ok job
        in
        let report = Lane.init ~sw ~clock ~base_path ~execute in
        Alcotest.(check int) "restart discovered keeper" 1 report.discovered_keepers;
        Eio.Promise.await done_p));
    Alcotest.(check bool) "inflight replayed" true !replayed;
    Alcotest.(check bool)
      "replay terminal success"
      true
      ((read_receipt ~base_path job).outcome = Store.Succeeded);
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_uncommitted_awaiting_job_is_aborted_on_startup () =
  with_temp_dir "memory-lane-uncommitted-outbox" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    ignore (Lane.stage ~base_path job |> staged);
    let executed = ref false in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let execute ~base_path:_ _job =
          executed := true;
          Ok `Null
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        Eio.Fiber.yield ()));
    Alcotest.(check bool) "uncommitted job never executed" false !executed;
    Alcotest.(check bool)
      "awaiting envelope removed"
      false
      (Sys.file_exists (awaiting_path ~base_path job));
    check_backlog ~base_path ~keeper_name:job.keeper_name 0)
;;

let test_retryable_failure_self_schedules_without_new_signal () =
  with_temp_dir "memory-lane-self-retry" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    let calls = ref 0 in
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let completed, completed_r = Eio.Promise.create () in
        let execute ~base_path:_ job =
          incr calls;
          if !calls = 1
          then
            Error
              Lane.
                { retryability = Lane.Retryable
                ; kind = "transient_test_failure"
                ; message = "retry without a second submit"
                ; detail = `Null
                }
          else (
            Eio.Promise.resolve completed_r ();
            execution_ok job)
        in
        ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
        ignore (submit_committed ~base_path job);
        Eio.Promise.await completed));
    Alcotest.(check int) "self retry count" 2 !calls;
    check_backlog ~base_path ~keeper_name:job.keeper_name 0)
;;

let test_post_receipt_activation_failure_self_reconciles () =
  with_temp_dir "memory-lane-activation-reconcile" (fun base_path ->
    Lane.For_testing.reset ();
    let job = make_job 1 in
    let blocked_pending_path = pending_path ~base_path job in
    Fun.protect
      ~finally:(fun () ->
        if Sys.file_exists blocked_pending_path
           && Sys.is_directory blocked_pending_path
        then Unix.rmdir blocked_pending_path)
      (fun () ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             let clock = Eio.Stdenv.clock env in
             let completed, completed_r = Eio.Promise.create () in
             let execute ~base_path:_ job =
               Eio.Promise.resolve completed_r ();
               execution_ok job
             in
             ignore (Lane.init ~sw ~clock ~base_path ~execute : Lane.init_report);
             ignore (Lane.stage ~base_path job |> staged);
             write_execution_receipt_commit ~base_path job;
             Unix.mkdir blocked_pending_path 0o700;
             (match Lane.activate ~base_path job with
              | Lane.Rejected _ -> ()
              | Lane.Admitted _ ->
                Alcotest.fail
                  "activation unexpectedly succeeded through blocked queue path");
             Unix.rmdir blocked_pending_path;
             Eio.Promise.await completed));
         check_backlog ~base_path ~keeper_name:job.keeper_name 0;
         Alcotest.(check bool)
           "reconciled job terminal receipt committed"
           true
           ((read_receipt ~base_path job).outcome = Store.Succeeded)))
;;

let () =
  Alcotest.run
    "keeper_memory_lane"
    [ ( "durability"
      , [ Alcotest.test_case
            "staged outbox recovers from turn receipt"
            `Quick
            test_staged_before_init_recovers_only_from_turn_receipt
        ; Alcotest.test_case
            "duplicate admission is idempotent"
            `Quick
            test_duplicate_admission_is_idempotent
        ; Alcotest.test_case
            "malformed turn receipt preserves outbox"
            `Quick
            test_malformed_execution_receipt_preserves_awaiting_outbox
        ; Alcotest.test_case
            "cancelled inflight replays after restart"
            `Quick
            test_cancelled_inflight_replays_after_restart
        ; Alcotest.test_case
            "pending directory rejects inflight state"
            `Quick
            test_admission_rejects_wrong_state_in_pending_directory
        ; Alcotest.test_case
            "symlinked memory job root is rejected"
            `Quick
            test_store_rejects_symlinked_memory_job_root
        ; Alcotest.test_case
            "receipt-backed inflight is acknowledged"
            `Quick
            test_receipt_backed_inflight_is_acknowledged_without_replay
        ; Alcotest.test_case
            "terminal cleanup debt does not block"
            `Quick
            test_terminal_receipt_cleanup_debt_does_not_block_lane
        ; Alcotest.test_case
            "malformed keeper does not block healthy discovery"
            `Quick
            test_malformed_keeper_discovery_does_not_block_healthy_keeper
        ; Alcotest.test_case
            "receipt omits durable payload"
            `Quick
            test_receipt_omits_job_payload
        ; Alcotest.test_case
            "queue rejects filename coordinate mismatch"
            `Quick
            test_queue_rejects_filename_coordinate_mismatch
        ; Alcotest.test_case
            "queue reconciles atomic write orphans"
            `Quick
            test_queue_reconciles_atomic_write_orphans
        ; Alcotest.test_case
            "uncommitted outbox is aborted"
            `Quick
            test_uncommitted_awaiting_job_is_aborted_on_startup
        ] )
    ; ( "lane"
      , [ Alcotest.test_case
            "serializes within keeper"
            `Quick
            test_serializes_within_keeper
        ; Alcotest.test_case
            "keepers run independently"
            `Quick
            test_independent_keepers_run_concurrently
        ; Alcotest.test_case
            "failed job does not block next"
            `Quick
            test_failed_job_receipt_does_not_block_next
        ; Alcotest.test_case
            "receipt failure concurrent wake continues"
            `Quick
            test_receipt_failure_with_concurrent_wake_replays_and_continues
        ; Alcotest.test_case
            "retryable failure self schedules"
            `Quick
            test_retryable_failure_self_schedules_without_new_signal
        ; Alcotest.test_case
            "post-receipt activation self reconciles"
            `Quick
            test_post_receipt_activation_failure_self_reconciles
        ] )
    ]
;;
