module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence

let require_ok label = function
  | Ok value -> value
  | Error message -> Alcotest.failf "%s: %s" label message
;;

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s: expected Some" label
;;

let stimulus ?(payload = Queue.Bootstrap) post_id arrived_at : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at; payload }
;;

let queue stimuli = List.fold_left Queue.enqueue Queue.empty stimuli

let post_ids queue =
  Queue.to_list queue |> List.map (fun (stimulus : Queue.stimulus) -> stimulus.post_id)
;;

let claim_head state =
  State.claim_when ~claimed_at:10.0 ~ready:(fun _ -> true) state
  |> require_ok "claim head"
;;

let checkpoint_source ~turn_count =
  let trace_id =
    Keeper_id.Trace_id.of_string "trace-no-compaction-source"
    |> require_ok "parse no-compaction trace"
  in
  Keeper_checkpoint_ref.of_persisted
    ~trace_id
    ~generation:3
    ~turn_count
    ~sha256:(String.make 64 'a')
  |> Result.get_ok
;;

let no_compaction ~turn_count reason : State.no_compaction =
  { source = checkpoint_source ~turn_count; reason }
;;

let exact_terminal ?(slot_id = "slot-terminal") ?(call_id = "call-terminal") cause =
  State.Exact_execution_terminal { cause; slot_id; call_id }
;;

let test_exact_output_terminal_reasons_round_trip () =
  List.iter
    (fun (reason, label) ->
       Alcotest.(check string)
         "terminal reason label"
         label
         (State.no_compaction_reason_label reason);
       (match State.no_compaction_reason_of_label label with
        | Ok restored ->
          Alcotest.(check bool) "terminal reason typed round-trip" true
            (restored = reason)
        | Error detail -> Alcotest.failf "terminal reason decode failed: %s" detail);
       let settlement =
         State.No_compaction (no_compaction ~turn_count:7 reason)
       in
       let claimed, lease =
         State.with_pending
           (queue
              [ stimulus
                  ~payload:Queue.Manual_compaction_requested
                  Queue.manual_compaction_post_id
                  1.0
              ])
           State.empty
         |> claim_head
       in
       let lease = require_some "exact-output terminal lease" lease in
       let _, result =
         State.settle ~settled_at:11.0 ~lease ~settlement claimed
         |> require_ok "settle exact-output terminal"
       in
       let receipt =
         match result with
         | State.Settled receipt -> receipt
         | State.Already_settled _ ->
           Alcotest.fail "exact-output terminal was already settled"
       in
       let restored =
         State.transition_receipt_to_yojson receipt
         |> State.transition_receipt_of_yojson
         |> require_ok "exact-output terminal receipt round-trip"
       in
       Alcotest.(check bool)
         "terminal settlement survives public receipt codec"
         true
         (State.transition_receipt_equal receipt restored))
    [ State.Exact_lane_unconfigured, "exact_lane_unconfigured" ];
  List.iter
    (fun cause ->
       let reason = exact_terminal cause in
       let label = State.exact_execution_terminal_cause_label cause in
       Alcotest.(check string)
         "exact terminal cause label"
         label
         (State.no_compaction_reason_label reason);
       (match State.no_compaction_reason_of_label label with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "terminal reason decoded without call provenance");
       let claimed, lease =
         State.with_pending
           (queue
              [ stimulus
                  ~payload:Queue.Manual_compaction_requested
                  Queue.manual_compaction_post_id
                  1.0
              ])
           State.empty
         |> claim_head
       in
       let lease = require_some "exact terminal lease" lease in
       let _, settled =
         State.settle
           ~settled_at:11.0
           ~lease
           ~settlement:
             (State.No_compaction (no_compaction ~turn_count:7 reason))
           claimed
         |> require_ok "settle exact terminal"
       in
       let receipt =
         match settled with
         | State.Settled receipt -> receipt
         | State.Already_settled _ -> Alcotest.fail "exact terminal replayed"
       in
       let restored =
         State.transition_receipt_to_yojson receipt
         |> State.transition_receipt_of_yojson
         |> require_ok "exact terminal receipt round-trip"
       in
       Alcotest.(check bool)
         "exact terminal receipt retains call provenance"
         true
         (State.transition_receipt_equal receipt restored))
    [ State.Execution_failed_after_dispatch
    ; State.Attempt_already_started
    ; State.Execution_cancelled_after_dispatch
    ; State.Execution_provenance_mismatch
    ; State.Domain_invalid_output
    ; State.Invalid_structural_evidence
    ; State.Invalid_structural_source_after_dispatch
    ; State.Commit_admission_unavailable
    ; State.Lifecycle_transition_failed_after_dispatch
    ; State.Checkpoint_source_changed
    ; State.Checkpoint_persistence_failed
    ];
  (* Malformed structural evidence and planner invariant violations remain
     retryable/escalated and cannot be encoded as terminal no-compaction. *)
  List.iter
    (fun label ->
       match State.no_compaction_reason_of_label label with
       | Error _ -> ()
       | Ok _ ->
         Alcotest.failf
           "stochastic/invariant outcome %S encodable as terminal no-compaction"
           label)
    [ "invalid_compaction_plan"
    ; "compaction_invariant_violation"
    ]
;;

let test_exact_terminal_codec_rejects_missing_or_blank_call_identity () =
  let claimed, lease =
    State.with_pending
      (queue
         [ stimulus
             ~payload:Queue.Manual_compaction_requested
             Queue.manual_compaction_post_id
             1.0
         ])
      State.empty
    |> claim_head
  in
  let lease = require_some "closed exact terminal lease" lease in
  let _, settled =
    State.settle
      ~settled_at:2.0
      ~lease
      ~settlement:
        (State.No_compaction
           (no_compaction
              ~turn_count:7
              (exact_terminal State.Execution_cancelled_after_dispatch)))
      claimed
    |> require_ok "settle closed exact terminal"
  in
  let receipt =
    match settled with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "closed terminal was replayed"
  in
  let json = State.transition_receipt_to_yojson receipt in
  let map_settlement f =
    match json with
    | `Assoc receipt_fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "settlement"
              then name, f value
              else name, value)
           receipt_fields)
    | _ -> Alcotest.fail "receipt encoder returned a non-object"
  in
  let missing =
    map_settlement (function
      | `Assoc fields ->
        `Assoc (List.filter (fun (name, _) -> not (String.equal name "exact_execution")) fields)
      | _ -> Alcotest.fail "settlement encoder returned a non-object")
  in
  (match State.transition_receipt_of_yojson missing with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "terminal receipt decoded without exact execution");
  let blank =
    map_settlement (function
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (name, value) ->
                if String.equal name "exact_execution"
                then
                  name,
                  (match value with
                   | `Assoc exact_fields ->
                     `Assoc
                       (List.map
                          (fun (field, value) ->
                             if String.equal field "call_id"
                             then field, `String "   "
                             else field, value)
                          exact_fields)
                   | _ -> Alcotest.fail "exact execution encoder returned a non-object")
                else name, value)
             fields)
      | _ -> Alcotest.fail "settlement encoder returned a non-object")
  in
  match State.transition_receipt_of_yojson blank with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "terminal receipt decoded a blank call id"
;;

let test_cancelled_exact_terminal_consumes_queue_durably () =
  let request =
    stimulus
      ~payload:Queue.Manual_compaction_requested
      Queue.manual_compaction_post_id
      1.0
  in
  let claimed, lease =
    State.with_pending (queue [ request ]) State.empty |> claim_head
  in
  let lease = require_some "cancelled exact terminal lease" lease in
  let settled, _ =
    State.settle
      ~settled_at:2.0
      ~lease
      ~settlement:
        (State.No_compaction
           (no_compaction
              ~turn_count:7
              (exact_terminal
                 ~slot_id:"cancelled-slot"
                 ~call_id:"cancelled-call"
                 State.Execution_cancelled_after_dispatch)))
      claimed
    |> require_ok "settle cancelled exact terminal"
  in
  let restored =
    State.to_yojson settled
    |> State.of_yojson
    |> require_ok "cancelled exact terminal durable round-trip"
  in
  Alcotest.(check (list string)) "cancelled terminal leaves queue empty" []
    (post_ids (State.pending restored));
  Alcotest.(check int) "cancelled terminal leaves no active lease" 0
    (List.length (State.leases restored))
;;

let test_no_compaction_terminal_consumes_exact_request () =
  let request =
    stimulus
      ~payload:Queue.Manual_compaction_requested
      Queue.manual_compaction_post_id
      1.0
  in
  let peer_work = stimulus "peer-work" 2.0 in
  let claimed, lease =
    State.with_pending (queue [ request; peer_work ]) State.empty |> claim_head
  in
  let lease = require_some "no-compaction lease" lease in
  let terminal = no_compaction ~turn_count:7 State.No_eligible_history in
  let settled, result =
    State.settle
      ~settled_at:11.0
      ~lease
      ~settlement:(State.No_compaction terminal)
      claimed
    |> require_ok "settle no-compaction terminal"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "first no-compaction was already settled"
  in
  Alcotest.(check string)
    "typed transition identity"
    "lease:1:no_compaction"
    receipt.transition_id;
  Alcotest.(check (list string))
    "request is terminal while unrelated work remains runnable"
    [ "peer-work" ]
    (post_ids (State.pending settled));
  let decoded =
    State.transition_receipt_to_yojson receipt
    |> State.transition_receipt_of_yojson
    |> require_ok "no-compaction receipt roundtrip"
  in
  Alcotest.(check bool)
    "source-bound receipt roundtrips exactly"
    true
    (State.transition_receipt_equal receipt decoded);
  match
    State.settle
      ~settled_at:12.0
      ~lease
      ~settlement:
        (State.No_compaction
           (no_compaction ~turn_count:8 State.No_eligible_history))
      settled
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "different checkpoint source reused a settled request"
;;

let test_no_compaction_rejects_scheduled_product_work () =
  let scheduled_wake : Queue.scheduled_wake =
    { schedule_id = "scheduled-product-work"
    ; due_at = 1.0
    ; payload_digest = "scheduled-product-work-digest"
    ; title = Some "Scheduled product work"
    ; message = "Execute this product task"
    }
  in
  let work =
    stimulus
      ~payload:(Queue.Schedule_due scheduled_wake)
      "schedule-occurrence:scheduled-product-work"
      1.0
  in
  let claimed, lease =
    State.with_pending (queue [ work ]) State.empty |> claim_head
  in
  let lease = require_some "product work lease" lease in
  match
    State.settle
      ~settled_at:11.0
      ~lease
      ~settlement:
        (State.No_compaction
           (no_compaction ~turn_count:7 State.No_eligible_history))
      claimed
  with
  | Error message ->
    Alcotest.(check string)
      "typed settlement authority rejects product work"
      "no-compaction settlement requires one manual-compaction request stimulus"
      message;
    Alcotest.(check int)
      "rejected settlement keeps the source lease active"
      1
      (List.length (State.leases claimed))
  | Ok _ -> Alcotest.fail "no-compaction consumed a non-compaction product event"
;;

