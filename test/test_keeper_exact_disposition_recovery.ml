module State = Keeper_event_queue_state

let require_ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let checkpoint_ref ~sha =
  let trace_id =
    Keeper_id.Trace_id.of_string "exact-disposition-recovery-trace"
    |> require_ok
  in
  match
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~generation:4
      ~turn_count:12
      ~sha256:sha
  with
  | Ok reference -> reference
  | Error _ -> Alcotest.fail "invalid checkpoint fixture"
;;

let source_ref = checkpoint_ref ~sha:(String.make 64 '0')
let target_ref = checkpoint_ref ~sha:(String.make 64 '1')
let foreign_ref = checkpoint_ref ~sha:(String.make 64 '2')

let stimulus post_id arrived_at =
  { Keeper_event_queue.post_id
  ; urgency = Keeper_event_queue.Immediate
  ; arrived_at
  ; payload = Keeper_event_queue.Manual_compaction_requested
  }
;;

let claimed_state ?(post_id = "manual-exact") () =
  let pending =
    Keeper_event_queue.enqueue
      Keeper_event_queue.empty
      (stimulus post_id 1.0)
  in
  let state = State.with_pending pending State.empty in
  let state, lease =
    State.claim_when ~claimed_at:2.0 ~ready:(fun _ -> true) state
    |> require_ok
  in
  match lease with
  | Some lease -> state, lease
  | None -> Alcotest.fail "fixture lease was not claimed"
;;

let bound_state ?post_id () =
  let state, lease = claimed_state ?post_id () in
  let state =
    State.bind_exact_execution
      ~lease
      ~slot_id:"slot-a"
      ~call_id:"call-a"
      ~plan_fingerprint:"plan-a"
      ~request_body_sha256:(String.make 64 'a')
      state
    |> require_ok
  in
  state, lease
;;

let prepare_terminal state lease =
  State.prepare_exact_source_disposition
    ~lease
    ~source:source_ref
    ~outcome:(State.Terminal State.Domain_invalid_output)
    ~action:State.Consume_source
    ~prepared_at:3.0
    ~slot_id:"slot-a"
    ~call_id:"call-a"
    ~plan_fingerprint:"plan-a"
    ~request_body_sha256:(String.make 64 'a')
    state
  |> require_ok
;;

let test_terminal_wal_replay_retains_full_proof () =
  let state, lease = bound_state () in
  let prepared, disposition = prepare_terminal state lease in
  let finalized, result =
    State.finalize_exact_source_disposition
      ~settled_at:4.0
      ~lease
      ~disposition_id:disposition.disposition_id
      prepared
    |> require_ok
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | Already_settled _ -> Alcotest.fail "first finalization was replayed"
  in
  Alcotest.(check string)
    "deterministic exact transition"
    (lease.lease_id ^ ":settle_exact:" ^ disposition.disposition_id)
    receipt.transition_id;
  let entry =
    match State.transition_outbox finalized with
    | [ entry ] -> entry
    | [] | _ :: _ :: _ -> Alcotest.fail "exact settlement outbox is not singular"
  in
  (match entry.receipt.settlement with
   | State.Settle_exact proof ->
     Alcotest.(check string)
       "request proof retained"
       disposition.request_body_sha256
       proof.request_body_sha256;
     Alcotest.(check string)
       "plan proof retained"
       disposition.plan_fingerprint
       proof.plan_fingerprint
   | _ -> Alcotest.fail "WAL did not carry Settle_exact");
  let replayed =
    State.replay_transition_outbox_entry entry prepared |> require_ok
  in
  Alcotest.(check int) "replay consumed lease" 0 (List.length (State.leases replayed));
  let _, replay_result =
    State.finalize_exact_source_disposition
      ~settled_at:4.0
      ~lease
      ~disposition_id:disposition.disposition_id
      finalized
    |> require_ok
  in
  (match replay_result with
   | State.Already_settled replayed_receipt ->
     Alcotest.(check string)
       "same receipt"
       receipt.transition_id
       replayed_receipt.transition_id
   | Settled _ -> Alcotest.fail "repeated finalization was applied twice")
;;

let replace_assoc key value fields =
  (key, value) :: List.remove_assoc key fields
;;

