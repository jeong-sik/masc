(** Durable per-Keeper memory-job store regression tests. *)

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
      ?(trace_id = "trace-k1")
      ?(generation = 1)
      ?(oas_turn_count = 1)
      ?(enqueued_at = 1.0)
      ?(payload = `Assoc [ "value", `Int 1 ])
      turn
  =
  match
    Store.make_job
      ~keeper_name
      ~trace_id
      ~generation
      ~turn
      ~oas_turn_count
      ~enqueued_at
      ~payload
  with
  | Ok job -> job
  | Error error ->
    Alcotest.failf "job construction failed: %s" (Store.error_to_string error)
;;

let terminal_receipt
      ?(ended_at = 3.0)
      ?(outcome = Store.Succeeded)
      ?(detail = `Assoc [ "status", `String "ok" ])
      lease
  =
  match
    Store.make_terminal_receipt
      lease
      ~ended_at
      ~outcome
      ~detail
  with
  | Ok receipt -> receipt
  | Error error ->
    Alcotest.failf "receipt construction failed: %s" (Store.error_to_string error)
;;

let stage ~base_path job =
  match Store.stage_awaiting_turn_commit ~base_path job with
  | Ok admission -> admission
  | Error error ->
    Alcotest.failf "stage failed: %s" (Store.error_to_string error)
;;

let activate ~base_path job =
  match Store.activate ~base_path job with
  | Ok (activation, report) ->
    Alcotest.(check int)
      "activation cleanup debt"
      0
      (List.length report.cleanup_errors);
    activation
  | Error error ->
    Alcotest.failf "activation failed: %s" (Store.error_to_string error)
;;

let claim ~base_path ~keeper_name ~now =
  match Store.claim_all ~base_path ~keeper_name ~now with
  | Ok report -> report
  | Error error ->
    Alcotest.failf "claim failed: %s" (Store.error_to_string error)
;;

let check_backlog ~base_path ~keeper_name expected =
  match Store.backlog_count ~base_path ~keeper_name with
  | Ok actual -> Alcotest.(check int) "durable backlog" expected actual
  | Error error ->
    Alcotest.failf "backlog failed: %s" (Store.error_to_string error)
;;

let awaiting_path ~base_path job =
  Filename.concat
    (Store.For_testing.awaiting_dir
       ~base_path
       ~keeper_name:job.Store.keeper_name)
    (job.id ^ ".json")
;;

let pending_path ~base_path job =
  Filename.concat
    (Store.For_testing.pending_dir
       ~base_path
       ~keeper_name:job.Store.keeper_name)
    (job.id ^ ".json")
;;

let write_text path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)
;;

let write_json path json =
  match
    Fs_compat.save_file_atomic_unix
      path
      (Yojson.Safe.pretty_to_string json)
  with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "write failed path=%s: %s" path detail
;;

let read_json path =
  match Safe_ops.read_json_file_safe path with
  | Ok json -> json
  | Error detail -> Alcotest.failf "read failed path=%s: %s" path detail
;;

let replace_assoc_field name value = function
  | `Assoc fields ->
    `Assoc
      ((name, value)
       :: List.filter
            (fun (field, _) -> not (String.equal field name))
            fields)
  | _ -> Alcotest.fail "expected JSON object"
;;