let test_no_compaction_decode_rejects_mismatched_stimulus () =
  (* Persist decode boundary re-enforces the settle-time receipt-vs-stimuli
     invariant (parse, don't validate). A persisted state whose No_compaction
     outbox receipt is paired with a non-manual stimulus must decode to Error,
     not silently Ok. Counterfactual: without the decode-boundary call the same
     tampered JSON decodes Ok. *)
  let request =
    stimulus
      ~payload:Queue.Manual_compaction_requested
      Queue.manual_compaction_post_id
      1.0
  in
  let claimed, lease =
    State.with_pending (queue [ request ]) State.empty |> claim_head
  in
  let lease = require_some "no-compaction lease" lease in
  let terminal = no_compaction ~turn_count:7 State.No_eligible_history in
  let settled, _ =
    State.settle
      ~settled_at:11.0
      ~lease
      ~settlement:(State.No_compaction terminal)
      claimed
    |> require_ok "settle no-compaction terminal"
  in
  let json = State.to_yojson settled in
  (* The untampered persisted state decodes cleanly. *)
  ignore (State.of_yojson json |> require_ok "untampered no-compaction decode");
  let substitute =
    Queue.stimulus_to_yojson (stimulus ~payload:Queue.Bootstrap "peer-work" 2.0)
  in
  let tamper_outbox_entry = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if String.equal key "stimuli"
              then key, `List [ substitute ]
              else key, value)
           fields)
    | other -> other
  in
  let tampered =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              match key, value with
              | "transition_outbox", `List entries ->
                key, `List (List.map tamper_outbox_entry entries)
              | _ -> key, value)
           fields)
    | other -> other
  in
  match State.of_yojson tampered with
  | Error message ->
    Alcotest.(check string)
      "decode boundary rejects mismatched no-compaction stimulus"
      "no-compaction settlement requires one manual-compaction request stimulus"
      message
  | Ok _ ->
    Alcotest.fail
      "decode accepted a No_compaction receipt paired with a non-manual stimulus"
;;

let accepted_cancellation ~source ~source_revision ~owner_generation operation_id
    : State.accepted_cancellation
  =
  { source
  ; source_revision
  ; owner_generation
  ; operator_operation_id = operation_id
  ; reason = "operator cancelled retained work"
  }
;;

let test_accepted_cancellation_is_exact_owner_fenced_terminal () =
  let accepted = stimulus "accepted-event" 1.0 in
  let peer = stimulus "peer-event" 2.0 in
  let source =
    State.empty
    |> State.with_pending (queue [ accepted; peer ])
    |> State.with_revision 7L
  in
  let claimed, lease =
    State.claim_when
      ~claimed_at:3.0
      ~ready:(Queue.stimulus_identity_equal accepted)
      source
    |> require_ok "claim exact accepted event"
  in
  let lease = require_some "accepted event lease" lease in
  let cancellation =
    accepted_cancellation
      ~source:accepted
      ~source_revision:7L
      ~owner_generation:4
      "op-1"
  in
  (match
     State.settle
       ~settled_at:4.0
       ~lease
       ~settlement:(State.Cancel_accepted cancellation)
       claimed
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "generic settlement bypassed the owner fence");
  let changed_source = { accepted with arrived_at = 1.5 } in
  let changed_cancellation = { cancellation with source = changed_source } in
  (match
     State.cancel_accepted
       ~current_owner_generation:4
       ~settled_at:4.0
       ~lease
       ~cancellation:changed_cancellation
       claimed
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "accepted cancellation ignored a changed source snapshot");
  let settled, result =
    State.cancel_accepted
      ~current_owner_generation:4
      ~settled_at:4.0
      ~lease
      ~cancellation
      claimed
    |> require_ok "cancel accepted event"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "first cancellation was already settled"
  in
  Alcotest.(check string)
    "typed transition identity"
    "lease:1:cancel_accepted"
    receipt.transition_id;
  Alcotest.(check (list string))
    "only the exact accepted event is terminal"
    [ "peer-event" ]
    (post_ids (State.pending settled));
  let outbox = State.transition_outbox settled in
  let source_stimuli =
    match outbox with
    | [ entry ] -> entry.stimuli
    | _ -> Alcotest.fail "cancellation did not retain one exact outbox source"
  in
  Alcotest.(check bool)
    "outbox retains the exact source identity"
    true
    (match source_stimuli with
     | [ source ] -> Queue.stimulus_identity_equal source accepted
     | _ -> false);
  let decoded =
    State.transition_receipt_to_yojson receipt
    |> State.transition_receipt_of_yojson
    |> require_ok "accepted cancellation receipt roundtrip"
  in
  Alcotest.(check bool)
    "cancellation receipt roundtrips"
    true
    (State.transition_receipt_equal receipt decoded);
  (match
     State.cancel_accepted
       ~current_owner_generation:99
       ~settled_at:5.0
       ~lease
       ~cancellation
       settled
   with
   | Ok (_, State.Already_settled repeated) ->
     Alcotest.(check string)
       "same operation replays the committed receipt"
       receipt.transition_id
       repeated.transition_id
   | Ok (_, State.Settled _) -> Alcotest.fail "replay created a second cancellation"
   | Error message -> Alcotest.failf "committed cancellation did not replay: %s" message)
;;

let test_accepted_cancellation_rejects_stale_fences () =
  let accepted = stimulus "accepted-event" 1.0 in
  let claimed, lease =
    State.empty
    |> State.with_pending (queue [ accepted ])
    |> State.with_revision 7L
    |> State.claim_when ~claimed_at:3.0 ~ready:(fun _ -> true)
    |> require_ok "claim stale-fence fixture"
  in
  let lease = require_some "stale-fence lease" lease in
  let cancel cancellation current_owner_generation =
    State.cancel_accepted
      ~current_owner_generation
      ~settled_at:4.0
      ~lease
      ~cancellation
      claimed
  in
  (match
     cancel
       (accepted_cancellation
          ~source:accepted
          ~source_revision:7L
          ~owner_generation:4
          "op-1")
       5
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "stale owner generation cancelled accepted work");
  (match
     cancel
       (accepted_cancellation
          ~source:accepted
          ~source_revision:6L
          ~owner_generation:4
          "op-1")
       4
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "stale queue revision cancelled accepted work");
  Alcotest.(check int)
    "rejected cancellation keeps the exact lease active"
    1
    (List.length (State.leases claimed))
;;

let test_pending_accepted_cancellation_is_exact_and_source_bound () =
  let peer_before = stimulus "peer-before" 1.0 in
  let target = stimulus "pending-target" 2.0 in
  let peer_after = stimulus "peer-after" 3.0 in
  let state =
    State.empty
    |> State.with_pending (queue [ peer_before; target; peer_after ])
    |> State.with_revision 9L
  in
  let cancellation =
    accepted_cancellation
      ~source:target
      ~source_revision:9L
      ~owner_generation:6
      "pending-operation-1"
  in
  let cancelled, result =
    State.cancel_pending_accepted
      ~current_owner_generation:6
      ~settled_at:4.0
      ~cancellation
      state
    |> require_ok "cancel exact pending source"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "first pending cancellation replayed"
  in
  Alcotest.(check (list string))
    "pending cancellation preserves peer FIFO"
    [ "peer-before"; "peer-after" ]
    (post_ids (State.pending cancelled));
  Alcotest.(check int) "synthetic lease is terminal" 0 (List.length (State.leases cancelled));
  Alcotest.(check int64)
    "synthetic lease consumes one stable sequence"
    2L
    (State.next_lease_sequence cancelled);
  (match State.transition_outbox cancelled with
   | [ entry ] ->
     Alcotest.(check bool)
       "outbox carries the exact pending source"
       true
       (entry.stimuli = [ target ]);
     Alcotest.(check bool)
       "receipt is source-bound"
       true
       (match entry.receipt.settlement with
        | State.Cancel_accepted accepted -> accepted.source = target
        | _ -> false)
   | _ -> Alcotest.fail "pending cancellation did not create one outbox entry");
  (match
     State.cancel_pending_accepted
       ~current_owner_generation:99
       ~settled_at:5.0
       ~cancellation
       cancelled
   with
   | Ok (_, State.Already_settled replayed) ->
     Alcotest.(check bool)
       "committed pending cancellation replays before current fences"
       true
       (State.transition_receipt_equal receipt replayed)
   | Ok (_, State.Settled _) -> Alcotest.fail "pending replay committed twice"
   | Error detail -> Alcotest.fail detail);
  let changed_source =
    { cancellation with
      source = peer_before
    }
  in
  (match
     State.cancel_pending_accepted
       ~current_owner_generation:6
       ~settled_at:5.0
       ~cancellation:changed_source
       cancelled
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "operation ID replay accepted a different source")
;;

let test_claim_codec_ack_idempotency () =
  let first = stimulus "first" 1.0 in
  let state = State.with_pending (queue [ first ]) State.empty in
  let state, lease = claim_head state in
  let lease = require_some "claimed lease" lease in
  Alcotest.(check int64) "lease sequence" 1L lease.sequence;
  Alcotest.(check string) "stable lease id" "lease:1" lease.lease_id;
  Alcotest.(check int) "pending drained" 0 (Queue.length (State.pending state));
  Alcotest.(check int64) "next sequence" 2L (State.next_lease_sequence state);
  let state =
    State.to_yojson state |> State.of_yojson |> require_ok "v2 codec roundtrip"
  in
  let state, result =
    State.settle ~settled_at:11.0 ~lease ~settlement:State.Ack state
    |> require_ok "ack settlement"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "first settlement was already settled"
  in
  Alcotest.(check string) "transition id" "lease:1:ack" receipt.transition_id;
  Alcotest.(check string)
    "stable projection event id"
    "keeper-event-queue-transition:lease:1:ack"
    receipt.event_id;
  Alcotest.(check int) "lease removed" 0 (List.length (State.leases state));
  Alcotest.(check int) "outbox retained" 1 (List.length (State.transition_outbox state));
  let state, repeated =
    State.settle ~settled_at:12.0 ~lease ~settlement:State.Ack state
    |> require_ok "idempotent repeated ack"
  in
  (match repeated with
   | State.Already_settled repeated_receipt ->
     Alcotest.(check string)
       "same durable receipt"
       receipt.transition_id
       repeated_receipt.transition_id
   | State.Settled _ -> Alcotest.fail "repeated settlement created a second transition");
  Alcotest.(check int)
    "idempotent outbox cardinality"
    1
    (List.length (State.transition_outbox state));
  let state =
    State.mark_transition_projected ~transition_id:receipt.transition_id state
    |> require_ok "mark transition projected"
  in
  Alcotest.(check int)
    "projected outbox is retired"
    0
    (List.length (State.transition_outbox state));
  let projected = require_some "last projected settlement" (State.last_settlement state) in
  Alcotest.(check string)
    "projection acknowledgement retains the last receipt"
    receipt.transition_id
    projected.transition_id;
  ignore
    (State.mark_transition_projected ~transition_id:receipt.transition_id state
     |> require_ok "projection acknowledgement is idempotent");
  (match
     State.settle
       ~settled_at:13.0
       ~lease
       ~settlement:(State.Requeue State.Cycle_busy)
       state
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "conflicting second settlement was accepted")
;;

let test_canonical_receipt_replay () =
  let state =
    State.with_pending (queue [ stimulus "replay" 1.0 ]) State.empty
  in
  let claimed, lease = claim_head state in
  let lease = require_some "replay lease" lease in
  let settled, result =
    State.settle ~settled_at:11.0 ~lease ~settlement:State.Ack claimed
    |> require_ok "settle replay fixture"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "replay fixture was already settled"
  in
  let decoded =
    State.transition_receipt_to_yojson receipt
    |> State.transition_receipt_of_yojson
    |> require_ok "canonical receipt roundtrip"
  in
  Alcotest.(check bool)
    "receipt equality survives codec"
    true
    (State.transition_receipt_equal receipt decoded);
  let replayed =
    State.replay_transition_receipt decoded claimed
    |> require_ok "replay canonical receipt"
  in
  Alcotest.(check string)
    "replay reconstructs exact state"
    (State.to_yojson settled |> Yojson.Safe.to_string)
    (State.to_yojson replayed |> Yojson.Safe.to_string);
  let repeated =
    State.replay_transition_receipt decoded replayed
    |> require_ok "replay canonical receipt idempotently"
  in
  Alcotest.(check string)
    "idempotent replay preserves state"
    (State.to_yojson replayed |> Yojson.Safe.to_string)
    (State.to_yojson repeated |> Yojson.Safe.to_string);
  let conflicting = { decoded with event_id = "wrong-event-id" } in
  match State.replay_transition_receipt conflicting claimed with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "conflicting receipt replay was accepted"
;;

let test_receipt_codec_is_closed_and_finite () =
  let state =
    State.with_pending (queue [ stimulus "codec" 1.0 ]) State.empty
  in
  let claimed, lease = claim_head state in
  let lease = require_some "codec lease" lease in
  (match State.settle ~settled_at:Float.nan ~lease ~settlement:State.Ack claimed with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "non-finite settlement time was accepted");
  let _, result =
    State.settle ~settled_at:12.0 ~lease ~settlement:State.Ack claimed
    |> require_ok "settle codec fixture"
  in
  let receipt =
    match result with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "codec fixture was already settled"
  in
  let fields =
    match State.transition_receipt_to_yojson receipt with
    | `Assoc fields -> fields
    | _ -> Alcotest.fail "receipt encoder did not return an object"
  in
  let rejects label json =
    match State.transition_receipt_of_yojson json with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "%s was accepted" label
  in
  rejects "unknown receipt field" (`Assoc (("extra", `Null) :: fields));
  rejects
    "duplicate receipt field"
    (`Assoc (("transition_id", `String receipt.transition_id) :: fields));
  rejects
    "non-finite receipt time"
    (`Assoc
       (List.map
          (fun (name, value) ->
             if String.equal name "settled_at_unix"
             then name, `Float Float.infinity
             else name, value)
          fields));
  rejects
    "unknown settlement field"
    (`Assoc
       (List.map
          (fun (name, value) ->
             if String.equal name "settlement"
             then (
               match value with
               | `Assoc settlement_fields ->
                 name, `Assoc (("extra", `Null) :: settlement_fields)
               | _ -> Alcotest.fail "settlement encoder did not return an object")
             else name, value)
          fields))
