include Test_keeper_exact_execution_lease_guard_fixture

module State = Keeper_event_queue_state

let settlement_wal_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue-settlements.jsonl"
;;

let snapshot_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
    "event-queue.json"
;;

let read_file_or_fail label path =
  match Safe_ops.read_file_safe path with
  | Ok bytes -> bytes
  | Error detail -> Alcotest.failf "%s read failed: %s" label detail
;;

let decode_raw_snapshot label ~base_path ~keeper_name =
  let path = snapshot_path ~base_path ~keeper_name in
  let json =
    try Yojson.Safe.from_string (read_file_or_fail label path) with
    | Yojson.Json_error detail ->
      Alcotest.failf "%s raw snapshot JSON failed: %s" label detail
  in
  match State.of_yojson json with
  | Ok state -> state
  | Error detail -> Alcotest.failf "%s raw current-state decode failed: %s" label detail
;;

let require_loaded_state label ~base_path ~keeper_name =
  match P.load_state_result ~base_path ~keeper_name with
  | Ok state -> state
  | Error detail -> Alcotest.failf "%s state load failed: %s" label detail
;;

let check_no_active_lease label state =
  Alcotest.(check bool) (label ^ " has no active lease") true (Option.is_none (State.active_lease state))
;;

let check_no_exact_binding label state =
  Alcotest.(check bool)
    (label ^ " has no exact binding")
    true
    (Option.is_none (State.exact_execution_binding state))
;;

let check_no_pending label state =
  Alcotest.(check bool)
    (label ^ " has no pending stimuli")
    true
    (Q.is_empty (State.pending state))
;;

let state_json state = State.to_yojson state |> Yojson.Safe.to_string

let check_same_state label expected actual =
  Alcotest.(check string) label (state_json expected) (state_json actual)
;;

let require_single_exact_outbox ?disposition_id label state =
  match State.transition_outbox state with
  | [ entry ] ->
    (match entry.receipt.settlement with
     | P.Settle_exact disposition ->
       (match disposition_id with
        | None -> ()
        | Some expected ->
          Alcotest.(check string)
            (label ^ " disposition")
            expected
            disposition.disposition_id);
       entry.receipt
     | _ -> Alcotest.failf "%s outbox settlement was not Settle_exact" label)
  | entries ->
    Alcotest.failf "%s expected one outbox entry, got %d" label (List.length entries)
;;