let rec json_contains_string needle = function
  | `String value -> String.equal value needle
  | `Assoc fields ->
    List.exists
      (fun (_, value) -> json_contains_string needle value)
      fields
  | `List values -> List.exists (json_contains_string needle) values
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null -> false
;;

let operation_path ~base_path job =
  match
    Store.operation_stage_path_for_keepers_dir
      ~keepers_dir:(Masc.Common.keepers_runtime_dir_of_base ~base_path)
      ~keeper_name:job.Store.keeper_name
      ~operation_id:job.id
  with
  | Ok path -> path
  | Error error ->
    Alcotest.failf "operation path failed: %s" (Store.error_to_string error)
;;

let finish ~base_path receipt =
  match Store.finish ~base_path receipt with
  | Ok report -> report
  | Error error ->
    Alcotest.failf "finish failed: %s" (Store.error_to_string error)
;;

let test_retry_preserves_first_durable_envelope () =
  with_temp_dir "memory-job-canonical" (fun base_path ->
    let first =
      make_job
        ~enqueued_at:1.0
        ~payload:(`Assoc [ "alpha", `Int 1; "beta", `Int 2 ])
        1
    in
    let retry =
      make_job
        ~enqueued_at:99.0
        ~payload:(`Assoc [ "beta", `Int 2; "alpha", `Int 1 ])
        1
    in
    Alcotest.(check bool)
      "first stage"
      true
      (stage ~base_path first = Store.Staged_awaiting_turn_commit);
    Alcotest.(check bool)
      "semantic duplicate"
      true
      (stage ~base_path retry = Store.Already_awaiting);
    Alcotest.(check bool)
      "activate retry"
      true
      (activate ~base_path retry = Store.Activated);
    let report = claim ~base_path ~keeper_name:"k1" ~now:2.0 in
    let lease =
      match report.leases with
      | [ lease ] -> lease
      | leases ->
        Alcotest.failf "expected one lease, got %d" (List.length leases)
    in
    Alcotest.(check (float 0.0))
      "first enqueue timestamp wins"
      first.enqueued_at
      lease.job.enqueued_at;
    Alcotest.(check bool)
      "first payload representation wins"
      true
      (Yojson.Safe.equal first.payload lease.job.payload);
    let conflict =
      make_job ~payload:(`Assoc [ "alpha", `Int 9 ]) 1
    in
    (match Store.stage_awaiting_turn_commit ~base_path conflict with
     | Error (Store.Identity_conflict _) -> ()
     | Error error ->
       Alcotest.failf "wrong conflict: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "conflicting payload was accepted");
    let receipt = terminal_receipt lease in
    ignore (finish ~base_path receipt);
    let conflicting_receipt = terminal_receipt ~ended_at:4.0 lease in
    (match Store.finish ~base_path conflicting_receipt with
     | Error (Store.Identity_conflict _) -> ()
     | Error error ->
       Alcotest.failf
         "wrong terminal conflict: %s"
         (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "conflicting terminal timestamps were accepted");
    check_backlog ~base_path ~keeper_name:"k1" 0;
    let awaiting_dir =
      Store.For_testing.awaiting_dir ~base_path ~keeper_name:"k1"
    in
    Alcotest.(check int)
      "queue directory mode"
      0o700
      ((Unix.stat awaiting_dir).Unix.st_perm land 0o777);
    Alcotest.(check int)
      "receipt mode"
      0o600
      ((Unix.stat (Store.For_testing.receipt_path ~base_path first)).Unix.st_perm
       land 0o777))
;;

let test_ordered_claim_and_terminal_cleanup () =
  with_temp_dir "memory-job-order" (fun base_path ->
    let second = make_job ~oas_turn_count:2 ~enqueued_at:2.0 2 in
    let first = make_job ~oas_turn_count:1 ~enqueued_at:1.0 1 in
    List.iter
      (fun job ->
         ignore (stage ~base_path job);
         ignore (activate ~base_path job))
      [ second; first ];
    let report = claim ~base_path ~keeper_name:"k1" ~now:3.0 in
    Alcotest.(check (list int))
      "linear turn order"
      [ 1; 2 ]
      (List.map (fun lease -> lease.Store.job.turn) report.leases);
    Alcotest.(check int)
      "claim cleanup debt"
      0
      (List.length report.cleanup_errors);
    List.iter
      (fun lease ->
         ignore
           (finish
              ~base_path
              (terminal_receipt lease)))
      report.leases;
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_claim_does_not_overwrite_existing_lease () =
  with_temp_dir "memory-job-double-claim" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let pending = pending_path ~base_path job in
    let pending_envelope = read_json pending in
    let first_lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    write_json pending pending_envelope;
    (match Store.claim_all ~base_path ~keeper_name:"k1" ~now:3.0 with
     | Error (Store.Pending_already_inflight _) -> ()
     | Error error ->
       Alcotest.failf "wrong duplicate claim error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "existing inflight lease was overwritten");
    let receipt = terminal_receipt first_lease in
    ignore (finish ~base_path receipt);
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_receipt_backed_inflight_is_not_replayed () =
  with_temp_dir "memory-job-receipt-recovery" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    let operation = operation_path ~base_path job in
    Fs_compat.mkdir_p_durable_unix (Filename.dirname operation);
    write_text operation "staged provider result";
    let receipt = terminal_receipt lease in
    write_json
      (Store.For_testing.receipt_path ~base_path job)
      (Store.receipt_to_json receipt);
    (match Store.recover_inflight ~base_path ~keeper_name:"k1" with
     | Ok report ->
       Alcotest.(check int) "receipt prevents replay" 0 report.replayed;
       Alcotest.(check int)
         "recovery cleanup debt"
         0
         (List.length report.cleanup_errors)
     | Error error ->
       Alcotest.failf "recovery failed: %s" (Store.error_to_string error));
    Alcotest.(check bool)
      "provider stage acknowledged"
      false
      (Sys.file_exists operation);
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_recovery_rejects_mismatched_lease_receipt () =
  with_temp_dir "memory-job-receipt-lease" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    let mismatched =
      Store.receipt_to_json (terminal_receipt lease)
      |> replace_assoc_field "started_at" (`Float 9.0)
    in
    write_json (Store.For_testing.receipt_path ~base_path job) mismatched;
    (match Store.recover_inflight ~base_path ~keeper_name:"k1" with
     | Error (Store.Inflight_lease_conflict _) -> ()
     | Error error ->
       Alcotest.failf "wrong lease mismatch: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "mismatched terminal lease was accepted");
    check_backlog ~base_path ~keeper_name:"k1" 1)
;;

let test_terminal_cleanup_debt_is_explicit () =
  with_temp_dir "memory-job-cleanup-debt" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    let operation = operation_path ~base_path job in
    Fs_compat.mkdir_p_durable_unix operation;
    let report =
      finish
        ~base_path
        (terminal_receipt lease)
    in
    Alcotest.(check bool)
      "cleanup debt returned"
      true
      (report.cleanup_errors <> []);
    Alcotest.(check bool)
      "terminal receipt committed first"
      true
      (Sys.file_exists (Store.For_testing.receipt_path ~base_path job));
    check_backlog ~base_path ~keeper_name:"k1" 0)