;;

let test_claim_leases_earliest_ready_without_reordering_skipped_work () =
  let blocked =
    { (stimulus "blocked" 1.0) with urgency = Queue.Immediate }
  in
  let first_ready =
    { (stimulus "first-ready" 2.0) with urgency = Queue.Low }
  in
  let second_ready =
    { (stimulus "second-ready" 3.0) with urgency = Queue.Immediate }
  in
  let ready (candidate : Queue.stimulus) =
    not (String.equal candidate.post_id blocked.post_id)
  in
  let state =
    State.with_pending (queue [ blocked; first_ready; second_ready ]) State.empty
  in
  let state, first_lease =
    State.claim_when ~claimed_at:4.0 ~ready state
    |> require_ok "claim earliest ready"
  in
  let first_lease = require_some "first ready lease" first_lease in
  Alcotest.(check (list string))
    "arrival order wins across urgency labels"
    [ first_ready.post_id ]
    (post_ids (queue first_lease.stimuli));
  Alcotest.(check (list string))
    "skipped input keeps its position"
    [ blocked.post_id; second_ready.post_id ]
    (post_ids (State.pending state));
  let state, settlement =
    State.settle ~settled_at:5.0 ~lease:first_lease ~settlement:State.Ack state
    |> require_ok "settle first ready"
  in
  let receipt =
    match settlement with
    | State.Settled receipt -> receipt
    | State.Already_settled _ -> Alcotest.fail "first ready lease was already settled"
  in
  let state =
    State.mark_transition_projected ~transition_id:receipt.transition_id state
    |> require_ok "project first ready settlement"
  in
  let state, second_lease =
    State.claim_when ~claimed_at:6.0 ~ready state
    |> require_ok "claim second ready"
  in
  let second_lease = require_some "second ready lease" second_lease in
  Alcotest.(check (list string))
    "next ready input follows"
    [ second_ready.post_id ]
    (post_ids (queue second_lease.stimuli));
  Alcotest.(check (list string))
    "blocked input remains durable"
    [ blocked.post_id ]
    (post_ids (State.pending state))
;;