let corrupt_disposition_proof = function
  | `Assoc state_fields ->
    let bindings =
      match List.assoc "exact_execution_bindings" state_fields with
      | `List [ `Assoc binding_fields ] ->
        let disposition =
          match List.assoc "disposition" binding_fields with
          | `Assoc fields ->
            `Assoc
              (replace_assoc
                 "request_body_sha256"
                 (`String (String.make 64 'f'))
                 fields)
          | _ -> Alcotest.fail "fixture disposition missing"
        in
        `List
          [ `Assoc
              (replace_assoc "disposition" disposition binding_fields)
          ]
      | _ -> Alcotest.fail "fixture binding missing"
    in
    `Assoc
      (replace_assoc "exact_execution_bindings" bindings state_fields)
  | _ -> Alcotest.fail "fixture state is not an object"
;;

let test_wrong_full_proof_is_rejected () =
  let state, lease = bound_state () in
  let prepared, _ = prepare_terminal state lease in
  match State.of_yojson (corrupt_disposition_proof (State.to_yojson prepared)) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "changed request proof retained the disposition id"
;;

let legacy_v4_json = function
  | `Assoc state_fields ->
    let bindings =
      match List.assoc "exact_execution_bindings" state_fields with
      | `List rows ->
        `List
          (List.map
             (function
               | `Assoc fields ->
                 `Assoc (List.remove_assoc "disposition" fields)
               | row -> row)
             rows)
      | value -> value
    in
    `Assoc
      (state_fields
       |> replace_assoc "schema" (`String "keeper.event_queue.state.v4")
       |> replace_assoc "exact_execution_bindings" bindings)
  | json -> json
;;

let test_v4_cause_only_remains_fail_closed () =
  let state, lease = bound_state () in
  let terminal : State.exact_execution_terminal =
    { cause = State.Domain_invalid_output
    ; slot_id = "slot-a"
    ; call_id = "call-a"
    }
  in
  let quarantined =
    State.quarantine_exact_execution
      ~lease
      ~terminal
      ~plan_fingerprint:"plan-a"
      ~request_body_sha256:(String.make 64 'a')
      state
    |> require_ok
  in
  let migrated =
    State.of_yojson (legacy_v4_json (State.to_yojson quarantined))
    |> require_ok
  in
  (match State.exact_execution_binding migrated with
   | Some { status = State.Terminal_quarantined State.Domain_invalid_output; _ } ->
     ()
   | _ -> Alcotest.fail "v4 cause-only binding was synthesized");
  (match State.recover_leases ~settled_at:5.0 migrated with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "generic registration recovered a cause-only exact lease")
;;

let test_checkpoint_reconciliation_and_resume_once () =
  let state, lease = bound_state ~post_id:"checkpoint-exact" () in
  let prepared, disposition =
    State.prepare_exact_source_disposition
      ~lease
      ~source:source_ref
      ~outcome:(State.Checkpoint_committed { intended_ref = target_ref })
      ~action:State.Resume_source
      ~prepared_at:6.0
      ~slot_id:"slot-a"
      ~call_id:"call-a"
      ~plan_fingerprint:"plan-a"
      ~request_body_sha256:(String.make 64 'a')
      state
    |> require_ok
  in
  (match
     State.observe_exact_checkpoint_commit
       ~lease
       ~disposition_id:disposition.disposition_id
       ~current_ref:source_ref
       prepared
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "source ref was inferred as installed");
  (match
     State.observe_exact_checkpoint_commit
       ~lease
       ~disposition_id:disposition.disposition_id
       ~current_ref:foreign_ref
       prepared
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "foreign ref was inferred as installed");
  let observed =
    State.observe_exact_checkpoint_commit
      ~lease
      ~disposition_id:disposition.disposition_id
      ~current_ref:target_ref
      prepared
    |> require_ok
  in
  let finalized, result =
    State.finalize_exact_source_disposition
      ~settled_at:7.0
      ~lease
      ~disposition_id:disposition.disposition_id
      observed
    |> require_ok
  in
  Alcotest.(check int)
    "source resumed once"
    1
    (Keeper_event_queue.length (State.pending finalized));
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | Already_settled _ -> Alcotest.fail "checkpoint finalization replayed early"
  in
  let projected =
    State.mark_transition_projected
      ~transition_id:receipt.transition_id
      finalized
    |> require_ok
  in
  let claimed, unrelated =
    State.claim_when ~claimed_at:8.0 ~ready:(fun _ -> true) projected
    |> require_ok
  in
  ignore claimed;
  (match unrelated with
   | Some _ -> ()
   | None -> Alcotest.fail "resumed source did not remain runnable")
;;

let () =
  Alcotest.run
    "keeper exact disposition recovery"
    [ ( "recovery"
      , [ Alcotest.test_case
            "terminal WAL replay retains full proof"
            `Quick
            test_terminal_wal_replay_retains_full_proof
        ; Alcotest.test_case
            "wrong full proof is rejected"
            `Quick
            test_wrong_full_proof_is_rejected
        ; Alcotest.test_case
            "v4 cause-only remains fail-closed"
            `Quick
            test_v4_cause_only_remains_fail_closed
        ; Alcotest.test_case
            "checkpoint target reconciles and resumes once"
            `Quick
            test_checkpoint_reconciliation_and_resume_once
        ] )
    ]
;;