;;

let test_stale_completion_cannot_ack_requeued_work () =
  with_temp_dir "memory-job-stale-completion" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    let receipt = terminal_receipt lease in
    (match Store.recover_inflight ~base_path ~keeper_name:"k1" with
     | Ok report -> Alcotest.(check int) "one job requeued" 1 report.replayed
     | Error error ->
       Alcotest.failf "recovery failed: %s" (Store.error_to_string error));
    (match Store.finish ~base_path receipt with
     | Error (Store.Missing_inflight_lease _) -> ()
     | Error error ->
       Alcotest.failf "wrong stale completion error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "stale completion acknowledged requeued work");
    Alcotest.(check bool)
      "terminal receipt absent"
      false
      (Sys.file_exists (Store.For_testing.receipt_path ~base_path job));
    check_backlog ~base_path ~keeper_name:"k1" 1)
;;

let test_wrong_state_and_coordinate_are_rejected () =
  with_temp_dir "memory-job-coordinates" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let pending = pending_path ~base_path job in
    let envelope =
      read_json pending
      |> replace_assoc_field
           "state"
           (`Assoc
              [ "kind", `String "inflight"
              ; "started_at", `Float 1.0
              ])
    in
    write_json pending envelope;
    (match Store.backlog_count ~base_path ~keeper_name:"k1" with
     | Error (Store.Decode_error _) -> ()
     | Error error ->
       Alcotest.failf "wrong state error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "pending directory accepted inflight state"));
  with_temp_dir "memory-job-filename" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    let source = awaiting_path ~base_path job in
    let destination =
      Filename.concat
        (Filename.dirname source)
        (String.make 64 'a' ^ ".json")
    in
    Sys.rename source destination;
    (match Store.backlog_count ~base_path ~keeper_name:"k1" with
     | Error (Store.Decode_error _) -> ()
     | Error error ->
       Alcotest.failf "wrong coordinate error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "mismatched filename was accepted"))
;;

let test_symlinked_store_boundaries_are_rejected () =
  with_temp_dir "memory-job-root-symlink" (fun base_path ->
    let job = make_job 1 in
    let jobs_root =
      Store.For_testing.awaiting_dir ~base_path ~keeper_name:"k1"
      |> Filename.dirname
    in
    let target = Filename.concat base_path "outside-jobs" in
    Unix.mkdir target 0o700;
    Fs_compat.mkdir_p (Filename.dirname jobs_root);
    Unix.symlink target jobs_root;
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Error (Store.Io_error { operation = Store.Inspect; _ }) -> ()
     | Error error ->
       Alcotest.failf "wrong root error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "symlinked memory-jobs root was accepted");
    Alcotest.(check int)
      "root target untouched"
      0
      (Array.length (Sys.readdir target)));
  with_temp_dir "memory-job-keeper-symlink" (fun base_path ->
    let job = make_job 1 in
    let keepers_root = Masc.Common.keepers_runtime_dir_of_base ~base_path in
    let keeper_dir = Filename.concat keepers_root "k1" in
    let target = Filename.concat base_path "outside-keeper" in
    Fs_compat.mkdir_p keepers_root;
    Unix.mkdir target 0o700;
    Unix.symlink target keeper_dir;
    (match Store.stage_awaiting_turn_commit ~base_path job with
     | Error (Store.Io_error { operation = Store.Inspect; _ }) -> ()
     | Error error ->
       Alcotest.failf "wrong keeper error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "symlinked keeper directory was accepted");
    Alcotest.(check int)
      "keeper target untouched"
      0
      (Array.length (Sys.readdir target)));
  with_temp_dir "memory-job-recovery-symlink" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    let awaiting_dir =
      Store.For_testing.awaiting_dir ~base_path ~keeper_name:"k1"
    in
    let recovered_root =
      Filename.concat
        (Filename.dirname awaiting_dir)
        "recovered-atomic-writes"
    in
    let target = Filename.concat base_path "outside-recovery" in
    Unix.mkdir target 0o700;
    Unix.symlink target recovered_root;
    let orphan = Filename.concat awaiting_dir ".atomic_data.tmp" in
    write_text orphan "forensic payload";
    (match Store.backlog_count ~base_path ~keeper_name:"k1" with
     | Error (Store.Io_error { operation = Store.Inspect; _ }) -> ()
     | Error error ->
       Alcotest.failf "wrong recovery error: %s" (Store.error_to_string error)
     | Ok _ -> Alcotest.fail "symlinked recovery root was accepted");
    Alcotest.(check bool) "orphan remains in queue" true (Sys.file_exists orphan);
    Alcotest.(check int)
      "recovery target untouched"
      0
      (Array.length (Sys.readdir target)))
;;

let test_atomic_orphans_are_reconciled_without_loss () =
  with_temp_dir "memory-job-orphans" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    let dir =
      Store.For_testing.awaiting_dir ~base_path ~keeper_name:"k1"
    in
    let empty = Filename.concat dir ".atomic_empty.tmp" in
    let nonempty = Filename.concat dir ".atomic_data.tmp" in
    write_text empty "";
    write_text nonempty "forensic payload";
    check_backlog ~base_path ~keeper_name:"k1" 1;
    Alcotest.(check bool) "empty orphan removed" false (Sys.file_exists empty);
    Alcotest.(check bool)
      "nonempty orphan moved"
      false
      (Sys.file_exists nonempty);
    let recovered =
      Filename.concat
        (Filename.concat
           (Filename.dirname dir)
           "recovered-atomic-writes/awaiting-turn-commit")
        ".atomic_data.tmp"
    in
    Alcotest.(check bool)
      "nonempty orphan preserved"
      true
      (Sys.file_exists recovered))
;;

let test_discovery_isolates_malformed_keeper () =
  with_temp_dir "memory-job-discovery" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    let malformed =
      Filename.concat
        (Filename.concat
           (Masc.Common.keepers_runtime_dir_of_base ~base_path)
           "bad.name")
        "memory-jobs"
    in
    Fs_compat.mkdir_p malformed;
    match Store.discover_keeper_names ~base_path with
    | Ok (keepers, errors) ->
      Alcotest.(check (list string)) "healthy keeper" [ "k1" ] keepers;
      Alcotest.(check int) "malformed keeper isolated" 1 (List.length errors)
    | Error error ->
      Alcotest.failf "discovery failed: %s" (Store.error_to_string error));
  with_temp_dir "memory-job-discovery-root" (fun base_path ->
    with_temp_dir "memory-job-discovery-external" (fun external_base ->
      let external_job =
        make_job
          ~keeper_name:"k2"
          ~trace_id:"trace-k2"
          1
      in
      ignore (stage ~base_path:external_base external_job);
      let external_keeper =
        Filename.concat
          (Masc.Common.keepers_runtime_dir_of_base ~base_path:external_base)
          "k2"
      in
      let keepers_root = Masc.Common.keepers_runtime_dir_of_base ~base_path in
      Fs_compat.mkdir_p keepers_root;
      Unix.symlink external_keeper (Filename.concat keepers_root "k2");
      match Store.discover_keeper_names ~base_path with
      | Ok (keepers, errors) ->
        Alcotest.(check (list string))
          "external keeper not discovered"
          []
          keepers;
        Alcotest.(check int)
          "symlinked keeper isolated"
          1
          (List.length errors)
      | Error error ->
        Alcotest.failf
          "symlink discovery failed: %s"
          (Store.error_to_string error)))
;;

let test_typed_boundaries_reject_invalid_values () =
  (match
     Store.make_job
       ~keeper_name:"k1"
       ~trace_id:"trace-k1"
       ~generation:1
       ~turn:1
       ~oas_turn_count:1
       ~enqueued_at:1.0
       ~payload:(`Float Float.nan)
   with
   | Error (Store.Invalid_json_value _) -> ()
   | Error error ->
     Alcotest.failf "wrong payload error: %s" (Store.error_to_string error)
   | Ok _ -> Alcotest.fail "non-finite payload was accepted");
  with_temp_dir "memory-job-invalid-receipt" (fun base_path ->
    let job = make_job 1 in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    match
      Store.make_terminal_receipt
        lease
        ~ended_at:1.0
        ~outcome:Store.Succeeded
        ~detail:`Null
    with
    | Error (Store.Invalid_terminal_timestamps _) -> ()
    | Error error ->
      Alcotest.failf "wrong timestamp error: %s" (Store.error_to_string error)
    | Ok _ -> Alcotest.fail "reversed terminal timestamps were accepted");
  (match Store.claim_all ~base_path:"/unused" ~keeper_name:"k1" ~now:Float.nan with
   | Error (Store.Invalid_claim_time _) -> ()
   | Error error ->
     Alcotest.failf "wrong claim-time error: %s" (Store.error_to_string error)
   | Ok _ -> Alcotest.fail "non-finite claim time was accepted");
  (match
     Store.operation_stage_path_for_keepers_dir
       ~keepers_dir:"/unused"
       ~keeper_name:"k1"
       ~operation_id:"../escape"
   with
   | Error (Store.Invalid_job_id _) -> ()
   | Error error ->
     Alcotest.failf "wrong operation-id error: %s" (Store.error_to_string error)
   | Ok _ -> Alcotest.fail "invalid operation id produced a path");
  let job = make_job 1 in
  let duplicate_id_json =
    match Store.job_to_json job with
    | `Assoc fields -> `Assoc (("id", `String job.id) :: fields)
    | _ -> Alcotest.fail "job JSON must be an object"
  in
  (match Store.job_of_json duplicate_id_json with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "duplicate control field was accepted")