let test_requeue_and_escalation_are_total () =
  let retry = stimulus "retry" 1.0 in
  let state = State.with_pending (queue [ retry ]) State.empty in
  let state, lease = claim_head state in
  let lease = require_some "retry lease" lease in
  let state, _ =
    State.settle
      ~settled_at:2.0
      ~lease
      ~settlement:(State.Requeue State.Rotate_now)
      state
    |> require_ok "retry requeue"
  in
  let retry_receipt =
    match State.transition_outbox state with
    | [ entry ] -> entry.receipt
    | _ -> Alcotest.fail "retry settlement must create one outbox entry"
  in
  let blocked_state, blocked_lease = claim_head state in
  Alcotest.(check bool)
    "unprojected outbox blocks the next claim"
    true
    (Option.is_none blocked_lease);
  Alcotest.(check (list string))
    "blocked claim preserves pending work"
    [ "retry" ]
    (post_ids (State.pending blocked_state));
  let state =
    State.mark_transition_projected
      ~transition_id:retry_receipt.transition_id
      blocked_state
    |> require_ok "project retry transition"
  in
  Alcotest.(check (list string)) "retry restored" [ "retry" ] (post_ids (State.pending state));
  let state, lease = claim_head state in
  let lease = require_some "escalation lease" lease in
  let judgment : Queue.failure_judgment =
    { fj_runtime_id = "runtime-a"
    ; fj_judgment = Keeper_runtime_failure_route.Contract_violation
    ; fj_provenance = Keeper_runtime_failure_route.Oas_agent_error
    ; fj_detail = "deterministic failure"
    }
  in
  let successor =
    stimulus
      ~payload:(Queue.Failure_judgment judgment)
      (Queue.failure_judgment_post_id judgment)
      3.0
  in
  let state, _ =
    State.settle
      ~settled_at:3.0
      ~lease
      ~settlement:
        (State.Escalate
           { reason = State.Failure_judgment_requested
           ; successor = Some successor
           })
      state
    |> require_ok "atomic judgment successor"
  in
  let escalation_receipt =
    match State.transition_outbox state with
    | [ entry ] -> entry.receipt
    | _ -> Alcotest.fail "judgment escalation must create one outbox entry"
  in
  let state =
    State.mark_transition_projected ~transition_id:escalation_receipt.transition_id state
    |> require_ok "project judgment escalation"
  in
  Alcotest.(check (list string))
    "original consumed and successor pending"
    [ successor.post_id ]
    (post_ids (State.pending state));
  let state, judgment_lease = claim_head state in
  let judgment_lease = require_some "judgment lease" judgment_lease in
  let state, _ =
    State.settle
      ~settled_at:4.0
      ~lease:judgment_lease
      ~settlement:
        (State.Escalate
           { reason =
               State.Failure_judgment_boundary_failed
                 { detail = "structured judge response violated its contract" }
           ; successor = None
           })
      state
    |> require_ok "judgment boundary failure escalation"
  in
  Alcotest.(check int)
    "judgment boundary failure does not enqueue itself"
    0
    (Queue.length (State.pending state));
  Alcotest.(check int)
    "only the unprojected transition remains in state"
    1
    (List.length (State.transition_outbox state));
  let open Yojson.Safe.Util in
  let boundary_failure_settlement =
    State.to_yojson state
    |> member "transition_outbox"
    |> to_list
    |> List.rev
    |> List.hd
    |> member "receipt"
    |> member "settlement"
  in
  Alcotest.(check string)
    "judgment boundary failure receipt is an escalation"
    "escalate"
    (boundary_failure_settlement |> member "kind" |> to_string);
  Alcotest.(check string)
    "judgment boundary failure receipt preserves the typed reason"
    "failure_judgment_boundary_failed"
    (boundary_failure_settlement |> member "reason" |> to_string);
  Alcotest.(check bool)
    "judgment boundary failure receipt explicitly stores no successor"
    true
    (boundary_failure_settlement
     |> member "successor"
     |> Yojson.Safe.equal `Null)
;;

let test_judgment_terminal_evidence_is_durable () =
  List.iter
    (fun reason ->
      Alcotest.(check bool)
        "non-verdict judgment transitions do not request external input"
        false
        (State.escalation_reason_requests_external_input reason))
    [ State.Failure_judgment_requested
    ; State.Failure_judgment_boundary_failed { detail = "schema drift" }
    ];
  Alcotest.(check bool)
    "explicit external-input verdict remains visible"
    true
    (State.escalation_reason_requests_external_input
       (State.Failure_judgment_external_input_requested
          { judge_runtime_id = "structured-judge"
          ; rationale = "Required external input is unavailable."
          }));
  let judgment : Queue.failure_judgment =
    { fj_runtime_id = "failed-runtime"
    ; fj_judgment = Keeper_runtime_failure_route.Config_mismatch
    ; fj_provenance = Keeper_runtime_failure_route.Oas_config_error
    ; fj_detail = "configuration unavailable"
    }
  in
  let source =
    stimulus
      ~payload:(Queue.Failure_judgment judgment)
      (Queue.failure_judgment_post_id judgment)
      1.0
  in
  let state = State.with_pending (queue [ source ]) State.empty in
  let state, lease = claim_head state in
  let lease = require_some "external-input judgment lease" lease in
  let state, _ =
    State.settle
      ~settled_at:2.0
      ~lease
      ~settlement:
        (State.Escalate
           { reason =
               State.Failure_judgment_external_input_requested
                 { judge_runtime_id = "structured-judge"
                 ; rationale = "Required external input is unavailable."
                 }
           ; successor = None
           })
      state
    |> require_ok "external-input judgment settlement"
  in
  let restored =
    State.to_yojson state
    |> State.of_yojson
    |> require_ok "external-input judgment evidence roundtrip"
  in
  (match State.transition_outbox restored with
   | [ { receipt =
           { settlement =
               State.Escalate
                 { reason =
                     State.Failure_judgment_external_input_requested
                       { judge_runtime_id; rationale }
                 ; successor = None
                 }
           ; _
           }
       ; _
       } ] ->
     Alcotest.(check string)
       "opaque judge runtime preserved"
       "structured-judge"
       judge_runtime_id;
     Alcotest.(check string)
       "external-input rationale preserved"
       "Required external input is unavailable."
       rationale
   | _ -> Alcotest.fail "external-input judgment evidence changed during roundtrip");
  let open Yojson.Safe.Util in
  let settlement_json =
    State.to_yojson state
    |> member "transition_outbox"
    |> to_list
    |> List.hd
    |> member "receipt"
    |> member "settlement"
  in
  Alcotest.(check string)
    "external-input reason wire label"
    "failure_judgment_external_input_requested"
    (settlement_json |> member "reason" |> to_string);
  Alcotest.(check string)
    "external-input rationale wire evidence"
    "Required external input is unavailable."
    (settlement_json |> member "reason_detail" |> member "rationale" |> to_string);
  let invalid_state = State.with_pending (queue [ source ]) State.empty in
  let invalid_state, invalid_lease = claim_head invalid_state in
  let invalid_lease = require_some "invalid evidence lease" invalid_lease in
  match
    State.settle
      ~settled_at:3.0
      ~lease:invalid_lease
      ~settlement:
        (State.Escalate
           { reason =
               State.Failure_judgment_boundary_failed { detail = "" }
           ; successor = None
           })
      invalid_state
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "empty boundary failure evidence committed"
;;

let lease_for stimulus =
  let state = State.with_pending (queue [ stimulus ]) State.empty in
  let _state, lease = claim_head state in
  require_some "fixture lease" lease
;;

let turn_failure route : Masc.Keeper_unified_turn.turn_failure =
  { error = Agent_sdk.Error.Internal "deterministic fixture"
  ; runtime_id = "exact-final-runtime"
  ; route
  ; source_lease_disposition = Masc.Keeper_unified_turn.Follow_failure_route
  }
;;

let test_failed_cycle_route_mapping () =
  let retry_failure =
    turn_failure
      (Keeper_runtime_failure_route.Retry_after_observed
         { retry_class = Keeper_runtime_failure_route.Rate_limited
         ; retry_after = None
         })
  in
  (match
     Masc.Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:2.0
       ~compaction_consecutive_failures:0
       retry_failure
   with
   | Masc.Keeper_registry_event_queue.Requeue
       Masc.Keeper_registry_event_queue.Retry_after_observed ->
     ()
   | _ -> Alcotest.fail "observed retry route did not retain the leased work");
  let judgment_failure =
    turn_failure
      (Keeper_runtime_failure_route.Escalate_judgment
         { judgment = Keeper_runtime_failure_route.Contract_violation
         ; provenance = Keeper_runtime_failure_route.Oas_agent_error
         ; detail = "fixture contract failure"
         })
  in
  (match
     Masc.Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:3.0
       ~compaction_consecutive_failures:0
       judgment_failure
   with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason = Masc.Keeper_registry_event_queue.Failure_judgment_requested
       ; successor = Some { Queue.payload = Queue.Failure_judgment successor; _ }
       } ->
     Alcotest.(check string)
       "successor keeps exact final runtime"
       "exact-final-runtime"
       successor.fj_runtime_id
   | _ -> Alcotest.fail "deterministic failure did not create one judgment successor");
  let handled_failure =
    { judgment_failure with
      source_lease_disposition =
        Masc.Keeper_unified_turn.Acknowledge_after_in_turn_handling
    }
  in
  (match
     Masc.Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:6.0
       ~compaction_consecutive_failures:0
       handled_failure
   with
   | Masc.Keeper_registry_event_queue.Ack -> ()
   | _ -> Alcotest.fail "in-turn handled terminal failure was retried");
  let compacted_failure =
    { judgment_failure with
      source_lease_disposition =
        Masc.Keeper_unified_turn.Requeue_after_context_compaction
          Masc.Keeper_unified_turn.Compaction_committed
    }
  in
  match
    Masc.Keeper_heartbeat_loop.settlement_of_failure
      ~settled_at:7.0
      ~compaction_consecutive_failures:0
      compacted_failure
  with
  | Masc.Keeper_registry_event_queue.Requeue
      Masc.Keeper_registry_event_queue.Context_compaction_retry ->
    ()
  | _ -> Alcotest.fail "context-compacted source stimulus was acknowledged"
;;

let cycle_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "queue-outcome"
        ; "agent_name", `String "agent-queue-outcome"
        ; "trace_id", `String "trace-queue-outcome"
        ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.failf "cycle meta fixture: %s" message
;;

let test_manual_no_compaction_is_terminal_but_overflow_escalates () =
  let lease =
    lease_for
      (stimulus
         ~payload:Queue.Manual_compaction_requested
         Queue.manual_compaction_post_id
         1.0)
  in
  let source = checkpoint_source ~turn_count:7 in
  let no_compaction : Masc.Keeper_post_turn.no_compaction =
    { source; reason = State.No_eligible_history }
  in
  let expect_terminal = function
    | Masc.Keeper_registry_event_queue.No_compaction terminal ->
      Alcotest.(check bool)
        "exact checkpoint source is retained"
        true
        (Keeper_checkpoint_ref.equal source terminal.source);
      Alcotest.(check string)
        "typed reason is retained"
        "no_eligible_history"
        (State.no_compaction_reason_label terminal.reason)
    | _ -> Alcotest.fail "no-compaction source was requeued"
  in
  expect_terminal
    (Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
       ~base_path:"/tmp/no-compaction-manual"
       ~settled_at:2.0
       ~stop_requested:false
       ~compaction_consecutive_failures:0
       ~lease
       (Some
          (Masc.Keeper_heartbeat_loop_cycle.Manual_compaction_not_applied
             { meta = cycle_meta (); no_compaction })));
  let judgment_route =
    Keeper_runtime_failure_route.Escalate_judgment
      { judgment = Keeper_runtime_failure_route.Context_overflow
      ; provenance = Keeper_runtime_failure_route.Oas_api_error
      ; detail = "typed provider context overflow"
      }
  in
  let overflow_failure =
    turn_failure judgment_route
  in
  match
    Masc.Keeper_heartbeat_loop.settlement_of_failure
      ~settled_at:3.0
      ~compaction_consecutive_failures:0
      overflow_failure
  with
  | Masc.Keeper_registry_event_queue.Escalate
      { reason = Masc.Keeper_registry_event_queue.Failure_judgment_requested
      ; successor = Some { payload = Queue.Failure_judgment _; _ }
      } ->
    ()
  | _ -> Alcotest.fail "provider overflow no-compaction consumed the source lease"
;;

let test_applied_compaction_settles_followup_atomically () =
  let lease =
    lease_for
      (stimulus
         ~payload:Queue.Manual_compaction_requested
         Queue.manual_compaction_post_id
         1.0)
  in
  let meta = cycle_meta () in
  let settlement failure =
    Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
      ~base_path:(Sys.getcwd ())
      ~settled_at:8.0
      ~stop_requested:false
      ~compaction_consecutive_failures:0
      ~lease
      (Some
         (Masc.Keeper_heartbeat_loop_cycle.Manual_compaction_applied
            (Masc.Keeper_heartbeat_loop_cycle.Failed { meta; failure })))
  in
  let judgment_failure =
    turn_failure
      (Keeper_runtime_failure_route.Escalate_judgment
         { judgment = Keeper_runtime_failure_route.Contract_violation
         ; provenance = Keeper_runtime_failure_route.Oas_agent_error
         ; detail = "post-compaction contract failure"
         })
  in
  (match settlement judgment_failure with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason = Masc.Keeper_registry_event_queue.Failure_judgment_requested
       ; successor = Some { Queue.payload = Queue.Failure_judgment successor; _ }
       } ->
     Alcotest.(check string)
       "atomic successor keeps exact final runtime"
       judgment_failure.runtime_id
       successor.fj_runtime_id
   | _ -> Alcotest.fail "applied compaction lost its follow-up judgment");
  let retry_failure =
    turn_failure
      (Keeper_runtime_failure_route.Retry_after_observed
         { retry_class = Keeper_runtime_failure_route.Rate_limited
         ; retry_after = None
         })
  in
  match settlement retry_failure with
  | Masc.Keeper_registry_event_queue.Ack -> ()
  | _ -> Alcotest.fail "follow-up retry replayed an already-applied compaction"
;;

(* RFC-0351 S0 / #25461: a manual-compaction failure requeues while the streak
   is under the ceiling and settles terminally at it. Without the ceiling the
   stimulus re-enters on every heartbeat cycle, because [Requeue] is not an ack
   (measured: 102 failures / 104 compaction LLM calls in 74 minutes). *)
let test_compaction_retry_escalates_after_threshold () =
  let lease = lease_for (stimulus "compaction-retry" 1.0) in
  let meta = cycle_meta () in
  let failed =
    Masc.Keeper_heartbeat_loop_cycle.Manual_compaction_failed
      { meta
      ; failure =
          Masc.Keeper_manual_compaction.Recovery
            ( Masc.Keeper_post_turn.Checkpoint_candidate_failed
                "test-induced candidate failure"
            , Ok () )
      }
  in
  let settlement ~streak =
    Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
      ~base_path:"/tmp/compaction-retry-ceiling"
      ~settled_at:2.0
      ~stop_requested:false
      ~compaction_consecutive_failures:streak
      ~lease
      (Some failed)
  in
  let expect_requeue ~streak label =
    match settlement ~streak with
    | Masc.Keeper_registry_event_queue.Requeue
        Masc.Keeper_registry_event_queue.Context_compaction_retry ->
      ()
    | _ -> Alcotest.fail label
  in
  expect_requeue ~streak:0 "first compaction failure did not requeue";
  expect_requeue ~streak:1 "second compaction failure did not requeue";
  match settlement ~streak:2 with
  | Masc.Keeper_registry_event_queue.Escalate
      { reason =
          Masc.Keeper_registry_event_queue.Compaction_retry_exhausted
            { attempts; _ }
      ; successor = None
      } ->
    Alcotest.(check int) "escalation reports the attempt count" 3 attempts
  | _ ->
    Alcotest.fail
      "third consecutive compaction failure requeued instead of escalating"
;;

(* RFC-0351 S0 / #25461: the in-lane provider-overflow recovery joins the same
   ceiling. In the 2026-07-21 storm 284 of 285 rejections carried
   trigger=provider_overflow and escalation never fired, because this lane
   requeued unconditionally; the storm ran ~10h and ended only when the
   operator issued keeper_down. *)
let test_in_lane_compaction_streak_bounds_retries () =
  let judgment_route =
    Keeper_runtime_failure_route.Escalate_judgment
      { judgment = Keeper_runtime_failure_route.Context_overflow
      ; provenance = Keeper_runtime_failure_route.Oas_api_error
      ; detail = "typed provider context overflow"
      }
  in
  let failure disposition =
    { (turn_failure judgment_route) with source_lease_disposition = disposition }
  in
  let settlement ~streak disposition =
    Masc.Keeper_heartbeat_loop.settlement_of_failure
      ~settled_at:4.0
      ~compaction_consecutive_failures:streak
      (failure disposition)
  in
  let attempt_failed =
    Masc.Keeper_unified_turn.Requeue_after_context_compaction
      (Masc.Keeper_unified_turn.Compaction_attempt_failed
         { reason = "test-induced recovery failure" })
  in
  let committed =
    Masc.Keeper_unified_turn.Requeue_after_context_compaction
      Masc.Keeper_unified_turn.Compaction_committed
  in
  let terminal_no_compaction =
    Masc.Keeper_unified_turn.source_lease_disposition_after_no_compaction
      (no_compaction ~turn_count:13 State.Checkpoint_not_reduced)
  in
  let expect_compaction_requeue label = function
    | Masc.Keeper_registry_event_queue.Requeue
        Masc.Keeper_registry_event_queue.Context_compaction_retry ->
      ()
    | _ -> Alcotest.fail label
  in
  let expect_exhausted ~attempts label = function
    | Masc.Keeper_registry_event_queue.Escalate
        { reason =
            Masc.Keeper_registry_event_queue.Compaction_retry_exhausted
              { attempts = reported; _ }
        ; successor = None
        } ->
      Alcotest.(check int) (label ^ ": attempt count") attempts reported
    | _ -> Alcotest.fail label
  in
  expect_compaction_requeue
    "first in-lane recovery failure did not requeue"
    (settlement ~streak:0 attempt_failed);
  expect_compaction_requeue
    "second in-lane recovery failure did not requeue"
    (settlement ~streak:1 attempt_failed);
  expect_exhausted
    ~attempts:3
    "third in-lane recovery failure requeued instead of escalating"
    (settlement ~streak:2 attempt_failed);
  (* Below the ceiling a committed compaction requeues: the retry reloads a
     durably smaller checkpoint. *)
  expect_compaction_requeue
    "committed in-lane compaction below the ceiling did not requeue"
    (settlement ~streak:0 committed);
  expect_compaction_requeue
    "second committed episode below the ceiling did not requeue"
    (settlement ~streak:1 committed);
  (* #25538: at the ceiling a commit proves the floor — the savings keep
     committing yet the context re-overflows every episode, so the settlement
     escalates with the commit-distinguishing reason instead of looping. *)
  (match settlement ~streak:2 committed with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason =
           Masc.Keeper_registry_event_queue.Compaction_floor_exceeded
             { attempts; _ }
       ; successor = None
       } ->
     Alcotest.(check int) "floor escalation reports the attempt count" 3 attempts
   | _ ->
     Alcotest.fail
       "committed episode at the ceiling requeued instead of escalating as \
        a floor");
  (* A terminal no-compaction below the ceiling keeps today's route (the
     judgment successor); at the ceiling the settlement replaces the route,
     because a context that cannot shrink re-overflows deterministically. *)
  (match settlement ~streak:0 terminal_no_compaction with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason = Masc.Keeper_registry_event_queue.Failure_judgment_requested
       ; successor = Some { Queue.payload = Queue.Failure_judgment _; _ }
       } ->
     ()
   | _ ->
     Alcotest.fail
       "terminal no-compaction below the ceiling lost its typed failure route");
  expect_exhausted
    ~attempts:3
    "terminal no-compaction at the ceiling followed the route instead of \
     escalating"
    (settlement ~streak:2 terminal_no_compaction);
  let terminal_settlement route no_compaction =
    Masc.Keeper_heartbeat_loop.settlement_of_failure
      ~settled_at:5.0
      ~compaction_consecutive_failures:0
      { (turn_failure route) with
        source_lease_disposition =
          Masc.Keeper_unified_turn.source_lease_disposition_after_no_compaction
            no_compaction
      }
  in
  let dispatch_terminal =
    terminal_settlement
      (Keeper_runtime_failure_route.Retry_after_observed
         { retry_class = Keeper_runtime_failure_route.Rate_limited
         ; retry_after = None
         })
      (no_compaction
         ~turn_count:14
         (exact_terminal State.Execution_failed_after_dispatch))
  in
  (match dispatch_terminal with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason =
           Masc.Keeper_registry_event_queue.Compaction_exact_output_terminal
             { terminal =
                 { cause = State.Execution_failed_after_dispatch; _ }
             ; _
             }
       ; successor = None
       } ->
     ()
   | _ ->
     Alcotest.fail
       "post-dispatch compaction terminal entered the ordinary retry route");
  let domain_terminal =
    terminal_settlement
      (Keeper_runtime_failure_route.Rotate_now
         { rotate = Keeper_runtime_failure_route.Auth_failed })
      (no_compaction
         ~turn_count:15
         (exact_terminal State.Domain_invalid_output))
  in
  (match domain_terminal with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason =
           Masc.Keeper_registry_event_queue.Compaction_exact_output_terminal
             { terminal = { cause = State.Domain_invalid_output; _ }; _ }
       ; successor = None
       } ->
     ()
   | _ ->
     Alcotest.fail
       "domain-invalid compaction terminal entered the ordinary rotation route");
  let exact_lane_source = checkpoint_source ~turn_count:16 in
  let exact_lane_terminal =
    terminal_settlement
      (Keeper_runtime_failure_route.Retry_after_observed
         { retry_class = Keeper_runtime_failure_route.Rate_limited
         ; retry_after = None
         })
      { State.source = exact_lane_source; reason = State.Exact_lane_unconfigured }
  in
  (match exact_lane_terminal with
   | Masc.Keeper_registry_event_queue.Escalate
       { reason =
           Masc.Keeper_registry_event_queue.Compaction_exact_lane_unconfigured
             { source }
       ; successor = None
       } ->
     Alcotest.(check bool)
       "missing-lane terminal retains the full checkpoint source"
       true
       (source = exact_lane_source)
   | Masc.Keeper_registry_event_queue.Requeue _ ->
     Alcotest.fail "missing exact lane entered a retry route"
   | _ -> Alcotest.fail "missing exact lane lost its typed terminal escalation");
  let check_durable_terminal label expected_reason settlement =
    let state = State.with_pending (queue [ stimulus label 6.0 ]) State.empty in
    let state, lease = claim_head state in
    let lease = require_some (label ^ " lease") lease in
    let state, _ =
      State.settle ~settled_at:7.0 ~lease ~settlement state
      |> require_ok (label ^ " settlement")
    in
    let json = State.to_yojson state in
    let restored =
      State.of_yojson json |> require_ok (label ^ " codec round-trip")
    in
    let open Yojson.Safe.Util in
    let reason =
      json
      |> member "transition_outbox"
      |> to_list
      |> List.hd
      |> member "receipt"
      |> member "settlement"
      |> member "reason"
      |> to_string
    in
    Alcotest.(check string) (label ^ " durable reason") expected_reason reason;
    restored
  in
  ignore
    (check_durable_terminal
       "post-dispatch-terminal"
       "compaction_exact_output_terminal"
       dispatch_terminal
     : State.t);
  ignore
    (check_durable_terminal
       "domain-invalid-terminal"
       "compaction_exact_output_terminal"
       domain_terminal
     : State.t);
  let exact_lane_restored =
    check_durable_terminal
      "exact-lane-unconfigured-terminal"
      "compaction_exact_lane_unconfigured"
      exact_lane_terminal
  in
  match State.transition_outbox exact_lane_restored with
  | { State.receipt =
        { State.settlement =
            State.Escalate
              { reason = State.Compaction_exact_lane_unconfigured { source }
              ; successor = None
              }
        ; _
        }
    ; _
    }
    :: _ ->
    Alcotest.(check bool)
      "decoded missing-lane terminal retains the full checkpoint source"
      true
      (Keeper_checkpoint_ref.equal source exact_lane_source)
  | _ ->
    Alcotest.fail
      "decoded missing-lane terminal lost its typed source-bound escalation"
;;

(* RFC-0351 S0 / #25461: the settlement decides from the streak; this mapping
   is what advances it. In-lane dispositions must join the manual lane's
   counter, and outcomes with no compaction involvement must leave it
   untouched. *)
let test_compaction_outcome_mapping_covers_in_lane_dispositions () =
  let meta = cycle_meta () in
  let judgment_route =
    Keeper_runtime_failure_route.Escalate_judgment
      { judgment = Keeper_runtime_failure_route.Context_overflow
      ; provenance = Keeper_runtime_failure_route.Oas_api_error
      ; detail = "typed provider context overflow"
      }
  in
  let failed disposition =
    Some
      (Masc.Keeper_heartbeat_loop_cycle.Failed
         { meta
         ; failure =
             { (turn_failure judgment_route) with
               source_lease_disposition = disposition
             }
         })
  in
  let check label expected outcome =
    let actual =
      match Masc.Keeper_heartbeat_loop.compaction_outcome_of_cycle_outcome outcome with
      | Some `Committed -> "committed"
      | Some `Overflow_episode_committed -> "overflow_episode_committed"
      | Some `Failed -> "failed"
      | Some `Recovered -> "recovered"
      | None -> "none"
    in
    Alcotest.(check string) label expected actual
  in
  (* #25538: an in-lane commit is one provider-overflow episode — it advances
     the streak instead of resetting it, so an incompressible floor whose
     commits keep "succeeding" still reaches the ceiling. The old
     reset-on-commit expectation was the blind spot (measured: a committed
     920B/0.07% plan reset the streak forever). *)
  check
    "in-lane committed compaction counts the overflow episode"
    "overflow_episode_committed"
    (failed
       (Masc.Keeper_unified_turn.Requeue_after_context_compaction
          Masc.Keeper_unified_turn.Compaction_committed));
  check
    "in-lane failed recovery advances the streak"
    "failed"
    (failed
       (Masc.Keeper_unified_turn.Requeue_after_context_compaction
          (Masc.Keeper_unified_turn.Compaction_attempt_failed
             { reason = "test-induced recovery failure" })));
  check
    "post-dispatch terminal records failure without retry"
    "failed"
    (failed
       (Masc.Keeper_unified_turn.source_lease_disposition_after_no_compaction
          (no_compaction
             ~turn_count:18
             (exact_terminal State.Execution_failed_after_dispatch))));
  check
    "domain-invalid terminal records failure without retry"
    "failed"
    (failed
       (Masc.Keeper_unified_turn.source_lease_disposition_after_no_compaction
          (no_compaction
             ~turn_count:19
             (exact_terminal State.Domain_invalid_output))));
  check
    "a generic turn failure leaves the streak untouched"
    "none"
    (failed Masc.Keeper_unified_turn.Follow_failure_route);
  check
    "an in-turn handled failure leaves the streak untouched"
    "none"
    (failed Masc.Keeper_unified_turn.Acknowledge_after_in_turn_handling);
  check
    "a completed overflow-free turn resets the streak"
    "recovered"
    (Some (Masc.Keeper_heartbeat_loop_cycle.Completed meta));
  check "no outcome leaves the streak untouched" "none" None
;;

let test_cancelled_and_skipped_cycles_requeue () =
  let lease = lease_for (stimulus "phase-gated" 1.0) in
  let meta = cycle_meta () in
  let settlement outcome =
    Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
      ~base_path:"/tmp/non-approval-cycle"
      ~settled_at:2.0
      ~stop_requested:false
      ~compaction_consecutive_failures:0
      ~lease
      (Some outcome)
  in
  (match settlement (Masc.Keeper_heartbeat_loop_cycle.Cancelled meta) with
   | Masc.Keeper_registry_event_queue.Requeue
       Masc.Keeper_registry_event_queue.Cancelled ->
     ()
   | _ -> Alcotest.fail "supervisor cancellation acknowledged leased work");
  match settlement (Masc.Keeper_heartbeat_loop_cycle.Skipped meta) with
  | Masc.Keeper_registry_event_queue.Requeue
      Masc.Keeper_registry_event_queue.Turn_not_scheduled ->
    ()
  | _ -> Alcotest.fail "non-executable phase acknowledged leased work"
;;

let test_unconsumed_approval_requeues_behind_other_work () =
  List.iter
    (fun reason ->
       let resolution : Queue.hitl_resolution =
         { approval_id = "approval-tail"
         ; decision = Queue.Hitl_approved
         ; channel = Keeper_continuation_channel.unrouted "queue fairness test"
         }
       in
       let approval =
         stimulus
           ~payload:(Queue.Hitl_resolved resolution)
           (Queue.hitl_resolution_post_id resolution)
           1.0
       in
       let board = stimulus "board-next" 2.0 in
       let state = State.with_pending (queue [ approval; board ]) State.empty in
       let state, lease = claim_head state in
       let lease = require_some "approval lease" lease in
       let state, _ =
         State.settle
           ~settled_at:3.0
           ~lease
           ~settlement:(State.Requeue reason)
           state
         |> require_ok "tail requeue approval"
       in
       Alcotest.(check (list string))
         "approval remains durable at the FIFO tail"
         [ "board-next"; Queue.hitl_resolution_post_id resolution ]
         (post_ids (State.pending state));
       let receipt =
         match State.transition_outbox state with
         | [ entry ] -> entry.receipt
         | _ -> Alcotest.fail "approval requeue must create one receipt"
       in
       let state =
         State.mark_transition_projected ~transition_id:receipt.transition_id state
         |> require_ok "project approval requeue"
       in
       let _state, next = claim_head state in
       let next = require_some "next fair lease" next in
       match next.stimuli with
       | [ next ] ->
         Alcotest.(check string)
           "unrelated work leases before the retained approval"
           "board-next"
           next.post_id
       | _ -> Alcotest.fail "fairness fixture expected one leased stimulus")
    [ State.Approval_grant_unconsumed
    ; State.Approval_grant_state_unavailable
    ]
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

(* RFC-0351 S0 / #25539: the approval wake's job is delivery, not
   consumption. A completed turn settles as Ack even while the grant is
   durably unconsumed (8,349 requeue receipts measured across 8 keepers;
   one idealist grant spun 657 times) — and the grant-store-unavailable
   path, the second unbounded loop, also follows the completed turn. A
   turn that did not complete keeps its ordinary typed settlement, so
   delivery is still retried. *)
let test_approved_wake_settles_on_delivery_not_consumption () =
  with_temp_dir "approval-delivery-ack" @@ fun base_path ->
  ignore (Masc.Keeper_approval_queue.install_persistence ~base_path);
  let approval_id =
    match
      Masc.Keeper_approval_queue.submit_pending
        ~keeper_name:"queue-outcome"
        ~tool_name:"external-effect"
        ~input:(`Assoc [ "op", `String "delivery-ack-test" ])
        ~base_path
        ()
    with
    | Ok id -> id
    | Error error ->
      Alcotest.failf
        "approval fixture submit: %s"
        (Masc.Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Masc.Keeper_approval_queue.resolve
       ~base_path
       ~id:approval_id
       ~decision:Masc.Keeper_approval_queue.Decision.Approve
   with
   | Ok () -> ()
   | Error error ->
     Alcotest.failf
       "approval fixture resolve: %s"
       (Masc.Keeper_approval_queue.resolve_error_to_string error));
  (match
     Masc.Keeper_approval_queue.approved_resolution_state
       ~base_path
       ~id:approval_id
   with
   | Ok Masc.Keeper_approval_queue.Resolution_unconsumed -> ()
   | Ok Masc.Keeper_approval_queue.Resolution_consumed ->
     Alcotest.fail "fixture grant is unexpectedly consumed"
   | Error error ->
     Alcotest.failf
       "fixture grant state: %s"
       (Masc.Keeper_approval_queue.grant_error_to_string error));
  let resolution : Queue.hitl_resolution =
    { approval_id
    ; decision = Queue.Hitl_approved
    ; channel = Keeper_continuation_channel.unrouted "delivery ack test"
    }
  in
  let lease =
    lease_for
      (stimulus
         ~payload:(Queue.Hitl_resolved resolution)
         (Queue.hitl_resolution_post_id resolution)
         1.0)
  in
  let settlement ~base_path outcome =
    Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
      ~base_path
      ~settled_at:4.0
      ~stop_requested:false
      ~compaction_consecutive_failures:0
      ~lease
      outcome
  in
  let meta = cycle_meta () in
  (match
     settlement ~base_path (Some (Masc.Keeper_heartbeat_loop_cycle.Completed meta))
   with
   | Masc.Keeper_registry_event_queue.Ack -> ()
   | _ ->
     Alcotest.fail
       "completed turn with an unconsumed grant did not settle as Ack");
  (* Grant survives the Ack: the operator's authorization is not consumed
     by settlement and remains durably spendable. *)
  (match
     Masc.Keeper_approval_queue.approved_resolution_state
       ~base_path
       ~id:approval_id
   with
   | Ok Masc.Keeper_approval_queue.Resolution_unconsumed -> ()
   | Ok Masc.Keeper_approval_queue.Resolution_consumed ->
     Alcotest.fail "settlement consumed the grant"
   | Error error ->
     Alcotest.failf
       "grant state after ack: %s"
       (Masc.Keeper_approval_queue.grant_error_to_string error));
  (* The second unbounded loop: a completed turn whose grant store cannot
     be read must also follow the completed turn instead of requeuing. *)
  (match
     settlement
       ~base_path:(Filename.concat base_path "missing-grant-store")
       (Some (Masc.Keeper_heartbeat_loop_cycle.Completed meta))
   with
   | Masc.Keeper_registry_event_queue.Ack -> ()
   | _ ->
     Alcotest.fail
       "grant-store-unavailable completed turn did not settle as Ack");
  (* An undelivered wake keeps re-entering: a busy cycle still requeues. *)
  match
    settlement
      ~base_path
      (Some
         (Masc.Keeper_heartbeat_loop_cycle.Busy
            { meta
            ; block = Masc.Keeper_turn_admission.Turn_busy None
            }))
  with
  | Masc.Keeper_registry_event_queue.Requeue
      Masc.Keeper_registry_event_queue.Cycle_busy ->
    ()
  | _ -> Alcotest.fail "busy cycle released the undelivered approval wake"
;;


let keeper_dir ~base_path ~keeper_name =
  Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
;;

let write_queue path queue =
  Fs_compat.mkdir_p (Filename.dirname path);
  Queue.queue_to_yojson queue
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path
  |> require_ok ("write fixture " ^ path)
;;

let write_state path state =
  Fs_compat.mkdir_p (Filename.dirname path);
  State.to_yojson state
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path
  |> require_ok ("write fixture " ^ path)
;;

let test_settlement_wal_commit_replay_and_owner_fence () =
  with_temp_dir "keeper-event-queue-settlement-wal" (fun base_path ->
    let keeper_name = "wal_owner" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "wal-source" 1.0))
    |> require_ok "seed WAL owner";
    let lease =
      Persistence.claim_when_result
        ~base_path ~keeper_name ~claimed_at:2.0 ~ready:(fun _ -> true) ()
      |> require_ok "claim WAL source"
      |> require_some "WAL lease"
    in
    let owner_dir = keeper_dir ~base_path ~keeper_name in
    let wal_path = Filename.concat owner_dir "event-queue-settlements.jsonl" in
    Fs_compat.save_file_atomic wal_path "" |> require_ok "create WAL";
    Unix.chmod owner_dir 0o500;
    let outcome =
      Fun.protect
        ~finally:(fun () -> Unix.chmod owner_dir 0o700)
        (fun () ->
           Persistence.settle_result
             ~base_path ~keeper_name ~settled_at:3.0 ~lease ~settlement:State.Ack ())
      |> require_ok "commit with blocked checkpoint"
    in
    (match outcome with
     | Persistence.Committed_followup_failed { stage = `Checkpoint; _ } -> ()
     | _ -> Alcotest.fail "checkpoint failure did not preserve committed outcome");
    let committed_wal = Fs_compat.load_file wal_path in
    Alcotest.(check bool)
      "committed receipt remains in WAL before recovery"
      true
      (not (String.equal committed_wal ""));
    let replayed =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "replay committed WAL suffix"
    in
    Alcotest.(check int) "active lease replayed once" 0 (List.length (State.leases replayed));
    Alcotest.(check string)
      "checkpointed WAL is compacted exactly"
      ""
      (Fs_compat.load_file wal_path);
    let replayed_again =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load after exact WAL compaction"
    in
    Alcotest.(check int64)
      "applied WAL row is not replayed again"
      (State.revision replayed)
      (State.revision replayed_again);
    let peer = "wal_peer" in
    Persistence.update_result ~base_path ~keeper_name:peer (fun pending ->
      Queue.enqueue pending (stimulus "peer-source" 4.0))
    |> require_ok "seed peer owner";
    ignore
      (Persistence.claim_when_result
         ~base_path ~keeper_name:peer ~claimed_at:5.0 ~ready:(fun _ -> true) ()
       |> require_ok "claim peer source"
       |> require_some "peer lease");
    let peer_wal =
      Filename.concat
        (keeper_dir ~base_path ~keeper_name:peer)
        "event-queue-settlements.jsonl"
    in
    Fs_compat.save_file_atomic peer_wal committed_wal
    |> require_ok "copy stale owner WAL";
    match Persistence.load_state_result ~base_path ~keeper_name:peer with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "another Keeper owner's WAL receipt was replayed")
