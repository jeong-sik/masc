module P = Keeper_event_queue_persistence
module Q = Keeper_event_queue

type cancellation_outcome =
  | Cancellation_observed
  | Returned
  | Raised of string

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let source_ref () =
  let trace_id =
    match Keeper_id.Trace_id.of_string "exact-lease-guard" with
    | Ok trace_id -> trace_id
    | Error detail -> Alcotest.failf "trace id rejected: %s" detail
  in
  match
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:1
      ~turn_count:1
      ~sha256:(String.make 64 'a')
  with
  | Ok source -> source
  | Error _ -> Alcotest.fail "checkpoint source rejected"
;;

let claim_manual_lease ~base_path ~keeper_name =
  let stimulus : Q.stimulus =
    { post_id = "manual-compaction"
    ; urgency = Q.Immediate
    ; arrived_at = 1.0
    ; payload = Q.Manual_compaction_requested
    }
  in
  (match
     P.update_checked_result
       ~base_path
       ~keeper_name
       (fun pending -> Ok (Q.enqueue pending stimulus))
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "manual stimulus persist failed: %s" detail);
  match
    P.claim_when_result
      ~base_path
      ~keeper_name
      ~claimed_at:2.0
      ~ready:(fun _ -> true)
      ()
  with
  | Ok (Some lease) -> lease
  | Ok None -> Alcotest.fail "manual lease was not claimed"
  | Error detail -> Alcotest.failf "manual lease claim failed: %s" detail
;;

let bind_and_quarantine
      ~base_path
      ~keeper_name
      ~cause
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  let lease = claim_manual_lease ~base_path ~keeper_name in
  (match
     P.bind_exact_execution_result
       ~base_path
       ~keeper_name
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ()
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "exact execution bind failed: %s" detail);
  let terminal : P.exact_execution_terminal = { cause; slot_id; call_id } in
  (match
     P.quarantine_exact_execution_result
       ~base_path
       ~keeper_name
       ~lease
       ~terminal
       ~plan_fingerprint
       ~request_body_sha256
       ()
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "exact execution quarantine failed: %s" detail);
  lease, terminal
;;

let terminal_settlement source terminal : P.settlement =
  P.No_compaction { source; reason = P.Exact_execution_terminal terminal }
;;

let check_binding ~base_path ~keeper_name ~call_id ~plan_fingerprint =
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok
      (Some
        { call_id = actual_call_id
        ; plan_fingerprint = actual_plan_fingerprint
        ; status = P.Terminal_quarantined _
        ; _
        }) ->
    Alcotest.(check string) "durable call id" call_id actual_call_id;
    Alcotest.(check string)
      "durable plan fingerprint"
      plan_fingerprint
      actual_plan_fingerprint
  | Ok (Some _) -> Alcotest.fail "binding was not terminally quarantined"
  | Ok None -> Alcotest.fail "durable exact execution binding disappeared"
  | Error detail -> Alcotest.failf "binding load failed: %s" detail
;;

let bind_exact_execution
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  match
    P.bind_exact_execution_result
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "exact execution bind failed: %s" detail
;;

let check_dispatch_uncertain_binding
      ~base_path
      ~keeper_name
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  =
  match P.exact_execution_binding_result ~base_path ~keeper_name with
  | Ok
      (Some
        { slot_id = actual_slot_id
        ; call_id = actual_call_id
        ; plan_fingerprint = actual_plan_fingerprint
        ; request_body_sha256 = actual_request_body_sha256
        ; status = P.Dispatch_uncertain
        ; _
        }) ->
    Alcotest.(check string) "dispatch-uncertain slot" slot_id actual_slot_id;
    Alcotest.(check string) "dispatch-uncertain call" call_id actual_call_id;
    Alcotest.(check string)
      "dispatch-uncertain plan"
      plan_fingerprint
      actual_plan_fingerprint;
    Alcotest.(check string)
      "dispatch-uncertain request"
      request_body_sha256
      actual_request_body_sha256
  | Ok (Some _) -> Alcotest.fail "exact execution binding was not dispatch-uncertain"
  | Ok None -> Alcotest.fail "dispatch-uncertain binding disappeared"
  | Error detail -> Alcotest.failf "dispatch-uncertain binding load failed: %s" detail
;;

let test_bind_crash_restart_remains_blocked () =
  with_temp_dir "masc-exact-bind-crash" @@ fun base_path ->
  let keeper_name = "exact_bind_crash" in
  let slot_id = "slot-bind-crash" in
  let call_id = "call-bind-crash" in
  let plan_fingerprint = "plan-bind-crash" in
  let request_body_sha256 = String.make 64 'd' in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  bind_exact_execution
    ~base_path
    ~keeper_name
    ~lease
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256;
  check_dispatch_uncertain_binding
    ~base_path
    ~keeper_name
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256;
  (match
     P.settle_result
       ~base_path
       ~keeper_name
       ~settled_at:3.0
       ~lease
       ~settlement:(P.Requeue P.Context_compaction_retry)
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "dispatch-uncertain lease accepted a generic requeue");
  (match P.prepare_registration_result ~base_path ~keeper_name ~settled_at:4.0 () with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "restart requeued a dispatch-uncertain exact execution");
  check_dispatch_uncertain_binding
    ~base_path
    ~keeper_name
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256;
  match P.load_pending_result ~base_path ~keeper_name with
  | Ok pending -> Alcotest.(check bool) "restart created no replay" true (Q.is_empty pending)
  | Error detail -> Alcotest.failf "pending load failed: %s" detail
