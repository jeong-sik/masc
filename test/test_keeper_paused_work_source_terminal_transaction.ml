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
         ; runtime = { meta.runtime with nonce = 51 }
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
         ; owner_nonce = meta.runtime.nonce
         ; source_receipt = State.Hitl_terminal resolution
         ; operator_operation_id = "operator-source-terminal-1"
         }
       in
       f config keeper_name meta request)
;;

let check_applied = function
  | Transaction.Applied
      (Keeper_registry_event_queue.Acked _
      | Keeper_registry_event_queue.Already_acked _) -> ()
  | Transaction.Applied
      (Keeper_registry_event_queue.Ack_committed_followup_failed { detail; _ }) ->
    Alcotest.fail detail
  | Transaction.Committed_followup_failed failure ->
    Alcotest.fail
      (Transaction.error_to_string
         { cause = failure; reservation_release = None })
;;

let replace_field name value fields =
  List.map (fun (field, current) -> if String.equal field name then field, value else field, current) fields
;;

let source_ack_wire_fields json =
  match json with
  | `Assoc state_fields ->
    (match List.assoc_opt "transition_outbox" state_fields with
     | Some (`List [ `Assoc outbox_fields ]) ->
       (match List.assoc_opt "receipt" outbox_fields with
        | Some (`Assoc receipt_fields) ->
          (match List.assoc_opt "settlement" receipt_fields with
           | Some (`Assoc settlement_fields) -> state_fields, outbox_fields, receipt_fields, settlement_fields
           | Some _ | None -> Alcotest.fail "source ACK settlement must be an object")
        | Some _ | None -> Alcotest.fail "source ACK outbox receipt must be an object")
     | Some _ | None -> Alcotest.fail "source ACK must retain exactly one durable outbox entry")
  | _ -> Alcotest.fail "source ACK state must be a JSON object"
;;

let source_ack_transition_state request state =
  let source_terminal : State.accepted_source_terminal =
    { source = request.source
    ; source_revision = request.source_revision
    ; owner_nonce = request.owner_nonce
    ; operator_operation_id = request.operator_operation_id
    ; source_receipt = request.source_receipt
    }
  in
  State.ack_pending_source_terminal
    ~current_owner_nonce:request.owner_nonce
    ~settled_at:2.0
    ~source_terminal
    state
  |> require_ok "create source ACK transition"
;;

let test_source_ack_wire_is_canonical_and_recovers_v8 () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let original =
      Persistence.load_state_result ~base_path:config.Workspace.base_path ~keeper_name
      |> require_ok "load source ACK state"
    in
    let acknowledged, result = source_ack_transition_state request original in
    (match result with
     | State.Settled _ -> ()
     | State.Already_settled _ -> Alcotest.fail "first source ACK was a replay");
    let canonical_json = State.to_yojson acknowledged in
    let state_fields, outbox_fields, receipt_fields, settlement_fields =
      source_ack_wire_fields canonical_json
    in
    Alcotest.(check (option string))
      "source ACK writes v9 state"
      (Some State.schema)
      (match List.assoc_opt "schema" state_fields with
       | Some (`String schema) -> Some schema
       | Some _ | None -> None);
    Alcotest.(check (option string))
      "source ACK writes its own durable kind"
      (Some "ack_source_terminal")
      (match List.assoc_opt "kind" settlement_fields with
       | Some (`String kind) -> Some kind
       | Some _ | None -> None);
    let legacy_transition_id =
      match List.assoc_opt "lease_id" receipt_fields with
      | Some (`String lease_id) -> lease_id ^ ":settle_from_source_terminal"
      | Some _ | None -> Alcotest.fail "source ACK receipt omitted lease identity"
    in
    let legacy_event_id = "keeper-event-queue-transition:" ^ legacy_transition_id in
    let legacy_settlement =
      replace_field "kind" (`String "settle_from_source_terminal") settlement_fields
    in
    let legacy_receipt =
      receipt_fields
      |> replace_field "settlement" (`Assoc legacy_settlement)
      |> replace_field "transition_id" (`String legacy_transition_id)
      |> replace_field "event_id" (`String legacy_event_id)
    in
    let legacy_outbox = replace_field "receipt" (`Assoc legacy_receipt) outbox_fields in
    let legacy_state =
      state_fields
      |> replace_field "schema" (`String "keeper.event_queue.state.v8")
      |> replace_field "transition_outbox" (`List [ `Assoc legacy_outbox ])
      |> fun fields -> `Assoc fields
    in
    let recovered = State.of_yojson legacy_state |> require_ok "recover v8 source ACK outbox" in
    let recovered_json = State.to_yojson recovered in
    let recovered_fields, _, _, recovered_settlement = source_ack_wire_fields recovered_json in
    Alcotest.(check (option string))
      "recovery rewrites v8 as v9"
      (Some State.schema)
      (match List.assoc_opt "schema" recovered_fields with
       | Some (`String schema) -> Some schema
       | Some _ | None -> None);
    Alcotest.(check (option string))
      "recovery removes legacy source settlement kind"
      (Some "ack_source_terminal")
      (match List.assoc_opt "kind" recovered_settlement with
       | Some (`String kind) -> Some kind
       | Some _ | None -> None))
;;

let test_exact_terminal_receipt_acks_pending () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let first =
      Transaction.ack_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit Ack_source_terminal"
    in
    (match first.commit_status with
     | Transaction.Committed -> ()
     | Transaction.Already_committed -> Alcotest.fail "first ACK was replayed");
    check_applied first.projection;
    let open Yojson.Safe.Util in
    Alcotest.(check bool)
      "source-terminal receipt omits removed settled_at"
      true
      (match Receipt.to_yojson first.receipt |> member "source_terminal" |> member "settled_at" with
       | `Null -> true
       | _ -> false);
    let obsolete_v3_receipt =
      match Receipt.to_yojson first.receipt with
      | `Assoc fields ->
        let source_terminal =
          match List.assoc_opt "source_terminal" fields with
          | Some (`Assoc source_fields) ->
            `Assoc (("settled_at", `Float 2.0) :: source_fields)
          | Some _ | None -> Alcotest.fail "source-terminal receipt must be an object"
        in
        `Assoc
          (List.map
             (function
               | "operation", _ -> "operation", `String "settle_from_source_terminal"
               | "schema", _ -> "schema", `String "masc.keeper.paused-work-disposition.v3"
               | "source_terminal", _ -> "source_terminal", source_terminal
               | field -> field)
             fields)
      | _ -> Alcotest.fail "source-terminal receipt must be a JSON object"
    in
    (match Receipt.of_yojson obsolete_v3_receipt with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "source-terminal receipt accepted obsolete v3 schema");
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load source-terminal ACK"
    in
    Alcotest.(check int) "source removed" 0 (Queue.length (State.pending state));
    let replay =
      Transaction.ack_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay Ack_source_terminal"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed -> Alcotest.fail "replay replaced the source-terminal receipt");
    check_applied replay.projection;
    let replayed_state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load replayed source-terminal ACK"
    in
    Alcotest.(check int64)
      "replay does not append a second terminal transition"
      (State.revision state)
      (State.revision replayed_state);
    Alcotest.(check int)
      "replay keeps source removed"
      0
      (Queue.length (State.pending replayed_state)))
;;

let test_source_terminal_busy_has_zero_mutation () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let base_path = config.Workspace.base_path in
    (match
       Keeper_turn_admission.run_admin_if_free
         ~base_path
         ~keeper_name
         (fun () -> Transaction.ack_pending config ~keeper_name request)
     with
     | `Ran (Error { cause = Transaction.Admission_busy _; _ }) -> ()
     | `Ran (Error error) -> Alcotest.fail (Transaction.error_to_string error)
     | `Ran (Ok _) | `Busy _ ->
       Alcotest.fail "source-terminal ACK was not deferred by turn admission");
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load admission-busy source-terminal lane"
    in
    Alcotest.(check int)
      "admission busy retains source"
      1
      (Queue.length (State.pending state)))
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
    (match Transaction.ack_pending config ~keeper_name request with
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
    match Transaction.ack_pending config ~keeper_name request with
    | Error { cause = Transaction.Invalid_request _; _ } -> ()
    | Error error -> Alcotest.fail (Transaction.error_to_string error)
    | Ok _ -> Alcotest.fail "nonterminal source payload was accepted")
;;

let () =
  Alcotest.run
    "keeper paused-work source-terminal transaction"
    [ ( "Ack_source_terminal"
      , [ Alcotest.test_case
            "writes ACK wire and recovers v8 outbox"
            `Quick
            test_source_ack_wire_is_canonical_and_recovers_v8
        ; Alcotest.test_case
            "exact receipt ACKs pending"
            `Quick
            test_exact_terminal_receipt_acks_pending
        ; Alcotest.test_case
            "admission busy has zero mutation"
            `Quick
            test_source_terminal_busy_has_zero_mutation
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
