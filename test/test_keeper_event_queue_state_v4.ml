module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence

let codec_keeper_name = "event_queue_state_test_keeper"
let codec_owner_base_path = "/event-queue-state-test"

let state_to_yojson =
  State.to_yojson
    ~owner_base_path:codec_owner_base_path
    ~keeper_name:codec_keeper_name
;;

let state_of_yojson =
  State.of_yojson
    ~expected_owner_base_path:codec_owner_base_path
    ~expected_keeper_name:codec_keeper_name
;;

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

let test_snapshot_codec_rejects_cross_owner_copy () =
  let json = state_to_yojson State.empty in
  (match
     State.of_yojson
       ~expected_owner_base_path:"/different-base"
       ~expected_keeper_name:codec_keeper_name
       json
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "cross-BasePath queue snapshot was accepted");
  match
    State.of_yojson
      ~expected_owner_base_path:codec_owner_base_path
      ~expected_keeper_name:"different-keeper"
      json
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "cross-Keeper queue snapshot was accepted"
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
    state_to_yojson state |> state_of_yojson |> require_ok "v4 codec roundtrip"
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
    (state_to_yojson settled |> Yojson.Safe.to_string)
    (state_to_yojson replayed |> Yojson.Safe.to_string);
  let repeated =
    State.replay_transition_receipt decoded replayed
    |> require_ok "replay canonical receipt idempotently"
  in
  Alcotest.(check string)
    "idempotent replay preserves state"
    (state_to_yojson replayed |> Yojson.Safe.to_string)
    (state_to_yojson repeated |> Yojson.Safe.to_string);
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
    state_to_yojson state
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
    state_to_yojson state
    |> state_of_yojson
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
    state_to_yojson state
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
       handled_failure
   with
   | Masc.Keeper_registry_event_queue.Ack -> ()
   | _ -> Alcotest.fail "in-turn handled terminal failure was retried");
  let compacted_failure =
    { judgment_failure with
      source_lease_disposition =
        Masc.Keeper_unified_turn.Requeue_after_context_compaction
    }
  in
  match
    Masc.Keeper_heartbeat_loop.settlement_of_failure
      ~settled_at:7.0
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

let test_cancelled_and_skipped_cycles_requeue () =
  let lease = lease_for (stimulus "phase-gated" 1.0) in
  let meta = cycle_meta () in
  let settlement outcome =
    Masc.Keeper_heartbeat_loop.settlement_of_cycle_outcome
      ~base_path:"/tmp/non-approval-cycle"
      ~settled_at:2.0
      ~stop_requested:false
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

let keeper_dir ~base_path ~keeper_name =
  Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name
;;

let write_state ~base_path ~keeper_name path state =
  Fs_compat.mkdir_p (Filename.dirname path);
  let owner_base_path =
    Config_dir_resolver.canonical_base_path base_path
    |> function
    | Ok base_path -> base_path
    | Error error ->
      Alcotest.fail
        (Config_dir_resolver.canonical_base_path_error_to_string error)
  in
  State.to_yojson ~owner_base_path ~keeper_name state
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path
  |> require_ok ("write fixture " ^ path)
;;

let write_bytes path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path bytes
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
    let wal_path = Filename.concat owner_dir "event-queue-v4-settlements.jsonl" in
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
        "event-queue-v4-settlements.jsonl"
    in
    Fs_compat.save_file_atomic peer_wal committed_wal
    |> require_ok "copy stale owner WAL";
    match Persistence.load_state_result ~base_path ~keeper_name:peer with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "another Keeper owner's WAL receipt was replayed")
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

