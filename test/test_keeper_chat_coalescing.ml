(* Single-SSOT Keeper chat queue regression suite. *)

open Masc

let failures = ref 0

let check name condition =
  if condition
  then Printf.printf "  ✓ %s\n%!" name
  else (
    incr failures;
    Printf.printf "  ✗ %s\n%!" name)

let fail name detail =
  check (name ^ ": " ^ detail) false

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path

let with_base prefix body =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_chat_queue.For_testing.reset ();
      rm_rf base_path)
    (fun () -> body base_path)

let message
    ?(source = Keeper_chat_queue.Dashboard { thread_id = "keeper:queue-test" })
    ?(timestamp = 1.0)
    ?(user_blocks = [])
    ?(attachments = [])
    ?(user_row_origin = Keeper_chat_store.Needs_append)
    content =
  { Keeper_chat_queue.content
  ; user_blocks
  ; attachments
  ; timestamp
  ; source
  ; user_row_origin
  }

let configure base_path =
  Keeper_chat_queue.configure_persistence ~base_path

let configure_clean base_path =
  let report = configure base_path in
  check "persistence configure has no load errors" (report.load_errors = []);
  report

let enqueue_exn ~keeper_name queued =
  match Keeper_chat_queue.enqueue ~keeper_name queued with
  | Ok receipt -> receipt
  | Error error ->
    fail "enqueue succeeds" (Keeper_chat_queue.mutation_error_to_string error);
    failwith "enqueue failed"

let enqueue_with_receipt_exn ~keeper_name ~receipt_id queued =
  match
    Keeper_chat_queue.enqueue_with_receipt ~keeper_name ~receipt_id queued
  with
  | Ok receipt -> receipt
  | Error error ->
    fail
      "enqueue_with_receipt succeeds"
      (Keeper_chat_queue.mutation_error_to_string error);
    failwith "enqueue_with_receipt failed"

