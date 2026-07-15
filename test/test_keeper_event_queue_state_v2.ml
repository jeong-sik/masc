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
   | _ -> Alcotest.fail "in-turn handled terminal failure was retried")
;;

let cycle_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String "queue-outcome"
        ; "agent_name", `String "agent-queue-outcome"
        ; "trace_id", `String "trace-queue-outcome"
        ; "goal", `String "verify typed event queue outcomes"
        ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.failf "cycle meta fixture: %s" message
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

let write_queue path queue =
  Fs_compat.mkdir_p (Filename.dirname path);
  Queue.queue_to_yojson queue
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path
  |> require_ok ("write fixture " ^ path)
;;

let read_schema path =
  match Safe_ops.read_json_file_safe path with
  | Error message -> Alcotest.failf "read migrated state: %s" message
  | Ok (`Assoc fields) ->
    (match List.assoc_opt "schema" fields with
     | Some (`String schema) -> schema
     | _ -> Alcotest.fail "migrated state lacks schema")
  | Ok _ -> Alcotest.fail "migrated state is not an object"
;;

let test_retryable_failure_restores_exact_stimulus_at_fifo_tail () =
  with_temp_dir "keeper-event-queue-v2-retry-tail" (fun base_path ->
    let keeper_name = "retry_tail_keeper" in
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
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      List.fold_left Queue.enqueue pending [ source; unrelated ])
    |> require_ok "seed retry tail queue";
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
          ~settlement:(State.Requeue State.Retry_after_observed)
          ()
        |> require_ok "settle retryable source"
      with
      | Persistence.Settled receipt -> receipt
      | Persistence.Already_settled _ ->
        Alcotest.fail "first retryable settlement was already settled"
    in
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
     | State.Requeue State.Retry_after_observed -> ()
     | _ -> Alcotest.fail "retryable transition lost its typed requeue reason");
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

let test_legacy_pair_migrates_once () =
  with_temp_dir "keeper-event-queue-v2-migration" (fun base_path ->
    let keeper_name = "migration_keeper" in
    let dir = keeper_dir ~base_path ~keeper_name in
    let primary = Filename.concat dir "event-queue.json" in
    let legacy = Filename.concat dir "event-queue-inflight.json" in
    write_queue primary (queue [ stimulus "pending" 1.0 ]);
    write_queue legacy (queue [ stimulus "leased" 2.0 ]);
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "migrate legacy pair"
    in
    Alcotest.(check string) "primary became v2" State.schema (read_schema primary);
    Alcotest.(check bool) "legacy input removed" false (Sys.file_exists legacy);
    Alcotest.(check (list string))
      "legacy lease recovered before publication"
      [ "leased"; "pending" ]
      (post_ids (State.pending state));
    Alcotest.(check int) "no abandoned lease survives migration" 0 (List.length (State.leases state));
    Alcotest.(check int)
      "migration recovery receipt retained"
      1
      (List.length (State.transition_outbox state));
    write_queue legacy (queue [ stimulus "leased" 2.0 ]);
    let resumed =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "resume completed migration cleanup"
    in
    Alcotest.(check (list string))
      "crash residue does not duplicate migrated stimulus"
      [ "leased"; "pending" ]
      (post_ids (State.pending resumed));
    Alcotest.(check bool)
      "verified crash residue removed"
      false
      (Sys.file_exists legacy);
    write_queue legacy (queue [ stimulus "forbidden-residue" 3.0 ]);
    (match Persistence.load_state_result ~base_path ~keeper_name with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "v2 state silently accepted legacy residue"))
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
    let receipt =
      match
        Persistence.settle_result
          ~base_path
          ~keeper_name
          ~settled_at:3.0
          ~lease
          ~settlement:State.Ack
          ()
        |> require_ok "settle projection source"
      with
      | Persistence.Settled receipt -> receipt
      | Persistence.Already_settled _ ->
        Alcotest.fail "first projection settlement was already settled"
    in
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
    Masc.Keeper_reaction_ledger.record_event_queue_transition_reaction_result
      ~base_path
      ~keeper_name
      ~reaction_kind:Masc.Keeper_reaction_ledger.Event_queue_ack
      ~receipt
      source
    |> require_ok "replay stable transition reaction";
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
        ; Alcotest.test_case "requeue and escalation" `Quick test_requeue_and_escalation_are_total
        ; Alcotest.test_case
            "judgment terminal evidence"
            `Quick
            test_judgment_terminal_evidence_is_durable
        ; Alcotest.test_case "failed cycle route mapping" `Quick test_failed_cycle_route_mapping
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
            "retryable failure durable FIFO tail"
            `Quick
            test_retryable_failure_restores_exact_stimulus_at_fifo_tail
        ; Alcotest.test_case "legacy pair migration" `Quick test_legacy_pair_migrates_once
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
