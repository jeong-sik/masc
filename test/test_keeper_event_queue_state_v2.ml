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
  let projected = List.hd (State.transition_outbox state) in
  Alcotest.(check bool)
    "projection acknowledgement is durable state"
    true
    projected.projected_to_reaction_ledger;
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
      ~settlement:(State.Requeue State.Retry_after_pacing)
      state
    |> require_ok "retry requeue"
  in
  Alcotest.(check (list string)) "retry restored" [ "retry" ] (post_ids (State.pending state));
  let state, lease = claim_head state in
  let lease = require_some "escalation lease" lease in
  let judgment : Queue.failure_judgment =
    { fj_runtime_id = "runtime-a"
    ; fj_judgment = Keeper_runtime_failure_route.Contract_violation
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
           { reason = State.Failure_judgment_failed; successor = None })
      state
    |> require_ok "judgment failure escalation"
  in
  Alcotest.(check int)
    "failed judgment does not enqueue itself"
    0
    (Queue.length (State.pending state));
  Alcotest.(check int) "both transitions visible" 3 (List.length (State.transition_outbox state));
  let open Yojson.Safe.Util in
  let failed_judgment_settlement =
    State.to_yojson state
    |> member "transition_outbox"
    |> to_list
    |> List.rev
    |> List.hd
    |> member "receipt"
    |> member "settlement"
  in
  Alcotest.(check string)
    "failed judgment receipt is an escalation"
    "escalate"
    (failed_judgment_settlement |> member "kind" |> to_string);
  Alcotest.(check string)
    "failed judgment receipt preserves the typed reason"
    "failure_judgment_failed"
    (failed_judgment_settlement |> member "reason" |> to_string);
  Alcotest.(check bool)
    "failed judgment receipt explicitly stores no successor"
    true
    (failed_judgment_settlement
     |> member "successor"
     |> Yojson.Safe.equal `Null)
;;

let lease_for stimulus =
  let state = State.with_pending (queue [ stimulus ]) State.empty in
  let _state, lease = claim_head state in
  require_some "fixture lease" lease
;;

let turn_failure route : Keeper_unified_turn.turn_failure =
  { error = Agent_sdk.Error.Internal "deterministic fixture"
  ; runtime_id = "exact-final-runtime"
  ; route
  }
;;

let test_failed_cycle_route_mapping () =
  let ordinary_lease = lease_for (stimulus "ordinary" 1.0) in
  let retry_failure =
    turn_failure
      (Keeper_runtime_failure_route.Retry_after_pacing
         { pacing = Keeper_runtime_failure_route.Rate_limited
         ; retry_after = None
         })
  in
  (match
     Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:2.0
       ~lease:ordinary_lease
       retry_failure
   with
   | Keeper_registry_event_queue.Requeue
       Keeper_registry_event_queue.Retry_after_pacing ->
     ()
   | _ -> Alcotest.fail "retry route did not requeue the lease");
  let judgment_failure =
    turn_failure
      (Keeper_runtime_failure_route.Escalate_judgment
         { judgment = Keeper_runtime_failure_route.Contract_violation
         ; detail = "fixture contract failure"
         })
  in
  (match
     Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:3.0
       ~lease:ordinary_lease
       judgment_failure
   with
   | Keeper_registry_event_queue.Escalate
       { reason = Keeper_registry_event_queue.Failure_judgment_requested
       ; successor = Some { Queue.payload = Queue.Failure_judgment successor; _ }
       } ->
     Alcotest.(check string)
       "successor keeps exact final runtime"
       "exact-final-runtime"
       successor.fj_runtime_id
   | _ -> Alcotest.fail "deterministic failure did not create one judgment successor");
  let judgment : Queue.failure_judgment =
    { fj_runtime_id = "source-runtime"
    ; fj_judgment = Keeper_runtime_failure_route.Contract_violation
    ; fj_detail = "source failure"
    }
  in
  let leased_judgment =
    lease_for
      (stimulus
         ~payload:(Queue.Failure_judgment judgment)
         (Queue.failure_judgment_post_id judgment)
         4.0)
  in
  (match
     Keeper_heartbeat_loop.settlement_of_failure
       ~settled_at:5.0
       ~lease:leased_judgment
       judgment_failure
   with
   | Keeper_registry_event_queue.Escalate
       { reason = Keeper_registry_event_queue.Failure_judgment_failed
       ; successor = None
       } ->
     ()
   | _ -> Alcotest.fail "failed judgment recursively re-enqueued itself")
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
    write_queue legacy (queue [ stimulus "forbidden-residue" 3.0 ]);
    (match Persistence.load_state_result ~base_path ~keeper_name with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "v2 state silently accepted legacy residue"))
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
        ; Alcotest.test_case "failed cycle route mapping" `Quick test_failed_cycle_route_mapping
        ] )
    ; ( "persistence"
      , [ Alcotest.test_case "legacy pair migration" `Quick test_legacy_pair_migrates_once
        ; Alcotest.test_case
            "lane write fault isolation"
            `Quick
            test_failed_owner_write_does_not_block_peer_lane
        ] )
    ]
;;