let test_retired_epoch_is_quarantined_while_v4_continues () =
  with_temp_dir "keeper-event-queue-v4-epoch" (fun base_path ->
    let keeper_name = "epoch_cutover_keeper" in
    let dir = keeper_dir ~base_path ~keeper_name in
    let retired_snapshot = Filename.concat dir "event-queue.json" in
    let retired_wal = Filename.concat dir "event-queue-settlements.jsonl" in
    let retired_inflight = Filename.concat dir "event-queue-inflight.json" in
    let current_snapshot = Filename.concat dir "event-queue-v4.json" in
    let current_wal = Filename.concat dir "event-queue-v4-settlements.jsonl" in
    let retired_stimulus = stimulus "retired-work" 1.0 in
    let retired_queue =
      `Assoc
        [ "schema", `String "keeper.event_queue.v2"
        ; "length", `Int 1
        ; "items", `List [ Queue.stimulus_to_yojson retired_stimulus ]
        ]
    in
    let retired_snapshot_bytes =
      `Assoc
        [ "schema", `String "keeper.event_queue.state.v3"
        ; "revision", `Int 7
        ; "next_lease_sequence", `Int 8
        ; "pending", retired_queue
        ; "leases", `List []
        ; "last_settlement", `Null
        ; "transition_outbox", `List []
        ]
      |> Yojson.Safe.pretty_to_string
    in
    let retired_wal_bytes = "retired WAL bytes are quarantine evidence\n" in
    let retired_inflight_bytes = Yojson.Safe.pretty_to_string retired_queue in
    write_bytes retired_snapshot retired_snapshot_bytes;
    write_bytes retired_wal retired_wal_bytes;
    write_bytes retired_inflight retired_inflight_bytes;

    let discovery =
      Persistence.discover_keeper_names_with_snapshots ~base_path
    in
    Alcotest.(check (list string))
      "retired-only Keeper remains discoverable"
      [ keeper_name ]
      discovery.keeper_names;
    Alcotest.(check (option string))
      "retired evidence discovery is readable"
      None
      discovery.read_error;

    let empty_current =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load absent v4 authority"
    in
    Alcotest.(check int)
      "retired work is never loaded"
      0
      (Queue.length (State.pending empty_current));
    Alcotest.(check bool)
      "read-only empty load does not synthesize v4 authority"
      false
      (Sys.file_exists current_snapshot);
    let before = Persistence.observe_snapshot ~base_path ~keeper_name in
    let before_generation =
      require_some "empty v4 source generation" before.source_generation
    in
    Alcotest.(check bool)
      "absent v4 snapshot is a known empty authority"
      false
      before_generation.snapshot_present;
    Alcotest.(check int64)
      "empty v4 revision is known"
      0L
      before_generation.observed_revision;
    Alcotest.(check int)
      "all retired files are explicit residue"
      3
      (List.length before.read_errors);
    Alcotest.(check bool)
      "retired residue is typed"
      true
      (List.for_all
         (fun (error : Persistence.snapshot_read_error) ->
            match error.kind with
            | Persistence.Retired_epoch_residue -> true
            | Persistence.Invalid_path
            | Persistence.Read_failed
            | Persistence.Parse_failed -> false)
         before.read_errors);
    let observed_paths =
      List.filter_map
        (fun (error : Persistence.snapshot_read_error) -> error.path)
        before.read_errors
      |> List.sort String.compare
    in
    Alcotest.(check (list string))
      "residue evidence keeps exact paths"
      (List.sort String.compare [ retired_snapshot; retired_wal; retired_inflight ])
      observed_paths;

    let current_stimulus = stimulus "current-work" 2.0 in
    (match
       Persistence.enqueue_stimulus_if_absent_result
         ~base_path
         ~keeper_name
         current_stimulus
       |> require_ok "enqueue current v4 work"
     with
     | Persistence.Enqueued _ -> ()
     | Persistence.Already_present _ ->
       Alcotest.fail "empty v4 authority reported current work already present");
    Alcotest.(check bool)
      "enqueue writes the v4 snapshot"
      true
      (Sys.file_exists current_snapshot);
    Alcotest.(check bool)
      "enqueue does not synthesize a v4 settlement WAL"
      false
      (Sys.file_exists current_wal);
    Alcotest.(check string)
      "retired v3 snapshot remains byte-identical"
      retired_snapshot_bytes
      (Fs_compat.load_file retired_snapshot);
    Alcotest.(check string)
      "retired settlement WAL remains byte-identical"
      retired_wal_bytes
      (Fs_compat.load_file retired_wal);
    Alcotest.(check string)
      "retired inflight sidecar remains byte-identical"
      retired_inflight_bytes
      (Fs_compat.load_file retired_inflight);
    let current =
      Persistence.load_result ~base_path ~keeper_name
      |> require_ok "load current v4 work"
    in
    Alcotest.(check (list string))
      "load projects only current work"
      [ "current-work" ]
      (post_ids current);
    let after = Persistence.observe_snapshot ~base_path ~keeper_name in
    let after_generation =
      require_some "readable v4 generation with residue" after.source_generation
    in
    Alcotest.(check bool)
      "readable current snapshot remains known despite residue"
      true
      after_generation.snapshot_present;
    Alcotest.(check (list string))
      "observation projects only current work"
      [ "current-work" ]
      (post_ids after.pending);
    Alcotest.(check int)
      "residue errors coexist with current generation"
      3
      (List.length after.read_errors);
    let encoded_residue =
      match after.read_errors with
      | error :: _ -> Persistence.snapshot_read_error_to_yojson error
      | [] -> Alcotest.fail "retired residue encoding fixture is empty"
    in
    let fleet = Persistence.fleet_summary_json ~now:3.0 ~base_path in
    let open Yojson.Safe.Util in
    Alcotest.(check bool)
      "typed residue requires operator action"
      true
      (encoded_residue |> member "operator_action_required" |> to_bool);
    Alcotest.(check bool)
      "typed residue keeps a concrete path"
      true
      (encoded_residue |> member "path" <> `Null);
    Alcotest.(check string)
      "dashboard reports residue degradation"
      "degraded"
      (fleet |> member "status" |> to_string);
    Alcotest.(check bool)
      "current counts remain complete"
      true
      (fleet |> member "counts_complete" |> to_bool);
    Alcotest.(check int)
      "dashboard counts only current work"
      1
      (fleet |> member "pending_count" |> to_int);
    Alcotest.(check bool)
      "dashboard requests operator disposition"
      true
      (fleet |> member "operator_action_required" |> to_bool))
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
    let retry_candidate = { source with arrived_at = 99.0 } in
    (match
       Persistence.enqueue_stimulus_if_absent_result
         ~base_path ~keeper_name retry_candidate
       |> require_ok "dedupe active lease"
     with
     | Persistence.Already_present committed ->
       Alcotest.(check (float 0.0))
         "active lease returns its committed arrival"
         source.arrived_at
         committed.arrived_at
     | Persistence.Enqueued _ -> Alcotest.fail "active lease was duplicated");
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
     | _ -> Alcotest.fail "first projection settlement was already settled");
    let unprojected_state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load unprojected state"
    in
    (match
       Persistence.enqueue_stimulus_if_absent_result
         ~base_path ~keeper_name retry_candidate
       |> require_ok "dedupe transition outbox"
     with
     | Persistence.Already_present committed ->
       Alcotest.(check (float 0.0))
         "outbox returns its committed arrival"
         source.arrived_at
         committed.arrived_at
     | Persistence.Enqueued _ -> Alcotest.fail "outbox stimulus was duplicated");
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
    write_state
      ~base_path
      ~keeper_name
      (Filename.concat (keeper_dir ~base_path ~keeper_name) "event-queue-v4.json")
      unprojected_state;
    Masc.Keeper_heartbeat_loop.project_transition_outbox ~base_path ~keeper_name
    |> require_ok "replay committed transition after outbox retirement loss";
    let summary =
      Masc.Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~pending_id_display_limit:20
    in
    let open Yojson.Safe.Util in
    Alcotest.(check int)
      "stable event id deduplicates crash replay"
      1
      (summary |> member "event_queue_ack_count" |> to_int);
    let replayed_state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load replayed projection state"
    in
    Alcotest.(check int)
      "replayed projection retires restored outbox"
      0
      (List.length (State.transition_outbox replayed_state));
    Masc.Keeper_heartbeat_loop.project_transition_outbox ~base_path ~keeper_name
    |> require_ok "empty outbox projection is idempotent")
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
        "event-queue-v4.json"
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
      (Persistence.load_pending_result ~base_path ~keeper_name:broken
       |> require_ok "load failed-owner pending queue"
       |> post_ids);
    Alcotest.(check (list string))
      "peer committed independently"
      [ "peer-pending" ]
      (Persistence.load_pending_result ~base_path ~keeper_name:peer
       |> require_ok "load peer pending queue"
       |> post_ids))
;;

let () =
  Alcotest.run
    "keeper event queue v4"
    [ ( "state"
      , [ Alcotest.test_case "claim codec ack idempotency" `Quick test_claim_codec_ack_idempotency
        ; Alcotest.test_case
            "snapshot codec rejects cross-owner copy"
            `Quick
            test_snapshot_codec_rejects_cross_owner_copy
        ; Alcotest.test_case
            "canonical receipt replay"
            `Quick
            test_canonical_receipt_replay
        ; Alcotest.test_case
            "receipt codec is closed and finite"
            `Quick
            test_receipt_codec_is_closed_and_finite
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
            "cancelled and skipped cycles requeue"
            `Quick
            test_cancelled_and_skipped_cycles_requeue
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
            "retired epoch is quarantined while v4 continues"
            `Quick
            test_retired_epoch_is_quarantined_while_v4_continues
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
        ] )
    ]
;;