;;

let test_accepted_cancellation_persistence_is_atomic_and_idempotent () =
  with_temp_dir "keeper-event-queue-accepted-cancellation" (fun base_path ->
    let keeper_name = "cancel_owner" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "cancel-source" 1.0))
    |> require_ok "seed cancellation owner";
    let lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:2.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim cancellation source"
      |> require_some "cancellation lease"
    in
    let source_revision =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load cancellation revision"
      |> State.revision
    in
    let cancellation : Persistence.accepted_cancellation =
      { source =
          (match Persistence.lease_stimuli lease with
           | [ source ] -> source
           | _ -> Alcotest.fail "cancellation lease did not retain one source")
      ; source_revision
      ; owner_generation = 7
      ; operator_operation_id = "cancel-operation-1"
      ; reason = "operator rejected paused work"
      }
    in
    let cancel () =
      Persistence.cancel_accepted_result
        ~base_path
        ~keeper_name
        ~current_owner_generation:7
        ~settled_at:3.0
        ~lease
        ~cancellation
        ()
      |> require_ok "commit accepted cancellation"
    in
    let receipt =
      match cancel () with
      | Persistence.Settled receipt -> receipt
      | Persistence.Already_settled _ ->
        Alcotest.fail "first accepted cancellation was already settled"
      | Persistence.Committed_followup_failed { receipt; _ } -> receipt
    in
    (match cancel () with
     | Persistence.Already_settled replayed ->
       Alcotest.(check bool)
         "same operation replays the canonical receipt"
         true
         (State.transition_receipt_equal receipt replayed)
     | Persistence.Settled _ | Persistence.Committed_followup_failed _ ->
       Alcotest.fail "accepted cancellation retry committed twice");
    let settled =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load cancelled owner"
    in
    Alcotest.(check int) "cancelled lease removed" 0 (List.length (State.leases settled));
    Alcotest.(check int)
      "cancelled source retained for projection"
      1
      (List.length (State.transition_outbox settled));
    let stale_keeper = "stale_cancel_owner" in
    Persistence.update_result ~base_path ~keeper_name:stale_keeper (fun pending ->
      Queue.enqueue pending (stimulus "stale-cancel-source" 4.0))
    |> require_ok "seed stale cancellation owner";
    let stale_lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name:stale_keeper
        ~claimed_at:5.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim stale cancellation source"
      |> require_some "stale cancellation lease"
    in
    let stale_revision =
      Persistence.load_state_result ~base_path ~keeper_name:stale_keeper
      |> require_ok "load stale cancellation revision"
      |> State.revision
    in
    let stale_cancellation : Persistence.accepted_cancellation =
      { cancellation with source_revision = Int64.pred stale_revision }
    in
    (match
       Persistence.cancel_accepted_result
         ~base_path
         ~keeper_name:stale_keeper
         ~current_owner_generation:7
         ~settled_at:6.0
         ~lease:stale_lease
         ~cancellation:stale_cancellation
         ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "stale queue revision committed cancellation");
    let unchanged =
      Persistence.load_state_result ~base_path ~keeper_name:stale_keeper
      |> require_ok "load rejected stale cancellation"
    in
    Alcotest.(check int)
      "stale rejection retains active lease"
      1
      (List.length (State.leases unchanged)))