;;

let test_receipt_identity_omits_payload () =
  with_temp_dir "memory-job-receipt-projection" (fun base_path ->
    let secret = "secret-checkpoint-payload" in
    let job =
      make_job ~payload:(`Assoc [ "secret", `String secret ]) 1
    in
    ignore (stage ~base_path job);
    ignore (activate ~base_path job);
    let lease =
      match (claim ~base_path ~keeper_name:"k1" ~now:2.0).leases with
      | [ lease ] -> lease
      | _ -> Alcotest.fail "expected one lease"
    in
    let json = Store.receipt_to_json (terminal_receipt lease) in
    Alcotest.(check bool)
      "receipt does not retain payload"
      false
      (json_contains_string secret json);
    match json with
    | `Assoc fields ->
      Alcotest.(check bool)
        "receipt has no job object"
        false
        (List.mem_assoc "job" fields)
    | _ -> Alcotest.fail "receipt must be an object")
;;

let () =
  Alcotest.run
    "keeper_memory_job_store"
    [ ( "durability"
      , [ Alcotest.test_case
            "retry preserves first durable envelope"
            `Quick
            test_retry_preserves_first_durable_envelope
        ; Alcotest.test_case
            "ordered claim and terminal cleanup"
            `Quick
            test_ordered_claim_and_terminal_cleanup
        ; Alcotest.test_case
            "claim preserves existing inflight lease"
            `Quick
            test_claim_does_not_overwrite_existing_lease
        ; Alcotest.test_case
            "receipt-backed inflight is not replayed"
            `Quick
            test_receipt_backed_inflight_is_not_replayed
        ; Alcotest.test_case
            "mismatched lease receipt is rejected"
            `Quick
            test_recovery_rejects_mismatched_lease_receipt
        ; Alcotest.test_case
            "terminal cleanup debt is explicit"
            `Quick
            test_terminal_cleanup_debt_is_explicit
        ; Alcotest.test_case
            "stale completion cannot acknowledge requeued work"
            `Quick
            test_stale_completion_cannot_ack_requeued_work
        ; Alcotest.test_case
            "atomic orphans reconcile without loss"
            `Quick
            test_atomic_orphans_are_reconciled_without_loss
        ] )
    ; ( "validation"
      , [ Alcotest.test_case
            "wrong state and coordinates are rejected"
            `Quick
            test_wrong_state_and_coordinate_are_rejected
        ; Alcotest.test_case
            "symlinked store boundaries are rejected"
            `Quick
            test_symlinked_store_boundaries_are_rejected
        ; Alcotest.test_case
            "discovery isolates malformed keeper"
            `Quick
            test_discovery_isolates_malformed_keeper
        ; Alcotest.test_case
            "typed boundaries reject invalid values"
            `Quick
            test_typed_boundaries_reject_invalid_values
        ; Alcotest.test_case
            "receipt identity omits payload"
            `Quick
            test_receipt_identity_omits_payload
        ] )
    ]
;;