let lease_exn ~keeper_name =
  match Keeper_chat_queue.lease_next ~keeper_name with
  | `Leased lease -> lease
  | `Empty ->
    fail "lease succeeds" "queue was empty";
    failwith "empty lease"
  | `Already_leased lease_id ->
    fail "lease succeeds" ("outstanding lease " ^ lease_id);
    failwith "already leased"
  | `Recovery_required evidence ->
    fail
      "lease succeeds"
      ("recovery required for "
       ^ Keeper_chat_queue.Receipt_id.to_string evidence.receipt_id);
    failwith "recovery required"
  | `Error error ->
    fail "lease succeeds" (Keeper_chat_queue.mutation_error_to_string error);
    failwith "lease failed"

let receipt_wire receipt_id =
  Keeper_chat_queue.Receipt_id.to_string receipt_id

let active_ids values =
  List.map
    (fun (value : Keeper_chat_queue.active_receipt) ->
       receipt_wire value.receipt_id)
    values

let database_path ~base_path ~keeper_name =
  match Keeper_chat_queue.For_testing.snapshot_path ~base_path ~keeper_name with
  | Ok path -> path
  | Error detail -> failwith detail

let save_text path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error detail -> failwith detail

let test_first_enqueue_with_runtime_eio_guard () =
  Printf.printf "Test: first SQLite enqueue preserves the live Eio boundary\n%!";
  with_base "keeper-chat-first-enqueue-eio" @@ fun base_path ->
  let keeper_name = "first-enqueue-eio" in
  Eio.Switch.run
  @@ fun sw ->
  Eio_guard.enable ();
  Eio.Switch.on_release sw Eio_guard.disable;
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let path = database_path ~base_path ~keeper_name in
  check "first enqueue starts without a SQLite store" (not (Sys.file_exists path));
  match Keeper_chat_queue.enqueue ~keeper_name (message "persist me") with
  | Error error ->
    fail
      "first enqueue succeeds with the runtime Eio guard"
      (Keeper_chat_queue.mutation_error_to_string error)
  | Ok receipt ->
    check "first enqueue publishes the SQLite store" (Sys.file_exists path);
    (match
       Keeper_chat_queue.lookup_receipt
         ~keeper_name
         ~receipt_id:receipt.receipt_id
     with
     | Ok { receipt = Some { state = Pending; _ }; revision } ->
       check "published receipt is durably readable"
         (Int64.equal revision receipt.revision)
     | Ok _ | Error _ ->
       check "published receipt is durably readable" false)

let test_lifecycle_fifo_terminal_pk_and_restart () =
  Printf.printf "Test: one SQLite SSOT owns FIFO, active, and terminal rows\n%!";
  with_base "keeper-chat-sqlite-lifecycle" @@ fun base_path ->
  let keeper_name = "lifecycle" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let first = enqueue_exn ~keeper_name (message "first") in
  let second = enqueue_exn ~keeper_name (message "second") in
  let first_id = receipt_wire first.receipt_id in
  let second_id = receipt_wire second.receipt_id in
  check "enqueue revisions are monotonic"
    (Int64.equal first.revision 1L && Int64.equal second.revision 2L);
  check "pending projection preserves FIFO"
    (active_ids (Keeper_chat_queue.snapshot ~keeper_name).pending
     = [ first_id; second_id ]);
  let first_lease = lease_exn ~keeper_name in
  check "first FIFO receipt leases alone"
    (String.equal (receipt_wire first_lease.item.receipt_id) first_id);
  (match
     Keeper_chat_queue.finalize
       ~keeper_name
       ~lease_id:first_lease.lease_id
       ~outcome:
         (Mark_delivered { completed_at = 2.0; outcome_ref = Some "turn-1" })
   with
   | `Finalized receipt_id ->
     check "finalize returns exact receipt"
       (Keeper_chat_queue.Receipt_id.equal receipt_id first.receipt_id)
   | `Unknown_lease | `Error _ ->
     check "finalize returns exact receipt" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "terminal body leaves active memory" (active_ids snapshot.pending = [ second_id ]);
  check "terminal count is retained without terminal list"
    (Int64.equal snapshot.terminal_count 1L);
  let terminal_wire =
    Keeper_chat_queue.For_testing.receipt_json
      ~base_path
      ~keeper_name
      ~receipt_id:first.receipt_id
  in
  (match terminal_wire with
   | Error detail ->
     fail "terminal receipt remains addressable by PK" detail
   | Ok None -> check "terminal receipt remains addressable by PK" false
   | Ok (Some wire) ->
     let json = Yojson.Safe.from_string wire in
     check "terminal row does not retain message body"
       (Json_util.assoc_member_opt "message" json = None));
  Keeper_chat_queue.For_testing.reset ();
  let report = configure base_path in
  check "restart restores one lane without recovery error" (report.load_errors = []);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "restart restores active FIFO only" (active_ids snapshot.pending = [ second_id ]);
  check "restart restores terminal count from SQL"
    (Int64.equal snapshot.terminal_count 1L);
  (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id:first.receipt_id with
   | Ok { receipt = Some { state = Delivered _; _ }; _ } ->
     check "terminal receipt lookup is a SQL PK lookup" true
   | Ok _ | Error _ -> check "terminal receipt lookup is a SQL PK lookup" false)