;;

let test_pending_cancellation_wal_replays_before_removal () =
  with_temp_dir "keeper-event-queue-pending-cancellation-wal" (fun base_path ->
    let keeper_name = "pending_cancel_owner" in
    let target = stimulus "pending-cancel-target" 1.0 in
    let peer = stimulus "pending-cancel-peer" 2.0 in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      List.fold_left Queue.enqueue pending [ target; peer ])
    |> require_ok "seed pending cancellation owner";
    let source_revision =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load pending cancellation revision"
      |> State.revision
    in
    let cancellation : Persistence.accepted_cancellation =
      { source = target
      ; source_revision
      ; owner_generation = 17
      ; operator_operation_id = "pending-cancel-operation"
      ; reason = "operator cancelled exact pending work"
      }
    in
    let owner_dir = keeper_dir ~base_path ~keeper_name in
    let wal_path = Filename.concat owner_dir "event-queue-settlements.jsonl" in
    Fs_compat.save_file_atomic wal_path "" |> require_ok "create pending cancellation WAL";
    Unix.chmod owner_dir 0o500;
    let committed =
      Fun.protect
        ~finally:(fun () -> Unix.chmod owner_dir 0o700)
        (fun () ->
           Persistence.cancel_pending_accepted_result
             ~base_path
             ~keeper_name
             ~current_owner_generation:17
             ~settled_at:3.0
             ~cancellation
             ())
      |> require_ok "commit pending cancellation with blocked checkpoint"
    in
    (match committed with
     | Persistence.Committed_followup_failed { stage = `Checkpoint; _ } -> ()
     | Persistence.Settled _ | Persistence.Already_settled _
     | Persistence.Committed_followup_failed _ ->
       Alcotest.fail "blocked checkpoint did not preserve committed WAL outcome");
    let wal_json =
      Fs_compat.load_file wal_path
      |> String.trim
      |> Yojson.Safe.from_string
    in
    Alcotest.(check string)
      "source-bearing WAL schema"
      "masc.keeper_event_queue.settlement.v2"
      Yojson.Safe.Util.(wal_json |> member "schema" |> to_string);
    let replayed =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "replay pending cancellation WAL"
    in
    Alcotest.(check (list string))
      "WAL replay removes only the exact pending source"
      [ "pending-cancel-peer" ]
      (post_ids (State.pending replayed));
    Alcotest.(check int) "WAL replay leaves no synthetic lease" 0 (List.length (State.leases replayed));
    (match State.transition_outbox replayed with
     | [ entry ] ->
       Alcotest.(check bool) "WAL replay retains exact source" true (entry.stimuli = [ target ])
     | _ -> Alcotest.fail "WAL replay did not restore one outbox entry");
    Alcotest.(check string)
      "checkpointed source-bearing WAL is compacted"
      ""
      (Fs_compat.load_file wal_path);
    match
      Persistence.cancel_pending_accepted_result
        ~base_path
        ~keeper_name
        ~current_owner_generation:999
        ~settled_at:4.0
        ~cancellation
        ()
    with
    | Ok (Persistence.Already_settled _) -> ()
    | Ok _ -> Alcotest.fail "pending cancellation retry committed twice"
    | Error detail -> Alcotest.failf "committed pending cancellation did not replay: %s" detail)
;;

let test_legacy_settlement_wal_v1_remains_replayable () =
  with_temp_dir "keeper-event-queue-legacy-settlement-wal" (fun base_path ->
    let keeper_name = "legacy_wal_owner" in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "legacy-wal-source" 1.0))
    |> require_ok "seed legacy WAL owner";
    let lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:2.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim legacy WAL source"
      |> require_some "legacy WAL lease"
    in
    let claimed =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load legacy WAL pre-settlement state"
    in
    let receipt =
      match
        State.settle ~settled_at:3.0 ~lease ~settlement:State.Ack claimed
        |> require_ok "construct legacy WAL receipt"
      with
      | _, State.Settled receipt -> receipt
      | _, State.Already_settled _ -> Alcotest.fail "legacy WAL fixture replayed early"
    in
    let wal_path =
      Filename.concat
        (keeper_dir ~base_path ~keeper_name)
        "event-queue-settlements.jsonl"
    in
    let row =
      `Assoc
        [ "schema", `String "masc.keeper_event_queue.settlement.v1"
        ; "base_path", `String (Unix.realpath base_path)
        ; "keeper_name", `String keeper_name
        ; "receipt", State.transition_receipt_to_yojson receipt
        ]
      |> Yojson.Safe.to_string
      |> fun row -> row ^ "\n"
    in
    Fs_compat.save_file_atomic wal_path row |> require_ok "write legacy WAL row";
    let replayed =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "replay legacy WAL row"
    in
    Alcotest.(check int) "legacy WAL settles active lease" 0 (List.length (State.leases replayed));
    Alcotest.(check int)
      "legacy WAL recreates transition outbox"
      1
      (List.length (State.transition_outbox replayed));
    Alcotest.(check string)
      "legacy WAL is compacted after checkpoint"
      ""
      (Fs_compat.load_file wal_path))
;;

let test_context_compaction_retry_is_durable_and_lane_local () =
  with_temp_dir "keeper-event-queue-v2-retry-tail" (fun base_path ->
    let keeper_name = "retry_tail_keeper" in
    let peer_keeper_name = "independent_peer_keeper" in
    let source =
      stimulus
        ~payload:
          (Queue.Connector_attention
             { event_id = "connector-event-17"
             ; channel = Keeper_continuation_channel.unrouted "retry tail fixture"
             })
        "connector-source"
        1.25
    in
    let unrelated = stimulus "unrelated-board-work" 2.5 in
    let peer_work = stimulus "independent-peer-work" 2.75 in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      List.fold_left Queue.enqueue pending [ source; unrelated ])
    |> require_ok "seed retry tail queue";
    Persistence.update_result ~base_path ~keeper_name:peer_keeper_name (fun pending ->
      Queue.enqueue pending peer_work)
    |> require_ok "seed independent peer lane";
    let lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:3.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim retryable source"
      |> require_some "retryable source lease"
    in
    let receipt =
      match
        Persistence.settle_result
          ~base_path
          ~keeper_name
          ~settled_at:4.0
          ~lease
          ~settlement:(State.Requeue State.Context_compaction_retry)
          ()
        |> require_ok "settle context-compacted source"
      with
      | Persistence.Settled receipt -> receipt
      | _ ->
        Alcotest.fail "first retryable settlement was already settled"
    in
    let peer_lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name:peer_keeper_name
        ~claimed_at:4.5
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim peer while owner projection is pending"
      |> require_some "independent peer lease"
    in
    (match Persistence.lease_stimuli peer_lease with
     | [ claimed ] ->
       Alcotest.(check bool)
         "owner compaction transition does not block peer lane"
         true
         (Queue.stimulus_identity_equal peer_work claimed)
     | _ -> Alcotest.fail "peer lane claim changed the stimulus set");
    let restored =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "restore retryable state"
    in
    (match Queue.to_list (State.pending restored) with
     | [ next; retained ] ->
       Alcotest.(check string)
         "unrelated same-lane work remains first"
         unrelated.post_id
         next.post_id;
       Alcotest.(check bool)
         "restart restores the exact retained stimulus"
         true
         (Yojson.Safe.equal
            (Queue.stimulus_to_yojson source)
            (Queue.stimulus_to_yojson retained))
     | _ -> Alcotest.fail "retryable settlement did not restore two pending stimuli");
    let outbox_entry =
      match State.transition_outbox restored with
      | [ entry ] -> entry
      | _ -> Alcotest.fail "retryable settlement must retain one transition receipt"
    in
    (match outbox_entry.receipt.settlement with
     | State.Requeue State.Context_compaction_retry -> ()
     | _ -> Alcotest.fail "compaction transition lost its typed requeue reason");
    (match outbox_entry.stimuli with
     | [ retained ] ->
       Alcotest.(check bool)
         "transition outbox retains the exact leased stimulus"
         true
         (Yojson.Safe.equal
            (Queue.stimulus_to_yojson source)
            (Queue.stimulus_to_yojson retained))
     | _ -> Alcotest.fail "retryable transition changed the leased stimulus set");
    Persistence.mark_transition_projected_result
      ~base_path
      ~keeper_name
      ~transition_id:receipt.transition_id
    |> require_ok "project retryable transition";
    let next_lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:5.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim unrelated work after retry"
      |> require_some "unrelated work lease"
    in
    (match Persistence.lease_stimuli next_lease with
     | [ next ] ->
       Alcotest.(check string)
         "unrelated work leases before the retained retry"
         unrelated.post_id
         next.post_id
     | _ -> Alcotest.fail "retry fairness fixture expected one leased stimulus");
    let after_next_claim =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "reload retained retry after unrelated claim"
    in
    match Queue.to_list (State.pending after_next_claim) with
    | [ retained ] ->
      Alcotest.(check bool)
        "retained retry survives the next same-lane claim"
        true
        (Yojson.Safe.equal
           (Queue.stimulus_to_yojson source)
           (Queue.stimulus_to_yojson retained))
    | _ -> Alcotest.fail "retained retry was not left pending after peer work claimed")
;;

let test_unsupported_snapshots_fail_closed () =
  with_temp_dir "keeper-event-queue-v3-hardcut" (fun base_path ->
    let keeper_name = "hardcut_keeper" in
    let dir = keeper_dir ~base_path ~keeper_name in
    let primary = Filename.concat dir "event-queue.json" in
    let unsupported = Filename.concat dir "event-queue-inflight.json" in
    write_state
      primary
      (State.with_pending (queue [ stimulus "pending" 1.0 ]) State.empty);
    write_queue unsupported (queue [ stimulus "obsolete" 2.0 ]);
    (match Persistence.load_state_result ~base_path ~keeper_name with
     | Error message ->
       Alcotest.(check bool)
         "unsupported sidecar is named"
         true
         (String.starts_with ~prefix:"unsupported event queue sidecar remains" message)
     | Ok _ -> Alcotest.fail "current state silently accepted unsupported sidecar");
    Alcotest.(check bool)
      "hard cut does not delete unsupported input"
      true
      (Sys.file_exists unsupported);
    Sys.remove unsupported;
    write_queue primary (queue [ stimulus "old-schema" 3.0 ]);
    (match Persistence.load_state_result ~base_path ~keeper_name with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "old primary schema was migrated"))
;;

let test_v3_snapshot_upgrades_only_without_active_lease () =
  with_temp_dir "keeper-event-queue-v3-upgrade" (fun base_path ->
    let keeper_name = "v3_upgrade_keeper" in
    let path = Filename.concat (keeper_dir ~base_path ~keeper_name) "event-queue.json" in
    let v3_of_state state =
      match State.to_yojson state with
      | `Assoc fields ->
        `Assoc
          (("schema", `String "keeper.event_queue.state.v3")
           :: List.filter
                (fun (name, _) ->
                   not
                     (String.equal name "schema"
                      || String.equal name "accepted_transfer_projections"
                      || String.equal name "exact_execution_bindings"))
                fields)
      | _ -> Alcotest.fail "current event queue state codec is not an object"
    in
    let v3 = v3_of_state State.empty in
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic path (Yojson.Safe.to_string v3)
    |> require_ok "write strict v3 predecessor";
    let upgraded =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load strict v3 predecessor"
    in
    Alcotest.(check int)
      "v3 starts with no target transfer accounting"
      0
      (List.length (State.accepted_transfer_projections upgraded));
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending (stimulus "upgrade" 1.0))
    |> require_ok "mutate upgraded queue";
    let persisted =
      Safe_ops.read_json_file_safe path |> require_ok "read upgraded queue"
    in
    let open Yojson.Safe.Util in
    Alcotest.(check string)
      "next durable write uses v4"
      "keeper.event_queue.state.v4"
      (persisted |> member "schema" |> to_string);
    let claimed, lease =
      State.with_pending (queue [ stimulus "possibly-dispatched" 2.0 ]) State.empty
      |> claim_head
    in
    ignore (require_some "legacy active lease" lease : State.lease);
    match State.of_yojson (v3_of_state claimed) with
    | Error _ -> ()
    | Ok _ ->
      Alcotest.fail
        "legacy active lease was promoted without exact execution bindings")