let check_single_v2_wal_row label bytes =
  let rows =
    String.split_on_char '\n' bytes
    |> List.filter (fun row -> not (String.equal row ""))
  in
  match rows with
  | [ row ] ->
    let schema =
      Yojson.Safe.from_string row
      |> Yojson.Safe.Util.member "schema"
      |> Yojson.Safe.Util.to_string
    in
    Alcotest.(check string)
      (label ^ " WAL schema")
      "masc.keeper_event_queue.settlement.v2"
      schema
  | _ -> Alcotest.failf "%s expected one durable WAL row, got %d" label (List.length rows)
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
   | Ok P.Fsync_completed -> ()
   | Ok (P.Visible_sync_unconfirmed detail) ->
     Alcotest.failf "before-dispatch release durability unknown: %s" detail
   | Error detail -> Alcotest.failf "before-dispatch release failed: %s" detail);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "before-dispatch release retained the binding"
   | Error detail -> Alcotest.failf "released binding load failed: %s" detail);
  let terminal : P.exact_execution_terminal =
    { cause = P.Execution_failed_after_dispatch
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    }
  in
  (match
     P.prepare_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~lease
       ~source:(source_ref ())
       ~terminal
       ~semantic:P.Exact_no_compaction
       ~prepared_at:3.0
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
    | Ok P.Fsync_completed, Error _ -> call_a, plan_a, request_a
    | Error _, Ok P.Fsync_completed -> call_b, plan_b, request_b
    | Ok P.Fsync_completed, Ok P.Fsync_completed ->
      Alcotest.fail "conflicting exact binds both succeeded"
    | Ok (P.Visible_sync_unconfirmed detail), _
    | _, Ok (P.Visible_sync_unconfirmed detail) ->
      Alcotest.failf "concurrent exact bind durability unknown: %s" detail
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
  let disposition =
    prepare_terminal_disposition
      ~base_path
      ~keeper_name
      ~lease
      ~terminal
      ~prepared_at:3.0
  in
  let wal_path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      "event-queue-settlements.jsonl"
  in
  Unix.mkdir wal_path 0o700;
  (match
     P.finalize_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "poisoned WAL unexpectedly committed settlement");
  Unix.rmdir wal_path;
  check_prepared_binding
    ~base_path
    ~keeper_name
    ~disposition_id:disposition.disposition_id;
  (match
     P.prepare_registration_after_exact_recovery_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ()
   with
   | Ok pending ->
     Alcotest.(check bool) "terminal recovery created no replay" true (Q.is_empty pending)
   | Error detail -> Alcotest.failf "prepared terminal recovery failed: %s" detail);
  (match P.exact_execution_binding_result ~base_path ~keeper_name with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "terminal recovery retained the exact binding"
   | Error detail -> Alcotest.failf "recovered binding load failed: %s" detail);
  (match P.load_pending_result ~base_path ~keeper_name with
   | Ok pending -> Alcotest.(check bool) "no generic recovery pending row" true (Q.is_empty pending)
   | Error detail -> Alcotest.failf "pending load failed: %s" detail);
  (match
     P.finalize_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~settled_at:6.0
       ~lease
       ~disposition_id:"different-disposition"
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "mismatched disposition replay was accepted");
  (match
    P.finalize_exact_source_disposition_result
      ~base_path
      ~keeper_name
      ~settled_at:7.0
      ~lease
      ~disposition_id:disposition.disposition_id
      ()
   with
   | Ok (P.Already_settled _) -> ()
   | Ok _ -> Alcotest.fail "matching receipt replay was not idempotent"
   | Error detail -> Alcotest.failf "matching receipt replay failed: %s" detail)
;;

let test_failure_judgment_settles_exact_execution_atomically () =
  with_temp_dir "masc-exact-failure-judgment" @@ fun base_path ->
  let keeper_name = "exact_failure_judgment" in
  let slot_id = "slot-failure-judgment" in
  let call_id = "call-failure-judgment" in
  let plan_fingerprint = "plan-failure-judgment" in
  let request_body_sha256 = String.make 64 '1' in
  let lease = claim_manual_lease ~base_path ~keeper_name in
  bind_exact_execution
    ~base_path
    ~keeper_name
    ~lease
    ~slot_id
    ~call_id
    ~plan_fingerprint
    ~request_body_sha256;
  let judgment : Q.failure_judgment =
    { fj_runtime_id = "runtime-failure-judgment"
    ; fj_judgment = Keeper_runtime_failure_route.Contract_violation
    ; fj_provenance = Keeper_runtime_failure_route.Oas_agent_error
    ; fj_detail = "post-compaction contract failure"
    }
  in
  let successor : Q.stimulus =
    { post_id = Q.failure_judgment_post_id judgment
    ; urgency = Q.Immediate
    ; arrived_at = 3.0
    ; payload = Q.Failure_judgment judgment
    }
  in
  let settlement : P.settlement =
    P.Escalate
      { reason = P.Failure_judgment_requested
      ; successor = Some successor
      }
  in
  let check_settled_state label =
    (match P.exact_execution_binding_result ~base_path ~keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.failf "%s retained the exact execution binding" label
     | Error detail -> Alcotest.failf "%s binding load failed: %s" label detail);
    (match P.active_lease_result ~base_path ~keeper_name with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.failf "%s retained the source lease" label
     | Error detail -> Alcotest.failf "%s active lease load failed: %s" label detail);
    match P.load_pending_result ~base_path ~keeper_name with
    | Ok pending ->
      (match Q.to_list pending with
       | [ { post_id; payload = Q.Failure_judgment actual; _ } ] ->
         Alcotest.(check string)
           (label ^ " enqueued the expected successor")
           successor.post_id
           post_id;
         Alcotest.(check string)
           (label ^ " retained the judgment runtime")
           judgment.fj_runtime_id
           actual.fj_runtime_id
       | _ ->
         Alcotest.failf
           "%s did not leave exactly one typed failure-judgment successor"
           label)
    | Error detail -> Alcotest.failf "%s pending load failed: %s" label detail
  in
  (match
     P.settle_bound_exact_nonterminal_result
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
   | Ok (P.Settled _) -> ()
   | Ok _ -> Alcotest.fail "failure judgment did not commit as the first settlement"
   | Error detail -> Alcotest.failf "failure judgment settlement failed: %s" detail);
  check_settled_state "first settlement";
  (match
     P.settle_bound_exact_nonterminal_result
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ~lease
       ~slot_id
       ~call_id
       ~plan_fingerprint
       ~request_body_sha256
       ~settlement
       ()
   with
   | Ok (P.Already_settled _) -> ()
   | Ok _ -> Alcotest.fail "failure judgment receipt replay was not idempotent"
   | Error detail -> Alcotest.failf "failure judgment receipt replay failed: %s" detail);
  check_settled_state "receipt replay"
;;

let run_exact_wal_followup_replay_case ~label ~failure ~expected_stage =
  with_temp_dir ("masc-exact-wal-" ^ label) @@ fun base_path ->
  let keeper_name = "exact_wal_" ^ label in
  let slot_id = "slot-wal-" ^ label in
  let call_id = "call-wal-" ^ label in
  let plan_fingerprint = "plan-wal-" ^ label in
  let request_body_sha256 = String.make 64 '2' in
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
  let disposition =
    prepare_terminal_disposition
      ~base_path
      ~keeper_name
      ~lease
      ~terminal
      ~prepared_at:3.0
  in
  let precommit =
    decode_raw_snapshot (label ^ " precommit") ~base_path ~keeper_name
  in
  (match
     P.For_testing.finalize_exact_source_disposition_with_followup_failure_result
       ~failure
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Ok (P.Committed_followup_failed { stage; _ }) ->
     Alcotest.(check bool)
       (label ^ " reports the injected committed stage")
       true
       (stage = expected_stage)
   | Ok _ -> Alcotest.failf "%s did not report a committed follow-up failure" label
   | Error detail -> Alcotest.failf "%s lost the durable WAL commit: %s" label detail);
  let wal_path = settlement_wal_path ~base_path ~keeper_name in
  check_single_v2_wal_row label (read_file_or_fail label wal_path);
  let before_replay =
    decode_raw_snapshot (label ^ " before replay") ~base_path ~keeper_name
  in
  (match failure with
   | P.For_testing.Fail_checkpoint _ ->
     Alcotest.(check string)
       (label ^ " checkpoint failure preserves precommit revision")
       (Int64.to_string (State.revision precommit))
       (Int64.to_string (State.revision before_replay));
     check_same_state
       (label ^ " checkpoint failure preserves the prepared snapshot")
       precommit
       before_replay;
     (match State.exact_execution_binding before_replay with
      | Some { status = P.Disposition_prepared prepared; _ }
        when String.equal prepared.disposition_id disposition.disposition_id ->
        ()
      | Some _ ->
        Alcotest.failf "%s checkpoint failure lost the prepared disposition" label
      | None ->
        Alcotest.failf "%s checkpoint failure removed the exact binding" label)
   | P.For_testing.Fail_wal_compaction _ ->
     Alcotest.(check string)
       (label ^ " compaction failure retains the committed revision")
       (Int64.to_string (Int64.succ (State.revision precommit)))
       (Int64.to_string (State.revision before_replay));
     check_no_active_lease (label ^ " committed snapshot") before_replay;
     check_no_exact_binding (label ^ " committed snapshot") before_replay;
     check_no_pending (label ^ " committed snapshot") before_replay;
     ignore
       (require_single_exact_outbox
          ~disposition_id:disposition.disposition_id
          (label ^ " committed snapshot")
          before_replay));
  let recovered = require_loaded_state (label ^ " first restart") ~base_path ~keeper_name in
  check_no_active_lease (label ^ " first restart") recovered;
  check_no_exact_binding (label ^ " first restart") recovered;
  check_no_pending (label ^ " first restart") recovered;
  let receipt =
    require_single_exact_outbox
      ~disposition_id:disposition.disposition_id
      (label ^ " first restart")
      recovered
  in
  Alcotest.(check string)
    (label ^ " WAL compacted after replay")
    ""
    (read_file_or_fail label wal_path);
  let loaded_again =
    require_loaded_state (label ^ " second restart") ~base_path ~keeper_name
  in
  check_same_state (label ^ " second load is idempotent") recovered loaded_again;
  (match
     P.finalize_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Ok (P.Already_settled replayed) ->
     Alcotest.(check bool)
       (label ^ " old finalize returns the canonical receipt")
       true
       (State.transition_receipt_equal receipt replayed)
   | Ok _ -> Alcotest.failf "%s old finalize was not idempotent" label
   | Error detail -> Alcotest.failf "%s old finalize retry failed: %s" label detail);
  let after_retry =
    require_loaded_state (label ^ " post-retry load") ~base_path ~keeper_name
  in
  check_same_state (label ^ " old retry leaves state unchanged") loaded_again after_retry
;;

let test_exact_wal_followup_failures_replay_once () =
  run_exact_wal_followup_replay_case
    ~label:"checkpoint"
    ~failure:(P.For_testing.Fail_checkpoint "injected checkpoint failure")
    ~expected_stage:`Checkpoint;
  run_exact_wal_followup_replay_case
    ~label:"compaction"
    ~failure:(P.For_testing.Fail_wal_compaction "injected WAL compaction failure")
    ~expected_stage:`Wal_compaction
;;

let test_visible_prepare_sync_failure_recovers_once () =
  with_temp_dir "masc-exact-visible-prepare" @@ fun base_path ->
  let keeper_name = "exact_visible_prepare" in
  let slot_id = "slot-visible-prepare" in
  let call_id = "call-visible-prepare" in
  let plan_fingerprint = "plan-visible-prepare" in
  let request_body_sha256 = String.make 64 '3' in
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
  let disposition =
    match
      P.For_testing.prepare_exact_source_disposition_with_sync_parent_result
        ~sync_parent:(fun _ -> raise (Failure "injected parent sync failure"))
        ~base_path
        ~keeper_name
        ~lease
        ~source:(source_ref ())
        ~terminal
        ~semantic:P.Exact_no_compaction
        ~prepared_at:3.0
        ()
    with
    | Ok (disposition, P.Visible_sync_unconfirmed _) -> disposition
    | Ok (_, P.Fsync_completed) ->
      Alcotest.fail "injected post-rename parent sync failure was not observed"
    | Error detail ->
      Alcotest.failf "visible exact disposition was misclassified as absent: %s" detail
  in
  (match
     P.prepare_registration_after_exact_recovery_result
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ()
   with
   | Ok pending ->
     Alcotest.(check bool) "visible prepare recovery creates no replay" true (Q.is_empty pending)
   | Error detail -> Alcotest.failf "visible prepare restart recovery failed: %s" detail);
  let recovered = require_loaded_state "visible prepare first restart" ~base_path ~keeper_name in
  check_no_active_lease "visible prepare first restart" recovered;
  check_no_exact_binding "visible prepare first restart" recovered;
  check_no_pending "visible prepare first restart" recovered;
  let receipt =
    require_single_exact_outbox
      ~disposition_id:disposition.disposition_id
      "visible prepare first restart"
      recovered
  in
  (match
     P.prepare_registration_after_exact_recovery_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ()
   with
   | Ok pending ->
     Alcotest.(check bool) "second visible prepare recovery creates no replay" true (Q.is_empty pending)
   | Error detail -> Alcotest.failf "second visible prepare recovery failed: %s" detail);
  let loaded_again =
    require_loaded_state "visible prepare second restart" ~base_path ~keeper_name
  in
  check_same_state "visible prepare recovery is idempotent" recovered loaded_again;
  (match
     P.finalize_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~settled_at:6.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Ok (P.Already_settled replayed) ->
     Alcotest.(check bool)
       "visible prepare old retry returns canonical receipt"
       true
       (State.transition_receipt_equal receipt replayed)
   | Ok _ -> Alcotest.fail "visible prepare old retry was not idempotent"
   | Error detail -> Alcotest.failf "visible prepare old retry failed: %s" detail)
;;

let test_stale_finalize_preserves_active_successor () =
  with_temp_dir "masc-exact-stale-finalize" @@ fun base_path ->
  let keeper_name = "exact_stale_finalize" in
  let lease, terminal =
    bind_and_quarantine
      ~base_path
      ~keeper_name
      ~cause:P.Execution_failed_after_dispatch
      ~slot_id:"slot-stale"
      ~call_id:"call-stale"
      ~plan_fingerprint:"plan-stale"
      ~request_body_sha256:(String.make 64 '4')
  in
  let disposition =
    prepare_terminal_disposition
      ~base_path
      ~keeper_name
      ~lease
      ~terminal
      ~prepared_at:3.0
  in
  (match
     P.For_testing.finalize_exact_source_disposition_with_followup_failure_result
       ~failure:(P.For_testing.Fail_checkpoint "injected stale-owner checkpoint failure")
       ~base_path
       ~keeper_name
       ~settled_at:4.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Ok (P.Committed_followup_failed { stage = `Checkpoint; _ }) -> ()
   | Ok _ -> Alcotest.fail "stale-owner setup did not stop after WAL commit"
   | Error detail -> Alcotest.failf "stale-owner WAL commit failed: %s" detail);
  let recovered = require_loaded_state "stale-owner restart" ~base_path ~keeper_name in
  let receipt =
    require_single_exact_outbox
      ~disposition_id:disposition.disposition_id
      "stale-owner restart"
      recovered
  in
  (match
     P.mark_transition_projected_result
       ~base_path
       ~keeper_name
       ~transition_id:receipt.transition_id
   with
   | Ok () -> ()
  | Error detail -> Alcotest.failf "stale-owner outbox projection failed: %s" detail);
  let successor = claim_manual_lease ~base_path ~keeper_name in
  let before_retry =
    require_loaded_state "stale finalize before retry" ~base_path ~keeper_name
  in
  (match State.active_lease before_retry with
   | Some active ->
     Alcotest.(check string)
       "stale finalize starts with successor lease id"
       successor.lease_id
       active.lease_id;
     Alcotest.(check string)
       "stale finalize starts with successor lease sequence"
       (Int64.to_string successor.sequence)
       (Int64.to_string active.sequence)
   | None -> Alcotest.fail "stale finalize setup lost the active successor lease");
  check_no_exact_binding "stale finalize before retry" before_retry;
  check_no_pending "stale finalize before retry" before_retry;
  Alcotest.(check int)
    "stale finalize starts without outbox work"
    0
    (List.length (State.transition_outbox before_retry));
  (match
     P.finalize_exact_source_disposition_result
       ~base_path
       ~keeper_name
       ~settled_at:5.0
       ~lease
       ~disposition_id:disposition.disposition_id
       ()
   with
   | Ok (P.Already_settled replayed) ->
     Alcotest.(check bool)
       "stale finalize retains the original receipt"
       true
       (State.transition_receipt_equal receipt replayed)
   | Ok _ -> Alcotest.fail "stale finalize committed a second transition"
   | Error detail -> Alcotest.failf "stale finalize retry failed: %s" detail);
  let after_retry =
    require_loaded_state "stale finalize post-retry" ~base_path ~keeper_name
  in
  Alcotest.(check string)
    "stale finalize preserves the successor revision"
    (Int64.to_string (State.revision before_retry))
    (Int64.to_string (State.revision after_retry));
  check_same_state
    "stale finalize leaves the adjacent full state unchanged"
    before_retry
    after_retry;
  (match State.active_lease after_retry with
   | Some active ->
     Alcotest.(check string)
       "stale finalize preserves successor lease id"
       successor.lease_id
       active.lease_id;
     Alcotest.(check string)
       "stale finalize preserves successor lease sequence"
       (Int64.to_string successor.sequence)
       (Int64.to_string active.sequence)
   | None -> Alcotest.fail "stale finalize removed the active successor lease");
  check_no_exact_binding "stale finalize after retry" after_retry;
  check_no_pending "stale finalize after retry" after_retry;
  Alcotest.(check int)
    "stale finalize creates no successor outbox mutation"
    0
    (List.length (State.transition_outbox after_retry))
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
  let settlement : P.settlement =
    P.No_compaction
      { source = source_ref ()
      ; reason = P.Exact_execution_terminal terminal
      }
  in
  let progress, resolve_progress = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let result, resolve_result = Eio.Promise.create () in
  let finalized = Atomic.make false in
  let prepare_entered = Atomic.make false in
  let progress_resolved = Atomic.make false in
  let release_resolved = Atomic.make false in
  let resolve_progress_once progress =
    if Atomic.compare_and_set progress_resolved false true
    then Eio.Promise.resolve resolve_progress progress
  in
  let resolve_release_once () =
    if Atomic.compare_and_set release_resolved false true
    then Eio.Promise.resolve resolve_release ()
  in
  Eio.Fiber.fork ~sw (fun () ->
    let outcome =
      try
        Eio.Cancel.sub (fun cancel_context ->
          (match
             Masc.Keeper_heartbeat_loop.For_testing.settle_claimed_lease_exact
               ~after_exact_disposition_prepare:(fun () ->
                 Atomic.set prepare_entered true;
                 resolve_progress_once (`Prepare_entered cancel_context);
                 Eio.Promise.await release)
               ~base_path
               ~keeper_name
               ~settled_at:7.0
               ~lease
               ~settlement
               ()
           with
           | Ok
               ( Keeper_registry_event_queue.Settled _
               | Keeper_registry_event_queue.Already_settled _ ) ->
             Atomic.set finalized true
           | Ok (Keeper_registry_event_queue.Committed_followup_failed { detail; _ }) ->
             failwith detail
           | Error detail -> failwith detail);
          Masc.Keeper_heartbeat_loop.For_testing.check_cancellation_after_exact_terminal_settlement
            settlement;
          Returned)
      with
      | Eio.Cancel.Cancelled _ -> Cancellation_observed
      | exn -> Raised (Printexc.to_string exn)
    in
    if not (Atomic.get prepare_entered)
    then resolve_progress_once (`Worker_finished outcome);
    Eio.Promise.resolve resolve_result outcome);
  let worker_finished_early =
    Fun.protect
      ~finally:resolve_release_once
      (fun () ->
         match Eio.Promise.await progress with
         | `Worker_finished outcome -> Some outcome
         | `Prepare_entered cancel_context ->
           Eio.Cancel.cancel cancel_context Exit;
           Alcotest.(check bool)
             "settlement is still protected"
             false
             (Atomic.get finalized);
           (match P.exact_execution_binding_result ~base_path ~keeper_name with
            | Ok (Some { status = P.Disposition_prepared _; _ }) -> ()
            | Ok _ ->
              Alcotest.fail "cancellation barrier was not after durable prepare"
            | Error detail ->
              Alcotest.failf
                "prepared cancellation binding load failed: %s"
                detail);
           None)
  in
  Alcotest.(check bool)
    "release resolver settled exactly once"
    true
    (Atomic.get release_resolved);
  (match worker_finished_early with
   | None -> ()
   | Some Cancellation_observed ->
     Alcotest.fail "worker observed cancellation before durable prepare"
   | Some Returned -> Alcotest.fail "worker returned before durable prepare"
   | Some (Raised detail) ->
     Alcotest.failf "worker failed before durable prepare: %s" detail);
  (match Eio.Promise.await result with
   | Cancellation_observed -> ()
   | Returned -> Alcotest.fail "post-settlement cancellation check did not propagate"
   | Raised detail -> Alcotest.failf "cancellation proof raised: %s" detail);
  Alcotest.(check bool) "terminal settlement finalized first" true (Atomic.get finalized);
  let state = require_loaded_state "post-cancellation finalization" ~base_path ~keeper_name in
  check_no_active_lease "post-cancellation finalization" state;
  check_no_exact_binding "post-cancellation finalization" state;
  check_no_pending "post-cancellation finalization" state;
  ignore (require_single_exact_outbox "post-cancellation finalization" state);
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
        ; Alcotest.test_case
            "failure judgment settles exact execution atomically"
            `Quick
            test_failure_judgment_settles_exact_execution_atomically
        ; Alcotest.test_case
            "Settle_exact WAL follow-up failures replay once"
            `Quick
            test_exact_wal_followup_failures_replay_once
        ; Alcotest.test_case
            "visible prepare sync failure recovers once"
            `Quick
            test_visible_prepare_sync_failure_recovers_once
        ; Alcotest.test_case
            "stale finalize preserves active successor"
            `Quick
            test_stale_finalize_preserves_active_successor
        ] )
    ; ( "cancellation"
      , [ Alcotest.test_case
            "cancellation surfaces only after terminal settlement"
            `Quick
            test_cancellation_surfaces_only_after_terminal_settlement
        ] )
    ]
;;
