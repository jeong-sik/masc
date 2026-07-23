open Masc

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Receipt = Keeper_paused_work_disposition_receipt
module Transaction = Keeper_paused_work_source_terminal_transaction

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

let with_source_terminal_lane f =
  let base_path = Filename.temp_dir "keeper-paused-source-terminal" "" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "paused-source-terminal-owner" in
       let meta =
         Masc_test_deps.meta_of_json_fixture
           (`Assoc
              [ "name", `String keeper_name
              ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
              ; "trace_id", `String "trace-paused-source-terminal-owner"
              ; "runtime_id", `String "runtime.primary"
              ; "autoboot_enabled", `Bool false
              ])
         |> require_ok "parse Keeper metadata fixture"
       in
       let meta =
         { meta with
           paused = true
         ; latched_reason =
             Some
               (Keeper_latched_reason.Operator_paused
                  { operator_actor =
                      Keeper_latched_reason.operator_actor_grpc_directive
                  })
         ; runtime = { meta.runtime with generation = 51 }
         }
       in
       Keeper_meta_store.write_meta config meta |> require_ok "persist Keeper metadata";
       let channel =
         Keeper_continuation_channel.dashboard ~thread_id:"thread-terminal-1"
         |> require_ok "construct terminal continuation channel"
       in
       let resolution : Queue.hitl_resolution =
         { approval_id = "approval-terminal-1"
         ; decision = Queue.Hitl_rejected "operator rejected"
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
       Persistence.update_result ~base_path ~keeper_name (fun pending ->
         Queue.enqueue pending source)
       |> require_ok "seed source-terminal event";
       let source_revision =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load source-terminal revision"
         |> State.revision
       in
       let request : Transaction.request =
         { source
         ; source_revision
         ; owner_generation = meta.runtime.generation
         ; source_receipt = State.Hitl_terminal resolution
         ; operator_operation_id = "operator-source-terminal-1"
         ; settled_at = 2.0
         }
       in
       f config keeper_name meta request)
;;

let check_applied = function
  | Transaction.Applied
      (Keeper_registry_event_queue.Settled _
      | Keeper_registry_event_queue.Already_settled _) -> ()
  | Transaction.Applied
      (Keeper_registry_event_queue.Committed_followup_failed { detail; _ }) ->
    Alcotest.fail detail
  | Transaction.Committed_followup_failed failure ->
    Alcotest.fail
      (Transaction.error_to_string
         { cause = failure; reservation_release = None })
;;

let test_exact_terminal_receipt_settles_once () =
  with_source_terminal_lane (fun config keeper_name meta request ->
    let first =
      Transaction.settle_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit Settle_from_source_terminal"
    in
    (match first.commit_status with
     | Transaction.Committed -> ()
     | Transaction.Already_committed -> Alcotest.fail "first settlement was replayed");
    check_applied first.projection;
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load source-terminal settlement"
    in
    Alcotest.(check int) "source removed" 0 (Queue.length (State.pending state));
    (match State.transition_outbox state with
     | [ { receipt = { settlement = State.Settle_from_source_terminal exact; _ }
         ; stimuli = [ source ]
         } ] ->
       Alcotest.(check bool) "outbox retains exact source" true (source = request.source);
       Alcotest.(check bool)
         "outbox retains exact terminal receipt"
         true
         (exact.source_receipt = request.source_receipt)
     | _ -> Alcotest.fail "source-terminal settlement outbox is not exact");
    let replacement =
      let resumed = Keeper_meta_contract.mark_resumed meta in
      { resumed with runtime = { resumed.runtime with generation = 52 } }
    in
    Keeper_meta_store.write_meta config replacement
    |> require_ok "persist replacement owner after settlement";
    let replay =
      Transaction.settle_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay Settle_from_source_terminal"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed -> Alcotest.fail "replay created another receipt");
    check_applied replay.projection)
;;

let test_mismatched_terminal_receipt_is_rejected_before_commit () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let other_channel =
      Keeper_continuation_channel.dashboard ~thread_id:"thread-terminal-other"
      |> require_ok "construct other terminal channel"
    in
    let mismatch : Queue.hitl_resolution =
      { approval_id = "approval-terminal-other"
      ; decision = Queue.Hitl_approved
      ; channel = other_channel
      }
    in
    let request = { request with source_receipt = State.Hitl_terminal mismatch } in
    (match Transaction.settle_pending config ~keeper_name request with
     | Error { cause = Transaction.Invalid_request _; _ } -> ()
     | Error error -> Alcotest.fail (Transaction.error_to_string error)
     | Ok _ -> Alcotest.fail "mismatched terminal receipt was accepted");
    (match
       Receipt.load
         config
         ~keeper_name
         ~operator_operation_id:request.operator_operation_id
     with
     | Ok None -> ()
     | Ok (Some _) -> Alcotest.fail "invalid terminal receipt was persisted"
     | Error detail -> Alcotest.fail detail);
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load rejected source-terminal lane"
    in
    Alcotest.(check int) "invalid receipt retains source" 1 (Queue.length (State.pending state)))
;;

let test_nonterminal_payload_is_rejected () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let bootstrap =
      { request.source with
        post_id = "nonterminal-bootstrap"
      ; payload = Queue.Bootstrap
      }
    in
    let request = { request with source = bootstrap } in
    match Transaction.settle_pending config ~keeper_name request with
    | Error { cause = Transaction.Invalid_request _; _ } -> ()
    | Error error -> Alcotest.fail (Transaction.error_to_string error)
    | Ok _ -> Alcotest.fail "nonterminal source payload was accepted")
;;

let () =
  Alcotest.run
    "keeper paused-work source-terminal transaction"
    [ ( "Settle_from_source_terminal"
      , [ Alcotest.test_case
            "exact receipt settles once"
            `Quick
            test_exact_terminal_receipt_settles_once
        ; Alcotest.test_case
            "mismatched receipt is rejected"
            `Quick
            test_mismatched_terminal_receipt_is_rejected_before_commit
        ; Alcotest.test_case
            "nonterminal payload is rejected"
            `Quick
            test_nonterminal_payload_is_rejected
        ] )
    ]
;;