;;

let test_transition_outbox_projects_with_stable_identity () =
  with_temp_dir "keeper-event-queue-v2-outbox" (fun base_path ->
    let keeper_name = "projection_keeper" in
    let source = stimulus "projected-source" 1.0 in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending source)
    |> require_ok "seed projection source";
    let lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name
        ~claimed_at:2.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim projection source"
      |> require_some "projection lease"
    in
    (match
       Persistence.enqueue_stimulus_if_absent_result
         ~base_path ~keeper_name source
       |> require_ok "dedupe active lease"
     with
     | Persistence.Already_present -> ()
     | Persistence.Enqueued -> Alcotest.fail "active lease was duplicated");
    (match
        Persistence.settle_result
          ~base_path
          ~keeper_name
          ~settled_at:3.0
          ~lease
          ~settlement:State.Ack
          ()
        |> require_ok "settle projection source"
      with
      | Persistence.Settled _ -> ()
      | _ ->
        Alcotest.fail "first projection settlement was already settled");
    (match
       Persistence.enqueue_stimulus_if_absent_result
         ~base_path ~keeper_name source
       |> require_ok "dedupe transition outbox"
     with
     | Persistence.Already_present -> ()
     | Persistence.Enqueued -> Alcotest.fail "outbox stimulus was duplicated");
    Masc.Keeper_heartbeat_loop.project_transition_outbox ~base_path ~keeper_name
    |> require_ok "project transition outbox";
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load projected state"
    in
    Alcotest.(check int)
      "projection retires outbox"
      0
      (List.length (State.transition_outbox state));
    Masc.Keeper_heartbeat_loop.project_transition_outbox ~base_path ~keeper_name
    |> require_ok "empty outbox projection is idempotent";
    let summary =
      Masc.Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~limit:20
    in
    let open Yojson.Safe.Util in
    Alcotest.(check int)
      "stable event id deduplicates crash replay"
      1
      (summary |> member "event_queue_ack_count" |> to_int);
    ())