;;

let test_before_dispatch_release_allows_registration_requeue () =
  with_temp_dir "masc-exact-before-dispatch-release" @@ fun base_path ->
  let keeper_name = "exact_before_dispatch_release" in
  let slot_id = "slot-before-dispatch" in
  let call_id = "call-before-dispatch" in
  let plan_fingerprint = "plan-before-dispatch" in
  let request_body_sha256 = String.make 64 'e' in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  bind_exact_execution
    ~base_path
    ~keeper_name
    ~lease
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256;
  (match
     P.release_exact_execution_before_dispatch_result
       ~base_path
       ~keeper_name
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ()
   with
   | Ok () -> ()
   | Error detail -> Alcotest.failf "before-dispatch release failed: %s" detail);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "before-dispatch release retained the binding"
   | Error detail -> Alcotest.failf "released binding load failed: %s" detail);
  let terminal : P.exact_execution_terminal =
    { cause = P.Execution_failed_after_dispatch; slot_id; call_id }
  in
  (match
     P.settle_exact_execution_result
       ~base_path
       ~keeper_name
       ~settled_at:3.0
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ~settlement:(terminal_settlement (source_ref ()) terminal)
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "active unbound lease accepted exact settlement");
  match P.prepare_registration_result ~base_path ~keeper_name ~settled_at:4.0 () with
  | Ok pending ->
    Alcotest.(check bool)
      "proven before-dispatch release permits replay"
      false
      (Q.is_empty pending)
  | Error detail -> Alcotest.failf "released registration failed: %s" detail
;;

let test_conflicting_concurrent_bind_has_single_winner () =
  Eio_main.run @@ fun _env ->
  with_temp_dir "masc-exact-concurrent-bind" @@ fun base_path ->
  let keeper_name = "exact_concurrent_bind" in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  let slot_id = "slot-concurrent" in
  let call_a = "call-concurrent-a" in
  let call_b = "call-concurrent-b" in
  let plan_a = "plan-concurrent-a" in
  let plan_b = "plan-concurrent-b" in
  let request_a = String.make 64 'f' in
  let request_b = String.make 64 '0' in
  let bind ~call_id ~plan_fingerprint ~request_body_sha256 () =
    P.bind_exact_execution_result
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  in
  let result_a, result_b =
    Eio.Fiber.pair
      (bind ~call_id:call_a ~plan_fingerprint:plan_a ~request_body_sha256:request_a)
      (bind ~call_id:call_b ~plan_fingerprint:plan_b ~request_body_sha256:request_b)
  in
  let winner_call, winner_plan, winner_request =
    match result_a, result_b with
    | Ok (), Error _ -> call_a, plan_a, request_a
    | Error _, Ok () -> call_b, plan_b, request_b
    | Ok (), Ok () -> Alcotest.fail "conflicting exact binds both succeeded"
    | Error first, Error second ->
      Alcotest.failf "conflicting exact binds both failed: %s / %s" first second
  in
  check_dispatch_uncertain_binding
    ~base_path
    ~keeper_name
    ~slot_id
    ~call_id:winner_call
    ~plan_fingerprint:winner_plan
    ~request_body_sha256:winner_request;
  match P.prepare_registration_result ~base_path ~keeper_name ~settled_at:3.0 () with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "concurrent bind winner became replayable"
;;

