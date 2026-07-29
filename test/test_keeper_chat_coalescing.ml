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

let claim_exn ~keeper_name =
  match Keeper_chat_queue.claim_next ~keeper_name with
  | `Claimed claim -> claim
  | `Empty ->
    fail "claim succeeds" "queue was empty";
    failwith "empty claim"
  | `Already_claimed attempt_id ->
    fail "claim succeeds" ("outstanding claim " ^ attempt_id);
    failwith "already claimed"
  | `Error error ->
    fail "claim succeeds" (Keeper_chat_queue.mutation_error_to_string error);
    failwith "claim failed"

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
  let first_claim = claim_exn ~keeper_name in
  check "first FIFO receipt claims alone"
    (String.equal (receipt_wire first_claim.receipt_id) first_id);
  (match
     Keeper_chat_queue.complete_claim
       ~keeper_name
       ~attempt_id:first_claim.attempt_id
       ~outcome:
         (Mark_delivered { completed_at = 2.0; outcome_ref = Some "turn-1" })
   with
   | `Completed receipt_id ->
     check "completion returns exact receipt"
       (Keeper_chat_queue.Receipt_id.equal receipt_id first.receipt_id)
   | `Unknown_claim | `Error _ ->
     check "completion returns exact receipt" false);
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
  check "restart restores one lane without load error" (report.load_errors = []);
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
  let claim = claim_exn ~keeper_name in
  ignore
    (Keeper_chat_queue.complete_claim
       ~keeper_name
       ~attempt_id:claim.attempt_id
       ~outcome:
         (Mark_failed
            { completed_at = 3.0
            ; kind = Delivery_failed
            ; detail = "transport failed"
            ; outcome_ref = None
            }) :
      [ `Completed of Keeper_chat_queue.Receipt_id.t
      | `Unknown_claim
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

let test_pending_cancellation_is_state_guarded () =
  Printf.printf "Test: pending cancellation is exact and state-guarded\n%!";
  with_base "keeper-chat-pending-cancel" @@ fun base_path ->
  let keeper_name = "pending-cancel" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let first = enqueue_exn ~keeper_name (message "first") in
  let second = enqueue_exn ~keeper_name (message "second") in
  (match
     Keeper_chat_queue.cancel_pending
       ~keeper_name
       ~receipt_id:first.receipt_id
       ~cancellation:
         { cancelled_at = 3.0
         ; detail = "cancelled by dashboard user before delivery"
         }
   with
   | Ok { revision = 3L; state = Failed { kind = Cancelled; _ }; _ } ->
     check "exact pending receipt becomes terminal once" true
   | Ok _ | Error _ ->
     check "exact pending receipt becomes terminal once" false);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "cancellation removes only the selected pending receipt"
    (active_ids snapshot.pending = [ receipt_wire second.receipt_id ]);
  check "cancellation increments terminal count"
    (Int64.equal snapshot.terminal_count 1L);
  ignore
    (enqueue_exn ~keeper_name (message "unrelated") :
      Keeper_chat_queue.enqueue_receipt);
  (match
     Keeper_chat_queue.cancel_pending
       ~keeper_name
       ~receipt_id:second.receipt_id
       ~cancellation:{ cancelled_at = 4.0; detail = "cancel after unrelated enqueue" }
   with
   | Ok { revision = 5L; state = Failed { kind = Cancelled; _ }; _ } ->
     check "unrelated queue revision does not gate exact cancellation" true
   | Ok _ | Error _ ->
     check "unrelated queue revision does not gate exact cancellation" false);
  let claim = claim_exn ~keeper_name in
  (match
     Keeper_chat_queue.cancel_pending
       ~keeper_name
       ~receipt_id:claim.receipt_id
       ~cancellation:{ cancelled_at = 5.0; detail = "too late" }
   with
   | Error
       (Keeper_chat_queue.Receipt_not_pending
          { observed_state = Some (Inflight _); _ }) ->
     check "delivery start closes the pending cancellation window" true
   | Ok _ | Error _ ->
     check "delivery start closes the pending cancellation window" false);
  check "rejected inflight cancellation does not mutate the queue"
    (Int64.equal (Keeper_chat_queue.snapshot ~keeper_name).revision 6L);
  ignore
    (Keeper_chat_queue.complete_claim
       ~keeper_name
       ~attempt_id:claim.attempt_id
       ~outcome:
         (Mark_failed
            { completed_at = 6.0
            ; kind = Delivery_failed
            ; detail = "test cleanup"
            ; outcome_ref = None
            }) :
      [ `Completed of Keeper_chat_queue.Receipt_id.t
      | `Unknown_claim
      | `Error of Keeper_chat_queue.mutation_error
      ])

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
       (* has_active_receipts takes the same entry lock the removed
          pending_count probe took — the re-entrancy invariant is what
          this test pins, not the count itself. *)
       match Keeper_chat_queue.has_active_receipts ~keeper_name with
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

