open Masc

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Receipt = Keeper_paused_work_disposition_receipt
module Transaction = Keeper_paused_work_transfer_transaction

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let require_some label = function
  | Some value -> value
  | None -> Alcotest.failf "%s: expected Some" label
;;

let rec remove_tree path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let write_meta config ~keeper_name ~trace_id ~generation ~paused =
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
         ; "trace_id", `String trace_id
         ; "runtime_id", `String "runtime.primary"
         ; "autoboot_enabled", `Bool false
         ])
    |> require_ok "parse Keeper metadata fixture"
  in
  let meta =
    { meta with
      paused
    ; latched_reason =
        (if paused
         then
           Some
             (Keeper_latched_reason.Operator_paused
                { operator_actor =
                    Keeper_latched_reason.operator_actor_grpc_directive
                })
         else None)
    ; runtime = { meta.runtime with generation }
    }
  in
  Keeper_meta_store.write_meta config meta |> require_ok "persist Keeper metadata";
  meta
;;

let with_transfer_lane f =
  let base_path = Filename.temp_dir "keeper-paused-transfer-transaction" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let from_keeper = "paused-transfer-source" in
       let to_keeper = "active-transfer-target" in
       let source_meta =
         write_meta
           config
           ~keeper_name:from_keeper
           ~trace_id:"trace-paused-transfer-source"
           ~generation:31
           ~paused:true
       in
       let target_meta =
         write_meta
           config
           ~keeper_name:to_keeper
           ~trace_id:"trace-active-transfer-target"
           ~generation:41
           ~paused:false
       in
       let channel =
         Keeper_continuation_channel.slack
           ~team_id:(Some "team-1")
           ~channel_id:"channel-1"
           ~thread_ts:(Some "thread-1")
           ~user_id:"user-1"
         |> require_ok "construct source continuation channel"
       in
       let resolution : Queue.hitl_resolution =
         { approval_id = "approval-1"
         ; decision = Queue.Hitl_approved
         ; channel
         }
       in
       let source : Queue.stimulus =
         { post_id = Queue.hitl_resolution_post_id resolution
         ; urgency = Queue.Immediate
         ; arrived_at = 1.0
         ; payload = Queue.Hitl_resolved resolution
         }
       in
       Persistence.update_result ~base_path ~keeper_name:from_keeper (fun pending ->
         Queue.enqueue pending source)
       |> require_ok "seed transfer source";
       let source_revision =
         Persistence.load_state_result ~base_path ~keeper_name:from_keeper
         |> require_ok "load transfer source revision"
         |> State.revision
       in
       let request : Transaction.request =
         { source
         ; source_revision
         ; owner_generation = source_meta.runtime.generation
         ; target_generation = target_meta.runtime.generation
         ; continuation_binding = Receipt.Routed channel
         ; operator_operation_id = "operator-transfer-1"
         ; settled_at = 3.0
         }
       in
       f config from_keeper to_keeper source_meta target_meta request)
;;

let check_applied ~expected_target = function
  | Transaction.Applied { source_settlement; target_projection } ->
    (match source_settlement with
     | Keeper_registry_event_queue.Settled _
     | Keeper_registry_event_queue.Already_settled _ -> ()
     | Keeper_registry_event_queue.Committed_followup_failed { detail; _ } ->
       Alcotest.fail detail);
    Alcotest.(check bool)
      "target projection status"
      true
      (target_projection = expected_target)
  | Transaction.Committed_followup_failed failure ->
    Alcotest.fail
      (Transaction.error_to_string
         { cause = failure; reservation_release = None })
;;

let assert_converged config ~from_keeper ~to_keeper source =
  let source_state =
    Persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name:from_keeper
    |> require_ok "load settled source lane"
  in
  Alcotest.(check int)
    "source pending removed"
    0
    (Queue.length (State.pending source_state));
  (match State.transition_outbox source_state with
   | [ { receipt = { settlement = State.Transfer_accepted transfer; _ }; stimuli = [ retained ] } ] ->
     Alcotest.(check bool) "terminal receipt retains source" true (retained = source);
     Alcotest.(check string) "causal target" to_keeper transfer.to_keeper
   | _ -> Alcotest.fail "source transfer settlement outbox is not exact");
  let target_state =
    Persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name:to_keeper
    |> require_ok "load transfer target lane"
  in
  Alcotest.(check bool)
    "target has the exact source once"
    true
    (Queue.to_list (State.pending target_state) = [ source ])
;;

let test_transfer_commits_and_replays_exactly_once () =
  with_transfer_lane (fun config from_keeper to_keeper _source_meta _target_meta request ->
    let first =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit Transfer_owner"
    in
    (match first.commit_status with
     | Transaction.Committed -> ()
     | Transaction.Already_committed -> Alcotest.fail "first transfer was a replay");
    check_applied ~expected_target:Transaction.Enqueued first.projection;
    assert_converged config ~from_keeper ~to_keeper request.source;
    let replay =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay Transfer_owner"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed -> Alcotest.fail "transfer replay created a receipt");
    check_applied ~expected_target:Transaction.Already_present replay.projection;
    assert_converged config ~from_keeper ~to_keeper request.source)
;;

let test_replay_after_target_consumption_has_no_second_effect () =
  with_transfer_lane (fun config from_keeper to_keeper _source_meta _target_meta request ->
    let base_path = config.Workspace.base_path in
    let first =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit Transfer_owner before target consumption"
    in
    check_applied ~expected_target:Transaction.Enqueued first.projection;
    let lease =
      Persistence.claim_when_result
        ~base_path
        ~keeper_name:to_keeper
        ~claimed_at:4.0
        ~ready:(fun _ -> true)
        ()
      |> require_ok "claim transferred target source"
      |> require_some "transferred target lease"
    in
    (match
       Persistence.settle_result
         ~base_path
         ~keeper_name:to_keeper
         ~settled_at:5.0
         ~lease
         ~settlement:State.Ack
         ()
     with
     | Ok (Persistence.Settled _ | Persistence.Already_settled _) -> ()
     | Ok (Persistence.Committed_followup_failed { detail; _ })
     | Error detail -> Alcotest.fail detail);
    let replay =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay Transfer_owner after target consumption"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed -> Alcotest.fail "target-consumed replay replaced receipt");
    check_applied ~expected_target:Transaction.Already_present replay.projection;
    let target =
      Persistence.load_state_result ~base_path ~keeper_name:to_keeper
      |> require_ok "load replayed consumed target"
    in
    Alcotest.(check int)
      "target source was not enqueued again"
      0
      (Queue.length (State.pending target));
    Alcotest.(check int)
      "one durable target projection"
      1
      (List.length (State.accepted_transfer_projections target)))
;;

let test_replay_after_source_settlement_projects_target () =
  with_transfer_lane (fun config from_keeper to_keeper source_meta target_meta request ->
    let transfer : Receipt.transfer_owner =
      { from_keeper
      ; to_keeper
      ; target_trace_id = target_meta.runtime.trace_id
      ; target_generation = request.target_generation
      ; source = request.source
      ; source_revision = request.source_revision
      ; settled_at = request.settled_at
      ; continuation_binding = request.continuation_binding
      }
    in
    let receipt : Receipt.t =
      { keeper_name = from_keeper
      ; expected_trace_id = source_meta.runtime.trace_id
      ; expected_generation = request.owner_generation
      ; operator_operation_id = request.operator_operation_id
      ; requested_at = 2.0
      ; operation = Receipt.Transfer_owner transfer
      }
    in
    (match
       Receipt.with_keeper_lock config ~keeper_name:from_keeper (fun lock ->
         Receipt.save_if_absent lock config receipt)
     with
     | Ok (Ok Receipt.Created) -> ()
     | Ok (Ok (Receipt.Existing _)) -> Alcotest.fail "prepared receipt already existed"
     | Ok (Error detail) | Error detail -> Alcotest.fail detail);
    let causal : Keeper_registry_event_queue.accepted_transfer =
      { source = request.source
      ; source_revision = request.source_revision
      ; owner_generation = request.owner_generation
      ; operator_operation_id = request.operator_operation_id
      ; from_keeper
      ; to_keeper
      }
    in
    (* fire-and-forget: the settlement value is only a fixture precondition here. *)
    ignore
      (Keeper_registry_event_queue.transfer_pending_accepted_result
         ~base_path:config.Workspace.base_path
         from_keeper
         ~current_owner_generation:request.owner_generation
         ~settled_at:request.settled_at
         ~transfer:causal
       |> require_ok "simulate committed source settlement");
    let replay =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "resume after source settlement"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed -> Alcotest.fail "prepared receipt was replaced");
    check_applied ~expected_target:Transaction.Enqueued replay.projection;
    assert_converged config ~from_keeper ~to_keeper request.source)
;;

let test_stale_source_revision_has_no_receipt_or_target_effect () =
  with_transfer_lane (fun config from_keeper to_keeper _source_meta _target_meta request ->
    let unrelated : Queue.stimulus =
      { post_id = "unrelated"
      ; urgency = Queue.Low
      ; arrived_at = 2.0
      ; payload = Queue.Bootstrap
      }
    in
    Persistence.update_result
      ~base_path:config.Workspace.base_path
      ~keeper_name:from_keeper
      (fun pending -> Queue.enqueue pending unrelated)
    |> require_ok "advance source revision";
    (match Transaction.transfer_pending config ~from_keeper ~to_keeper request with
     | Error { cause = Transaction.Source_queue_validation_failed _; _ } -> ()
     | Error error -> Alcotest.fail (Transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "stale source revision committed transfer");
    (match
       Receipt.load
         config
         ~keeper_name:from_keeper
         ~operator_operation_id:request.operator_operation_id
     with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "stale transfer persisted an operation receipt"
     | Error detail -> Alcotest.fail detail);
    let target =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name:to_keeper
      |> require_ok "load untouched transfer target"
    in
    Alcotest.(check int) "stale transfer target effect" 0 (Queue.length (State.pending target)))
;;

let () =
  Alcotest.run
    "keeper paused-work transfer transaction"
    [ ( "Transfer_owner"
      , [ Alcotest.test_case
            "commit and replay exactly once"
            `Quick
            test_transfer_commits_and_replays_exactly_once
        ; Alcotest.test_case
            "replay after source settlement projects target"
            `Quick
            test_replay_after_source_settlement_projects_target
        ; Alcotest.test_case
            "replay after target consumption has no second effect"
            `Quick
            test_replay_after_target_consumption_has_no_second_effect
        ; Alcotest.test_case
            "stale source revision has no effect"
            `Quick
            test_stale_source_revision_has_no_receipt_or_target_effect
        ] )
    ]
;;