let test_restart_recovery_never_requeues_bound_lease () =
  with_temp_dir "masc-exact-lease-restart" @@ fun base_path ->
  let keeper_name = "exact_restart_guard" in
  let slot_id = "slot-restart" in
  let call_id = "call-restart" in
  let plan_fingerprint = "plan-restart" in
  let request_body_sha256 = String.make 64 'b' in
  let lease, terminal =
    bind_and_quarantine
      ~base_path
      ~keeper_name
      ~cause:P.Execution_failed_after_dispatch
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  check_binding ~base_path ~keeper_name ~call_id ~plan_fingerprint;
  let settlement = terminal_settlement (source_ref ()) terminal in
  let wal_path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      "event-queue-settlements.jsonl"
  in
  Unix.mkdir wal_path 0o700;
  (match
     P.settle_exact_execution_result
       ~base_path
       ~keeper_name
       ~settled_at:3.0
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ~settlement
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "poisoned WAL unexpectedly committed settlement");
  Unix.rmdir wal_path;
  (match P.prepare_registration_result ~base_path ~keeper_name ~settled_at:4.0 () with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "registration recovery requeued a bound exact execution");
  check_binding ~base_path ~keeper_name ~call_id ~plan_fingerprint;
  (match P.load_pending_result ~base_path ~keeper_name with
   | Ok pending -> Alcotest.(check bool) "no generic recovery pending row" true (Q.is_empty pending)
   | Error detail -> Alcotest.failf "pending load failed: %s" detail);
  (match
     P.settle_exact_execution_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ~lease
       ~slot_id
       ~call_id:"different-call"
       ~plan_fingerprint
       ~request_body_sha256
       ~settlement
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "mismatched call id finalized a quarantined lease");
  (match
    P.settle_exact_execution_result
      ~base_path
      ~keeper_name
      ~settled_at:6.0
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~settlement
      ()
   with
   | Ok (P.Settled _ | P.Already_settled _ | P.Committed_followup_failed _) -> ()
   | Error detail -> Alcotest.failf "matching terminal finalization failed: %s" detail);
  match
    P.settle_exact_execution_result
      ~base_path
      ~keeper_name
      ~settled_at:7.0
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ~settlement
      ()
  with
  | Ok (P.Already_settled _) -> ()
  | Ok _ -> Alcotest.fail "matching receipt replay was not idempotent"
  | Error detail -> Alcotest.failf "matching receipt replay failed: %s" detail
;;

let test_cancellation_surfaces_only_after_terminal_settlement () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  with_temp_dir "masc-exact-lease-cancel" @@ fun base_path ->
  let keeper_name = "exact_cancel_guard" in
  let slot_id = "slot-cancel" in
  let call_id = "call-cancel" in
  let plan_fingerprint = "plan-cancel" in
  let request_body_sha256 = String.make 64 'c' in
  let lease, terminal =
    bind_and_quarantine
      ~base_path
      ~keeper_name
      ~cause:P.Execution_cancelled_after_dispatch
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  let settlement = terminal_settlement (source_ref ()) terminal in
  let context, resolve_context = Eio.Promise.create () in
  let entered, resolve_entered = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let result, resolve_result = Eio.Promise.create () in
  let committed = Atomic.make false in
  Eio.Fiber.fork ~sw (fun () ->
    let outcome =
      try
        Eio.Cancel.sub (fun cancel_context ->
          Eio.Promise.resolve resolve_context cancel_context;
          Eio.Cancel.protect (fun () ->
            Eio.Promise.resolve resolve_entered ();
            Eio.Promise.await release;
            match
              P.settle_exact_execution_result
                ~base_path
                ~keeper_name
                ~settled_at:7.0
                ~lease
                ~slot_id
                ~call_id
                ~plan_fingerprint
                ~request_body_sha256
                ~settlement
                ()
            with
            | Ok (P.Settled _ | P.Already_settled _ | P.Committed_followup_failed _) ->
              Atomic.set committed true
            | Error detail -> failwith detail);
          Keeper_heartbeat_loop.For_testing.check_cancellation_after_exact_terminal_settlement
            settlement;
          Returned)
      with
      | Eio.Cancel.Cancelled _ -> Cancellation_observed
      | exn -> Raised (Printexc.to_string exn)
    in
    Eio.Promise.resolve resolve_result outcome);
  let cancel_context = Eio.Promise.await context in
  Eio.Promise.await entered;
  Eio.Cancel.cancel cancel_context Exit;
  Eio.Fiber.yield ();
  Alcotest.(check bool) "settlement is still protected" false (Atomic.get committed);
  Eio.Promise.resolve resolve_release ();
  (match Eio.Promise.await result with
   | Cancellation_observed -> ()
   | Returned -> Alcotest.fail "post-settlement cancellation check did not propagate"
   | Raised detail -> Alcotest.failf "cancellation proof raised: %s" detail);
  Alcotest.(check bool) "terminal settlement committed first" true (Atomic.get committed);
  match P.prepare_registration_result ~base_path ~keeper_name ~settled_at:8.0 () with
  | Ok pending -> Alcotest.(check bool) "settled cancellation never requeues" true (Q.is_empty pending)
  | Error detail -> Alcotest.failf "post-terminal registration failed: %s" detail
;;

let () =
  Alcotest.run
    "exact execution lease guard"
    [ ( "dispatch fence"
      , [ Alcotest.test_case
            "bind crash remains blocked across restart"
            `Quick
            test_bind_crash_restart_remains_blocked
        ; Alcotest.test_case
            "Before_dispatch release permits registration replay"
            `Quick
            test_before_dispatch_release_allows_registration_requeue
        ; Alcotest.test_case
            "conflicting concurrent bind has one winner"
            `Quick
            test_conflicting_concurrent_bind_has_single_winner
        ] )
    ; ( "restart"
      , [ Alcotest.test_case
            "settlement persistence failure remains quarantined across registration"
            `Quick
            test_restart_recovery_never_requeues_bound_lease
        ] )
    ; ( "cancellation"
      , [ Alcotest.test_case
            "cancellation surfaces only after terminal settlement"
            `Quick
            test_cancellation_surfaces_only_after_terminal_settlement
        ] )
    ]
;;