let test_preallocated_receipt_convergence () =
  Printf.printf "Test: preallocated receipt is idempotent without terminal body reuse\n%!";
  with_base "keeper-chat-preallocated" @@ fun base_path ->
  let keeper_name = "preallocated" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
  let queued = message "canonical payload" in
  let first = enqueue_with_receipt_exn ~keeper_name ~receipt_id queued in
  let repeated = enqueue_with_receipt_exn ~keeper_name ~receipt_id queued in
  check "active identical receipt is idempotent"
    (Int64.equal first.revision repeated.revision
     && repeated.pending_count = 1);
  (match
     Keeper_chat_queue.enqueue_with_receipt
       ~keeper_name
       ~receipt_id
       (message "different payload")
   with
   | Error (Keeper_chat_queue.Invalid_input _) ->
     check "active receipt payload collision is typed" true
   | Ok _ | Error _ -> check "active receipt payload collision is typed" false);
  let lease = lease_exn ~keeper_name in
  ignore
    (Keeper_chat_queue.finalize
       ~keeper_name
       ~lease_id:lease.lease_id
       ~outcome:
         (Mark_failed
            { completed_at = 3.0
            ; kind = Delivery_failed
            ; detail = "transport failed"
            ; outcome_ref = None
            }) :
      [ `Finalized of Keeper_chat_queue.Receipt_id.t
      | `Unknown_lease
      | `Error of Keeper_chat_queue.mutation_error
      ]);
  (match
     Keeper_chat_queue.enqueue_with_receipt
       ~keeper_name
       ~receipt_id
       queued
   with
   | Error
       (Keeper_chat_queue.Receipt_already_terminal
          { receipt_id = observed; state = Failed _ }) ->
     check "terminal preallocated receipt converges without payload equality claim"
       (Keeper_chat_queue.Receipt_id.equal receipt_id observed)
   | Ok _ | Error _ ->
     check "terminal preallocated receipt converges without payload equality claim" false)

let expect_enqueue_indeterminate label expected_receipt_id = function
  | Error
      (Keeper_chat_queue.Persist_failed
         { publication =
             Keeper_chat_queue.Enqueue_indeterminate { receipt_id; _ }
         ; _
         }) ->
    check label
      (Keeper_chat_queue.Receipt_id.equal receipt_id expected_receipt_id)
  | Ok _ -> check label false
  | Error error ->
    fail label (Keeper_chat_queue.mutation_error_to_string error)

let test_transaction_publication_boundaries () =
  Printf.printf "Test: transaction stage faults preserve publication truth\n%!";
  let run_precommit base_path =
    let keeper_name = "precommit" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Mutation_applied ];
    (match Keeper_chat_queue.enqueue ~keeper_name (message "not published") with
     | Error
         (Keeper_chat_queue.Persist_failed
            { publication = Keeper_chat_queue.Not_published; _ }) ->
       check "pre-COMMIT failure is Not_published" true
     | Ok _ | Error _ -> check "pre-COMMIT failure is Not_published" false);
    check "pre-COMMIT failure leaves memory unchanged"
      ((Keeper_chat_queue.snapshot ~keeper_name).pending = [])
  in
  with_base "keeper-chat-precommit" run_precommit;
  let run_commit_invoked base_path =
    let keeper_name = "commit-invoked" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_invoked ];
    let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
    let outcome =
      Keeper_chat_queue.enqueue_with_receipt
        ~keeper_name ~receipt_id (message "commit uncertain")
    in
    expect_enqueue_indeterminate
      "failure at COMMIT invocation is never downgraded"
      receipt_id
      outcome;
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; revision = 1L } ->
       check "COMMIT invocation uncertainty replays exact target" true
     | Ok _ | Error _ ->
       check "COMMIT invocation uncertainty replays exact target" false)
  in
  with_base "keeper-chat-commit-invoked" run_commit_invoked;
  let run_sqlite_commit_failure label failure base_path =
    let keeper_name = "commit-result" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.fail_next_commit_with failure;
    let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
    let outcome =
      Keeper_chat_queue.enqueue_with_receipt
        ~keeper_name ~receipt_id (message label)
    in
    expect_enqueue_indeterminate
      (label ^ " after COMMIT invocation remains indeterminate")
      receipt_id
      outcome;
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       check (label ^ " exact plan reconciles") true
     | Ok _ | Error _ -> check (label ^ " exact plan reconciles") false)
  in
  with_base "keeper-chat-commit-busy"
    (run_sqlite_commit_failure "SQLITE_BUSY" Commit_busy);
  with_base "keeper-chat-commit-ioerr"
    (run_sqlite_commit_failure "SQLITE_IOERR" Commit_io_error);
  let run_commit_returned base_path =
    let keeper_name = "commit-returned" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_returned ];
    let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
    let outcome =
      Keeper_chat_queue.enqueue_with_receipt
        ~keeper_name ~receipt_id (message "durable target")
    in
    expect_enqueue_indeterminate
      "post-COMMIT failure remains structurally indeterminate"
      receipt_id
      outcome;
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; revision = 1L } ->
       check "post-COMMIT reconciliation verifies target without duplicate" true
     | Ok _ | Error _ ->
       check "post-COMMIT reconciliation verifies target without duplicate" false)
  in
  with_base "keeper-chat-commit-returned" run_commit_returned;
  let run_rollback_uncertain base_path =
    let keeper_name = "rollback-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages
      [ Mutation_applied; Before_rollback ];
    let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
    let outcome =
      Keeper_chat_queue.enqueue_with_receipt
        ~keeper_name ~receipt_id (message "rollback uncertain")
    in
    expect_enqueue_indeterminate
      "rollback failure cannot claim Not_published"
      receipt_id
      outcome;
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       check "rollback uncertainty converges by exact plan" true
     | Ok _ | Error _ -> check "rollback uncertainty converges by exact plan" false)
  in
  with_base "keeper-chat-rollback-uncertain" run_rollback_uncertain

let test_commit_observer_exception_and_cancellation () =
  Printf.printf "Test: post-COMMIT exception/cancellation cannot erase durable row\n%!";
  let run_exception base_path =
    let keeper_name = "commit-observer-exception" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.set_transaction_stage_observer
      (Some (function
         | Commit_returned -> failwith "observer failed after COMMIT"
         | _ -> ()));
    let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
    let outcome =
      Keeper_chat_queue.enqueue_with_receipt
        ~keeper_name ~receipt_id (message "committed")
    in
    expect_enqueue_indeterminate
      "post-COMMIT observer exception is explicit indeterminate"
      receipt_id
      outcome;
    Keeper_chat_queue.For_testing.set_transaction_stage_observer None;
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       check "observer exception target reconciles" true
     | Ok _ | Error _ -> check "observer exception target reconciles" false)
  in
  with_base "keeper-chat-observer-exn" run_exception;
  let run_cancellation base_path =
    let keeper_name = "commit-observer-cancel" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    Keeper_chat_queue.For_testing.set_transaction_stage_observer
      (Some (function
         | Commit_returned ->
           raise (Eio.Cancel.Cancelled (Failure "cancelled after COMMIT"))
         | _ -> ()));
    (match Keeper_chat_queue.enqueue ~keeper_name (message "survives cancellation") with
     | exception Eio.Cancel.Cancelled _ ->
       check "post-COMMIT cancellation propagates" true
     | Ok _ | Error _ -> check "post-COMMIT cancellation propagates" false);
    let uncertain = Keeper_chat_queue.snapshot ~keeper_name in
    check "post-COMMIT cancellation keeps target projection"
      (List.length uncertain.pending = 1);
    check "post-COMMIT cancellation leaves explicit durability quarantine"
      (List.exists
         (fun (error : Keeper_chat_queue.snapshot_load_error) ->
            error.kind = Durability_uncertain)
         uncertain.load_errors);
    Keeper_chat_queue.For_testing.reset ();
    let report = configure base_path in
    check "restart seeds committed row after cancelled caller" (report.load_errors = []);
    check "cancelled caller did not roll back durable row"
      (List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 1)
  in
  with_base "keeper-chat-observer-cancel" run_cancellation

let test_transition_observer_outside_lock_exactly_once () =
  Printf.printf "Test: transition wake is post-commit, unlocked, and exactly once\n%!";
  with_base "keeper-chat-transition-observer" @@ fun base_path ->
  let keeper_name = "transition-observer" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let calls = ref 0 in
  let nested_read_succeeded = ref false in
  Keeper_chat_queue.set_transition_observer
    (Some (fun ~keeper_name ~revision:_ ->
       incr calls;
       match Keeper_chat_queue.pending_count ~keeper_name with
       | Ok _ -> nested_read_succeeded := true
       | Error _ -> ()));
  let receipt_id = Keeper_chat_queue.Receipt_id.generate () in
  let queued = message "wake once" in
  ignore
    (enqueue_with_receipt_exn ~keeper_name ~receipt_id queued :
      Keeper_chat_queue.enqueue_receipt);
  ignore
    (enqueue_with_receipt_exn ~keeper_name ~receipt_id queued :
      Keeper_chat_queue.enqueue_receipt);
  check "transition observer can re-enter queue after lock release"
    !nested_read_succeeded;
  check "idempotent enqueue does not emit a second wake" (!calls = 1);
  Keeper_chat_queue.set_transition_observer
    (Some (fun ~keeper_name:_ ~revision:_ ->
       incr calls;
       failwith "wake observer failure"));
  let second = Keeper_chat_queue.enqueue ~keeper_name (message "observer fails") in
  check "wake observer failure cannot roll back committed enqueue"
    (Result.is_ok second && List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 2);
  check "failing wake observer was invoked exactly once" (!calls = 2)

let test_uncertain_lease_compensates_and_other_transitions_reconcile () =
  Printf.printf "Test: lease uncertainty compensates; finalize/nack converge exactly\n%!";
  let lease_case base_path =
    let keeper_name = "lease-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    ignore (enqueue_exn ~keeper_name (message "lease me") : Keeper_chat_queue.enqueue_receipt);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_returned ];
    (match Keeper_chat_queue.lease_next ~keeper_name with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication =
                Keeper_chat_queue.Lease_indeterminate _
            ; _
            }) ->
       check "uncertain lease is not returned to a consumer" true
     | `Leased _ | `Empty | `Already_leased _ | `Recovery_required _ | `Error _ ->
       check "uncertain lease is not returned to a consumer" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; revision = 3L } ->
       check "uncertain durable lease compensates to Pending" true
     | Ok _ | Error _ ->
       check "uncertain durable lease compensates to Pending" false);
    check "compensated receipt is leaseable again"
      (match Keeper_chat_queue.lease_next ~keeper_name with
       | `Leased _ -> true
       | `Empty | `Already_leased _ | `Recovery_required _ | `Error _ -> false)
  in
  with_base "keeper-chat-lease-uncertain" lease_case;
  let finalize_case base_path =
    let keeper_name = "finalize-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    let receipt = enqueue_exn ~keeper_name (message "finish me") in
    let lease = lease_exn ~keeper_name in
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_invoked ];
    (match
       Keeper_chat_queue.finalize
         ~keeper_name
         ~lease_id:lease.lease_id
         ~outcome:
           (Mark_delivered { completed_at = 4.0; outcome_ref = Some "turn" })
     with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication = Keeper_chat_queue.Finalize_indeterminate _; _ }) ->
       check "uncertain finalize is typed" true
     | `Finalized _ | `Unknown_lease | `Error _ ->
       check "uncertain finalize is typed" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id:receipt.receipt_id with
        | Ok { receipt = Some { state = Delivered _; _ }; _ } ->
          check "finalize reconciliation reapplies exact terminal target" true
        | Ok _ | Error _ ->
          check "finalize reconciliation reapplies exact terminal target" false)
     | Ok _ | Error _ ->
       check "finalize reconciliation reapplies exact terminal target" false)
  in
  with_base "keeper-chat-finalize-uncertain" finalize_case;
  let nack_case base_path =
    let keeper_name = "nack-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    ignore (enqueue_exn ~keeper_name (message "requeue me") : Keeper_chat_queue.enqueue_receipt);
    let lease = lease_exn ~keeper_name in
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_returned ];
    (match Keeper_chat_queue.nack ~keeper_name ~lease_id:lease.lease_id with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication = Keeper_chat_queue.Nack_indeterminate _; _ }) ->
       check "uncertain nack is typed" true
     | `Requeued _ | `Unknown_lease | `Error _ -> check "uncertain nack is typed" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       check "nack reconciliation retains Pending"
         (List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 1)
     | Ok _ | Error _ -> check "nack reconciliation retains Pending" false)
  in
  with_base "keeper-chat-nack-uncertain" nack_case

let test_restart_requires_explicit_recovery_without_journal () =
  Printf.printf
    "Test: restart preserves inflight evidence until exact operator requeue\n%!";
  with_base "keeper-chat-restart-inflight" @@ fun base_path ->
  let keeper_name = "restart-inflight" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let receipt = enqueue_exn ~keeper_name (message "recover me") in
  let lease = lease_exn ~keeper_name in
  Keeper_chat_queue.For_testing.reset ();
  let report = configure base_path in
  check "restart needs no external delivery authority" (report.load_errors = []);
  check "restart reports one recovery-required receipt"
    (report.recovery_required_receipt_count = 1);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "restart recovery increments revision once" (Int64.equal snapshot.revision 3L);
  check "restart does not return inflight evidence to Pending"
    (snapshot.pending = [] && snapshot.inflight = []);
  check "restart preserves exact receipt identity in recovery state"
    (active_ids snapshot.recovery_required
     = [ receipt_wire receipt.receipt_id ]);
  (match Keeper_chat_queue.lane_status ~keeper_name with
   | Ok
       { health =
           Delivery_recovery_required
             { receipt_id; lease_id; started_at = _ }
       ; has_active = true
       ; _
       } ->
     check "O(1) lane health exposes exact recovery evidence"
       (Keeper_chat_queue.Receipt_id.equal receipt_id receipt.receipt_id
        && String.equal lease_id lease.lease_id)
   | Ok _ | Error _ ->
     check "O(1) lane health exposes exact recovery evidence" false);
  (match snapshot.recovery_required with
   | [ { state = Recovery_required evidence; _ } ] ->
     check "restart preserves exact lease evidence"
       (String.equal evidence.lease_id lease.lease_id)
   | _ -> check "restart preserves exact lease evidence" false);
  (match Keeper_chat_queue.lease_next ~keeper_name with
   | `Recovery_required evidence ->
     check "recovery-required lane cannot auto-redeliver"
       (Keeper_chat_queue.Receipt_id.equal evidence.receipt_id receipt.receipt_id
        && String.equal evidence.lease_id lease.lease_id)
   | `Leased _ | `Empty | `Already_leased _ | `Error _ ->
     check "recovery-required lane cannot auto-redeliver" false);
  let healthy_keeper = "healthy" in
  ignore
    (enqueue_exn ~keeper_name:healthy_keeper (message "independent") :
      Keeper_chat_queue.enqueue_receipt);
  check "recovery blocks only its Keeper lane"
    (match Keeper_chat_queue.lease_next ~keeper_name:healthy_keeper with
     | `Leased _ -> true
     | `Empty | `Already_leased _ | `Recovery_required _ | `Error _ -> false);
  (match
     Keeper_chat_queue.resolve_recovery_required
       ~keeper_name
       ~receipt_id:receipt.receipt_id
       ~expected_revision:2L
       ~lease_id:lease.lease_id
       ~resolution:Requeue_unconfirmed
   with
   | Error (Keeper_chat_queue.Recovery_revision_mismatch _) ->
     check "stale recovery decision is rejected" true
   | Ok _ | Error _ -> check "stale recovery decision is rejected" false);
  (match
     Keeper_chat_queue.resolve_recovery_required
       ~keeper_name
       ~receipt_id:receipt.receipt_id
       ~expected_revision:3L
       ~lease_id:"different-lease"
       ~resolution:Requeue_unconfirmed
   with
   | Error (Keeper_chat_queue.Recovery_lease_mismatch _) ->
     check "mismatched recovery evidence is rejected" true
   | Ok _ | Error _ -> check "mismatched recovery evidence is rejected" false);
  let recovery_fields =
    [ ( "schema"
      , `String Keeper_chat_recovery_command.tool_command_schema )
    ; "keeper_name", `String keeper_name
    ; "receipt_id", `String (receipt_wire receipt.receipt_id)
    ; "expected_revision", `String "3"
    ; "lease_id", `String lease.lease_id
    ; ( "decision"
      , `Assoc [ "kind", `String "requeue_unconfirmed" ] )
    ]
  in
  (match
     Keeper_chat_recovery_command.parse_tool_command
       (`Assoc (("unexpected", `Bool true) :: recovery_fields))
   with
   | Error (Keeper_chat_recovery_command.Unsupported_fields _) ->
     check "operator command rejects extra fields" true
   | Ok _ | Error _ -> check "operator command rejects extra fields" false);
  (match Keeper_chat_recovery_command.parse_tool_command (`Assoc recovery_fields) with
   | Error error ->
     fail
       "typed operator recovery command parses"
       (Keeper_chat_recovery_command.input_error_to_string error)
   | Ok command ->
     (match Keeper_chat_recovery_command.execute ~now:4.0 command with
      | Ok { revision = 4L; state = Pending; _ } ->
        check "exact operator decision requeues once" true
      | Ok _ | Error _ -> check "exact operator decision requeues once" false));
  (match Keeper_chat_queue.lease_next ~keeper_name with
   | `Leased replay ->
     check "explicit requeue preserves receipt identity"
       (Keeper_chat_queue.Receipt_id.equal
          replay.item.receipt_id receipt.receipt_id)
   | `Empty | `Already_leased _ | `Recovery_required _ | `Error _ ->
     check "explicit requeue preserves receipt identity" false)

let test_legacy_json_is_not_a_queue_authority () =
  Printf.printf "Test: removed legacy JSON is never inspected as queue state\n%!";
  with_base "keeper-chat-legacy-hard-cut" @@ fun base_path ->
  let legacy_keeper = "legacy" in
  let healthy_keeper = "healthy" in
  let legacy =
    Filename.concat
      (Filename.dirname
         (database_path ~base_path ~keeper_name:legacy_keeper))
      "chat-queue.json"
  in
  let original = "{\"schema\":\"keeper_chat_queue.v3\"}" in
  save_text legacy original;
  let report = configure base_path in
  check "legacy JSON creates no configured queue lane"
    (report.load_errors = [] && report.restored_keeper_count = 0);
  (match Keeper_chat_queue.enqueue ~keeper_name:legacy_keeper (message "blocked") with
   | Ok _ -> check "new SQLite queue ignores removed legacy format" true
   | Error _ -> check "new SQLite queue ignores removed legacy format" false);
  check "legacy file is retained byte-for-byte"
    (String.equal (Fs_compat.load_file legacy) original);
  check "new acceptance creates only the SQLite SSOT"
    (Sys.file_exists (database_path ~base_path ~keeper_name:legacy_keeper));
  check "unrelated Keeper lane remains writable"
    (Result.is_ok
       (Keeper_chat_queue.enqueue ~keeper_name:healthy_keeper (message "works")))

let test_foreign_database_and_symlink_are_quarantined () =
  Printf.printf "Test: foreign schema and symlink path never become queue SSOT\n%!";
  let foreign_case base_path =
    let keeper_name = "foreign-db" in
    let path = database_path ~base_path ~keeper_name in
    Fs_compat.mkdir_p (Filename.dirname path);
    save_text path "not a Keeper chat queue SQLite database";
    let report = configure base_path in
    check "foreign database is quarantined"
      (List.exists
         (function
           | Some observed, _ -> String.equal observed keeper_name
           | None, _ -> false)
         report.load_errors)
  in
  with_base "keeper-chat-foreign-db" foreign_case;
  let symlink_case base_path =
    let keeper_name = "symlink-db" in
    let path = database_path ~base_path ~keeper_name in
    Fs_compat.mkdir_p (Filename.dirname path);
    let target = Filename.concat base_path "outside.sqlite3" in
    save_text target "not sqlite";
    Unix.symlink target path;
    let report = configure base_path in
    check "database symlink is rejected as Invalid_path"
      (List.exists
         (function
           | Some observed, (error : Keeper_chat_queue.snapshot_load_error) ->
             String.equal observed keeper_name && error.kind = Invalid_path
           | None, _ -> false)
         report.load_errors)
  in
  with_base "keeper-chat-symlink-db" symlink_case

let test_reconcile_absent_lane_and_stage_order () =
  Printf.printf "Test: absent lane reconciliation and transaction stage order\n%!";
  with_base "keeper-chat-absent-reconcile" @@ fun base_path ->
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  (match Keeper_chat_queue.reconcile_persistence ~keeper_name:"new-keeper" with
   | Ok { outcome = Already_consistent; revision = 0L } ->
     check "absent valid lane is already consistent at revision zero" true
   | Ok _ | Error _ ->
     check "absent valid lane is already consistent at revision zero" false);
  let stages = ref [] in
  Keeper_chat_queue.For_testing.set_transaction_stage_observer
    (Some (fun stage -> stages := stage :: !stages));
  ignore
    (enqueue_exn ~keeper_name:"stage-order" (message "stage order") :
      Keeper_chat_queue.enqueue_receipt);
  check "successful transaction exposes deterministic stage order"
    (List.rev !stages
     = [ Transaction_begun
       ; Mutation_applied
       ; Before_commit
       ; Commit_invoked
       ; Commit_returned
       ; Before_close
       ])

let () =
  Eio_main.run @@ fun _environment ->
  test_first_enqueue_with_runtime_eio_guard ();
  test_lifecycle_fifo_terminal_pk_and_restart ();
  test_preallocated_receipt_convergence ();
  test_transaction_publication_boundaries ();
  test_commit_observer_exception_and_cancellation ();
  test_transition_observer_outside_lock_exactly_once ();
  test_uncertain_lease_compensates_and_other_transitions_reconcile ();
  test_restart_requires_explicit_recovery_without_journal ();
  test_legacy_json_is_not_a_queue_authority ();
  test_foreign_database_and_symlink_are_quarantined ();
  test_reconcile_absent_lane_and_stage_order ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_coalescing checks passed\n%!"