let test_uncertain_claim_compensates_and_other_transitions_reconcile () =
  Printf.printf "Test: claim uncertainty compensates; complete/requeue converge exactly\n%!";
  let claim_case base_path =
    let keeper_name = "claim-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    ignore (enqueue_exn ~keeper_name (message "claim me") : Keeper_chat_queue.enqueue_receipt);
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_returned ];
    (match Keeper_chat_queue.claim_next ~keeper_name with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication =
                Keeper_chat_queue.Claim_indeterminate _
            ; _
            }) ->
       check "uncertain claim is not returned to a consumer" true
     | `Claimed _ | `Empty | `Already_claimed _ | `Error _ ->
       check "uncertain claim is not returned to a consumer" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; revision = 3L } ->
       check "uncertain durable claim compensates to Pending" true
     | Ok _ | Error _ ->
       check "uncertain durable claim compensates to Pending" false);
    check "compensated receipt is claimable again"
      (match Keeper_chat_queue.claim_next ~keeper_name with
       | `Claimed _ -> true
       | `Empty | `Already_claimed _ | `Error _ -> false)
  in
  with_base "keeper-chat-claim-uncertain" claim_case;
  let complete_case base_path =
    let keeper_name = "complete-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    let receipt = enqueue_exn ~keeper_name (message "finish me") in
    let claim = claim_exn ~keeper_name in
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_invoked ];
    (match
       Keeper_chat_queue.complete_claim
         ~keeper_name
         ~attempt_id:claim.attempt_id
         ~outcome:
           (Mark_delivered { completed_at = 4.0; outcome_ref = Some "turn" })
     with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication = Keeper_chat_queue.Complete_indeterminate _; _ }) ->
       check "uncertain completion is typed" true
     | `Completed _ | `Unknown_claim | `Error _ ->
       check "uncertain completion is typed" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id:receipt.receipt_id with
        | Ok { receipt = Some { state = Delivered _; _ }; _ } ->
          check "completion reconciliation reapplies exact terminal target" true
        | Ok _ | Error _ ->
          check "completion reconciliation reapplies exact terminal target" false)
     | Ok _ | Error _ ->
       check "completion reconciliation reapplies exact terminal target" false)
  in
  with_base "keeper-chat-complete-uncertain" complete_case;
  let requeue_case base_path =
    let keeper_name = "requeue-uncertain" in
    ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
    ignore (enqueue_exn ~keeper_name (message "requeue me") : Keeper_chat_queue.enqueue_receipt);
    let claim = claim_exn ~keeper_name in
    Keeper_chat_queue.For_testing.fail_transaction_at_stages [ Commit_returned ];
    (match Keeper_chat_queue.requeue_claim ~keeper_name ~attempt_id:claim.attempt_id with
     | `Error
         (Keeper_chat_queue.Persist_failed
            { publication = Keeper_chat_queue.Requeue_indeterminate _; _ }) ->
       check "uncertain requeue is typed" true
     | `Requeued _ | `Unknown_claim | `Error _ -> check "uncertain requeue is typed" false);
    (match Keeper_chat_queue.reconcile_persistence ~keeper_name with
     | Ok { outcome = Reconciled; _ } ->
       check "requeue reconciliation retains Pending"
         (List.length (Keeper_chat_queue.snapshot ~keeper_name).pending = 1)
     | Ok _ | Error _ -> check "requeue reconciliation retains Pending" false)
  in
  with_base "keeper-chat-requeue-uncertain" requeue_case

let test_restart_terminalizes_interrupted_claim_without_replay () =
  Printf.printf
    "Test: restart terminalizes an interrupted claim and continues FIFO\n%!";
  with_base "keeper-chat-restart-inflight" @@ fun base_path ->
  let keeper_name = "restart-inflight" in
  ignore (configure_clean base_path : Keeper_chat_queue.configure_report);
  let receipt = enqueue_exn ~keeper_name (message "do not replay me") in
  let following = enqueue_exn ~keeper_name (message "continue after interruption") in
  let claim = claim_exn ~keeper_name in
  Keeper_chat_queue.For_testing.reset ();
  let report = configure base_path in
  check "restart needs no external delivery authority" (report.load_errors = []);
  check "restart reports one interrupted receipt" (report.interrupted_receipt_count = 1);
  let snapshot = Keeper_chat_queue.snapshot ~keeper_name in
  check "restart terminal transition increments revision once"
    (Int64.equal snapshot.revision 4L);
  check "interrupted receipt is not returned to Pending or Inflight"
    (snapshot.inflight = []
     && active_ids snapshot.pending = [ receipt_wire following.receipt_id ]);
  (match Keeper_chat_queue.lane_status ~keeper_name with
   | Ok { health = Ready; has_active = true; _ } ->
     check "terminalized claim leaves its lane dispatchable" true
   | Ok _ | Error _ ->
     check "terminalized claim leaves its lane dispatchable" false);
  (match Keeper_chat_queue.lookup_receipt ~keeper_name ~receipt_id:receipt.receipt_id with
   | Ok { receipt = Some { state = Failed { kind = Interrupted; _ }; _ }; _ } ->
     check "restart records the unknown external effect as Interrupted" true
   | Ok _ | Error _ ->
     check "restart records the unknown external effect as Interrupted" false);
  (match Keeper_chat_queue.claim_next ~keeper_name with
   | `Claimed next ->
     check "next FIFO receipt proceeds without replaying the interrupted one"
       (Keeper_chat_queue.Receipt_id.equal next.receipt_id following.receipt_id
        && not (String.equal next.attempt_id claim.attempt_id))
   | `Empty | `Already_claimed _ | `Error _ ->
     check "next FIFO receipt proceeds without replaying the interrupted one" false)

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

let test_runtime_files_are_not_queue_lane_directories () =
  Printf.printf
    "Test: Keeper runtime files are not interpreted as queue lane directories\n%!";
  with_base "keeper-chat-runtime-files" @@ fun base_path ->
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  save_text (Filename.concat keepers_dir "executor.json") "{}";
  save_text (Filename.concat keepers_dir "executor.memory.jsonl") "";
  save_text (Filename.concat keepers_dir "executor.decisions.jsonl") "";
  save_text (Filename.concat keepers_dir "executor.decisions.jsonl.1") "";
  save_text (Filename.concat keepers_dir "_alerts.deadletter.jsonl") "";
  save_text (Filename.concat keepers_dir "executor.json.bak-20260715") "{}";
  save_text
    (Filename.concat keepers_dir "executor.memory.jsonl.bak-20260715")
    "";
  let report = configure base_path in
  check "runtime files produce no queue load failures"
    (report.load_errors = []);
  check "runtime files restore no queue lanes"
    (report.restored_keeper_count = 0)

let test_runtime_root_typed_filename_authority () =
  Printf.printf "Test: Keeper runtime root filenames round-trip canonically\n%!";
  let open Keeper_runtime_root_entry in
  let dotted_metadata = keeper_basename ~keeper_name:"dot.dataset" Metadata in
  let dotted_interpretations = classify_basename dotted_metadata in
  check "dotted metadata has one injective authority"
    (match dotted_interpretations with
     | [ Keeper
           { keeper_name = "dot.dataset"; artifact = Metadata; rotation = None }
       ] ->
       true
     | _ -> false);
  check "exact metadata authority preserves arbitrary dotted suffixes"
    (metadata_keeper_name dotted_metadata = Some "dot.dataset");
  check "every typed interpretation renders to the observed basename"
    (List.for_all
       (fun interpretation -> String.equal (basename interpretation) dotted_metadata)
       dotted_interpretations);
  check "noncanonical rotated filename is rejected"
    (classify_basename "executor.decisions.jsonl.01" = []);
  check "TLA trace writer rotation is owned"
    (match classify_basename "executor.tla-trace.jsonl.1" with
     | [ Keeper
           { keeper_name = "executor"; artifact = Tla_trace_log; rotation = Some 1 }
       ] ->
       true
     | _ -> false);
  check "metadata migration root backup is not an owned runtime artifact"
    (classify_basename "executor.json.bak" = []);
  check "legacy single-file metrics are not owned"
    (classify_basename "executor.metrics.jsonl" = []);
  check "removed policy logs are not owned"
    (classify_basename "executor.policy.jsonl" = []);
  check "removed alert logs are not owned"
    (classify_basename "_alerts.jsonl" = []);
  check "removed alert retry logs are not owned"
    (classify_basename "_alerts.retry.jsonl" = []);
  check "removed alert deadletters are not owned"
    (classify_basename "_alerts.deadletter.jsonl" = [])

let test_corrupt_dotted_metadata_authority_does_not_disappear () =
  Printf.printf
    "Test: corrupt dotted metadata remains in persisted Keeper inventory\n%!";
  with_base "keeper-chat-corrupt-dotted-meta" @@ fun base_path ->
  let config = Workspace.default_config base_path in
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  save_text (Filename.concat keepers_dir "corrupt.dataset.json") "not-json";
  check "corrupt dotted metadata name remains discoverable"
    (match Keeper_meta_store.persisted_keeper_names_result config with
     | Ok names -> List.mem "corrupt.dataset" names
     | Error _ -> false)

let test_regular_runtime_entry_is_outside_queue_authority () =
  Printf.printf
    "Test: regular Keeper runtime entries remain outside queue authority\n%!";
  with_base "keeper-chat-unowned-runtime-entry" @@ fun base_path ->
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let entry_name = "unexpected-queue-authority" in
  let entry_path = Filename.concat keepers_dir entry_name in
  save_text entry_path "not a declared Keeper runtime artifact";
  let report = configure base_path in
  check "regular entry produces no queue load failure"
    (report.load_errors = []);
  check "regular entry restores no queue lane"
    (report.restored_keeper_count = 0);
  check "unowned root entry does not block an unrelated Keeper lane"
    (Result.is_ok
       (Keeper_chat_queue.enqueue ~keeper_name:"unrelated" (message "works")))

let test_runtime_root_replacement_during_inventory_is_rejected () =
  Printf.printf
    "Test: Keeper runtime root replacement during inventory is rejected\n%!";
  with_base "keeper-chat-runtime-root-replacement" @@ fun base_path ->
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let displaced_dir = keepers_dir ^ ".displaced" in
  Fs_compat.mkdir_p keepers_dir;
  save_text (Filename.concat keepers_dir "executor.json") "{}";
  Keeper_chat_queue.For_testing.set_inventory_classified_observer
    (Some (fun () ->
       Unix.rename keepers_dir displaced_dir;
       Unix.mkdir keepers_dir 0o755));
  let report = configure base_path in
  check "runtime root replacement reports one registry error"
    (match report.load_errors with
     | [ None, error ] ->
       error.kind = Keeper_chat_queue.Read_failed
       && error.path = Some keepers_dir
       && String.equal error.message
            "failed to discover Keeper chat queue databases: Keeper runtime root entries changed during queue inventory"
     | _ -> false);
  check "runtime root replacement restores no queue lane"
    (report.restored_keeper_count = 0)

let test_runtime_root_child_replacement_during_inventory_is_rejected () =
  Printf.printf
    "Test: Keeper runtime root child replacement during inventory is rejected\n%!";
  with_base "keeper-chat-runtime-root-child-replacement" @@ fun base_path ->
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  let metadata_path = Filename.concat keepers_dir "executor.json" in
  save_text metadata_path "{}";
  Keeper_chat_queue.For_testing.set_inventory_classified_observer
    (Some (fun () ->
       Sys.remove metadata_path;
       Unix.mkdir metadata_path 0o755));
  let report = configure base_path in
  check "runtime root child replacement reports one registry error"
    (match report.load_errors with
     | [ None, error ] ->
       error.kind = Keeper_chat_queue.Read_failed
       && error.path = Some keepers_dir
       && String.equal error.message
            ("failed to discover Keeper chat queue databases: Keeper runtime root entry identity changed during queue inventory: "
             ^ metadata_path)
     | _ -> false);
  check "runtime root child replacement restores no queue lane"
    (report.restored_keeper_count = 0)

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

let test_finalize_statement_total () =
  Printf.printf "Test: statement finalize is total on both rc and raise channels\n%!";
  let db = Sqlite3.db_open ":memory:" in
  let stmt = Sqlite3.prepare db "SELECT 1" in
  (match Keeper_chat_queue.For_testing.finalize_statement db stmt with
   | Ok () -> check "healthy statement finalize returns Ok" true
   | Error detail -> fail "healthy statement finalize returns Ok" detail);
  (* Sqlite3.finalize raises SqliteError on an already-finalized statement;
     the wrapper must fold that raise into Error instead of letting it
     escape cleanup. *)
  (match Keeper_chat_queue.For_testing.finalize_statement db stmt with
   | Error detail ->
     check "already-finalized statement folds to Error without raising"
       (detail <> "");
     check "the Error comes from the raise channel, not an error rc"
       (String.starts_with ~prefix:"SQLite statement finalize raised:" detail)
   | Ok () ->
     check "already-finalized statement folds to Error without raising" false
   | exception exn ->
     fail "already-finalized statement folds to Error without raising"
       (Printexc.to_string exn));
  ignore (Sqlite3.db_close db : bool)

let test_finalize_statement_gc_pressure () =
  Printf.printf
    "Test: finalize keeps the statement wrap pinned across its blocking window\n%!";
  (* Exercises the pinned [sqlite_finalize] path under allocation churn:
     2,000 prepare/finalize cycles stay functionally correct while the
     minor heap turns over. Honest scope note: this loop is single-threaded
     and [Gc.minor] runs only after each finalize returns, so it does NOT
     construct the cross-thread race the pin closes (the
     stmt_wrap_finalize_gc use-after-free needs another thread to drive a
     collection during the finalize blocking window — SIGSEGV
     `checkMutexEnter <- sqlite3_finalize <- stmt_wrap_finalize_gc`,
     2026-07-15 / 2026-07-17 crash reports). The pin's guarantee rests on
     the documented [Sys.opaque_identity] semantics ("prevent the argument
     from being garbage collected until the location where the call would
     have occurred", sys.mli), which no in-process test can deterministically
     falsify; this test guards the code path's functional behavior only. *)
  let db = Sqlite3.db_open ":memory:" in
  let churn = ref [] in
  for i = 1 to 2_000 do
    let stmt = Sqlite3.prepare db "SELECT 1" in
    (match Keeper_chat_queue.For_testing.finalize_statement db stmt with
     | Ok () -> ()
     | Error detail -> fail "gc-pressure finalize returns Ok" detail);
    churn := String.make 256 'x' :: (if i mod 16 = 0 then [] else !churn);
    if i mod 64 = 0 then Gc.minor ()
  done;
  ignore (Sys.opaque_identity !churn);
  check "2000 finalize cycles under GC pressure complete" true;
  ignore (Sqlite3.db_close db : bool)

let () =
  Eio_main.run @@ fun _environment ->
  test_first_enqueue_with_runtime_eio_guard ();
  test_lifecycle_fifo_terminal_pk_and_restart ();
  test_preallocated_receipt_convergence ();
  test_pending_cancellation_is_state_guarded ();
  test_transaction_publication_boundaries ();
  test_commit_observer_exception_and_cancellation ();
  test_transition_observer_outside_lock_exactly_once ();
  test_uncertain_claim_compensates_and_other_transitions_reconcile ();
  test_restart_terminalizes_interrupted_claim_without_replay ();
  test_legacy_json_is_not_a_queue_authority ();
  test_runtime_root_typed_filename_authority ();
  test_corrupt_dotted_metadata_authority_does_not_disappear ();
  test_runtime_files_are_not_queue_lane_directories ();
  test_regular_runtime_entry_is_outside_queue_authority ();
  test_runtime_root_replacement_during_inventory_is_rejected ();
  test_runtime_root_child_replacement_during_inventory_is_rejected ();
  test_foreign_database_and_symlink_are_quarantined ();
  test_reconcile_absent_lane_and_stage_order ();
  test_finalize_statement_total ();
  test_finalize_statement_gc_pressure ();
  if !failures > 0
  then (
    Printf.printf "FAILED: %d check(s)\n%!" !failures;
    exit 1)
  else Printf.printf "All keeper_chat_coalescing checks passed\n%!"