;;

let test_registration_preparation_is_atomic_and_fail_closed () =
  with_temp_dir "keeper-event-queue-v2-registration" (fun base_path ->
    let keeper_name = "registration_keeper" in
    let source = stimulus "abandoned" 1.0 in
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending source)
    |> require_ok "seed registration source";
    ignore
      (Persistence.claim_when_result
         ~base_path
         ~keeper_name
         ~claimed_at:2.0
         ~ready:(fun _ -> true)
         ()
       |> require_ok "claim registration source"
       |> require_some "registration lease");
    let pending =
      Persistence.prepare_registration_result
        ~base_path
        ~keeper_name
        ~settled_at:3.0
        ()
      |> require_ok "prepare registration"
    in
    Alcotest.(check (list string))
      "abandoned lease returned to pending"
      [ "abandoned" ]
      (post_ids pending);
    let prepared =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load prepared registration state"
    in
    Alcotest.(check int) "registration leaves no active lease" 0 (List.length (State.leases prepared));
    Alcotest.(check int)
      "registration records one recovery transition"
      1
      (List.length (State.transition_outbox prepared));
    let prepared_revision = State.revision prepared in
    ignore
      (Persistence.prepare_registration_result
         ~base_path
         ~keeper_name
         ~settled_at:4.0
         ()
       |> require_ok "repeat prepared registration");
    let repeated =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load repeated registration state"
    in
    Alcotest.(check int64)
      "repeat registration does not synthesize a transition"
      prepared_revision
      (State.revision repeated);
    Alcotest.(check int)
      "repeat registration retains one recovery transition"
      1
      (List.length (State.transition_outbox repeated));

    let malformed_keeper = "malformed_registration_keeper" in
    let malformed_path =
      Filename.concat
        (keeper_dir ~base_path ~keeper_name:malformed_keeper)
        "event-queue.json"
    in
    Fs_compat.mkdir_p (Filename.dirname malformed_path);
    Fs_compat.save_file_atomic malformed_path "{}"
    |> require_ok "write malformed registration state";
    (match
       Persistence.prepare_registration_result
         ~base_path
         ~keeper_name:malformed_keeper
         ~settled_at:5.0
         ()
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "malformed registration state became an empty queue"))
;;

let test_failed_owner_write_does_not_block_peer_lane () =
  with_temp_dir "keeper-event-queue-v2-fault" (fun base_path ->
    let broken = "broken_lane" in
    let peer = "peer_lane" in
    Persistence.update_result ~base_path ~keeper_name:broken (fun queue ->
      Queue.enqueue queue (stimulus "broken-pending" 1.0))
    |> require_ok "seed broken lane";
    let broken_dir = keeper_dir ~base_path ~keeper_name:broken in
    Unix.chmod broken_dir 0o500;
    Fun.protect
      ~finally:(fun () -> Unix.chmod broken_dir 0o700)
      (fun () ->
         (match
            Persistence.claim_when_result
              ~base_path
              ~keeper_name:broken
              ~claimed_at:2.0
              ~ready:(fun _ -> true)
              ()
          with
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "unwritable owner reported a committed claim");
         Persistence.update_result ~base_path ~keeper_name:peer (fun queue ->
           Queue.enqueue queue (stimulus "peer-pending" 2.0))
         |> require_ok "peer lane remains independently writable");
    Alcotest.(check (list string))
      "failed claim left durable pending unchanged"
      [ "broken-pending" ]
      (Persistence.load_pending ~base_path ~keeper_name:broken |> post_ids);
    Alcotest.(check (list string))
      "peer committed independently"
      [ "peer-pending" ]
      (Persistence.load_pending ~base_path ~keeper_name:peer |> post_ids))
;;

let () =
  Alcotest.run
    "keeper event queue v2"
    [ ( "state"
      , [ Alcotest.test_case "claim codec ack idempotency" `Quick test_claim_codec_ack_idempotency
        ; Alcotest.test_case
            "canonical receipt replay"
            `Quick
            test_canonical_receipt_replay
        ; Alcotest.test_case
            "receipt codec is closed and finite"
            `Quick
            test_receipt_codec_is_closed_and_finite
        ; Alcotest.test_case
            "no-compaction terminal consumes exact request"
            `Quick
            test_no_compaction_terminal_consumes_exact_request
        ; Alcotest.test_case
            "no-compaction rejects scheduled product work"
            `Quick
            test_no_compaction_rejects_scheduled_product_work
        ; Alcotest.test_case
            "accepted cancellation is exact and owner-fenced"
            `Quick
            test_accepted_cancellation_is_exact_owner_fenced_terminal
        ; Alcotest.test_case
            "accepted cancellation rejects stale fences"
            `Quick
            test_accepted_cancellation_rejects_stale_fences
        ; Alcotest.test_case
            "pending accepted cancellation is exact and source-bound"
            `Quick
            test_pending_accepted_cancellation_is_exact_and_source_bound
        ; Alcotest.test_case
            "claim earliest ready without reordering"
            `Quick
            test_claim_leases_earliest_ready_without_reordering_skipped_work
        ; Alcotest.test_case "requeue and escalation" `Quick test_requeue_and_escalation_are_total
        ; Alcotest.test_case
            "judgment terminal evidence"
            `Quick
            test_judgment_terminal_evidence_is_durable
        ; Alcotest.test_case "failed cycle route mapping" `Quick test_failed_cycle_route_mapping
        ; Alcotest.test_case
            "applied compaction settles follow-up atomically"
            `Quick
            test_applied_compaction_settles_followup_atomically
        ; Alcotest.test_case
            "manual no-compaction is terminal but overflow escalates"
            `Quick
            test_manual_no_compaction_is_terminal_but_overflow_escalates
        ; Alcotest.test_case
            "exact-output terminal reasons round-trip"
            `Quick
            test_exact_output_terminal_reasons_round_trip
        ; Alcotest.test_case
            "exact terminal codec rejects missing or blank call identity"
            `Quick
            test_exact_terminal_codec_rejects_missing_or_blank_call_identity
        ; Alcotest.test_case
            "cancelled exact terminal consumes the queue durably"
            `Quick
            test_cancelled_exact_terminal_consumes_queue_durably
        ; Alcotest.test_case
            "cancelled and skipped cycles requeue"
            `Quick
            test_cancelled_and_skipped_cycles_requeue
        ; Alcotest.test_case
            "compaction retry escalates after threshold"
            `Quick
            test_compaction_retry_escalates_after_threshold
        ; Alcotest.test_case
            "in-lane compaction streak bounds retries"
            `Quick
            test_in_lane_compaction_streak_bounds_retries
        ; Alcotest.test_case
            "compaction outcome mapping covers in-lane dispositions"
            `Quick
            test_compaction_outcome_mapping_covers_in_lane_dispositions
        ; Alcotest.test_case
            "approved wake settles on delivery not consumption"
            `Quick
            test_approved_wake_settles_on_delivery_not_consumption
        ; Alcotest.test_case
            "unconsumed approval yields FIFO"
            `Quick
            test_unconsumed_approval_requeues_behind_other_work
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case
            "context compaction retry is durable and lane-local"
            `Quick
            test_context_compaction_retry_is_durable_and_lane_local
        ; Alcotest.test_case
            "settlement WAL commit replay and owner fence"
            `Quick
            test_settlement_wal_commit_replay_and_owner_fence
        ; Alcotest.test_case
            "accepted cancellation persistence is atomic and idempotent"
            `Quick
            test_accepted_cancellation_persistence_is_atomic_and_idempotent
        ; Alcotest.test_case
            "pending cancellation WAL replays before removal"
            `Quick
            test_pending_cancellation_wal_replays_before_removal
        ; Alcotest.test_case
            "legacy settlement WAL v1 remains replayable"
            `Quick
            test_legacy_settlement_wal_v1_remains_replayable
        ; Alcotest.test_case
            "unsupported snapshots fail closed"
            `Quick
            test_unsupported_snapshots_fail_closed
        ; Alcotest.test_case
            "v3 upgrades only without an active lease"
            `Quick
            test_v3_snapshot_upgrades_only_without_active_lease
        ; Alcotest.test_case
            "transition outbox projection"
            `Quick
            test_transition_outbox_projects_with_stable_identity
        ; Alcotest.test_case
            "registration preparation"
            `Quick
            test_registration_preparation_is_atomic_and_fail_closed
        ; Alcotest.test_case
            "lane write fault isolation"
            `Quick
            test_failed_owner_write_does_not_block_peer_lane
        ; Alcotest.test_case
            "no-compaction decode rejects mismatched stimulus"
            `Quick
            test_no_compaction_decode_rejects_mismatched_stimulus
        ] )
    ]
;;
