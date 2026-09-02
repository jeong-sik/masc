open Masc

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Receipt = Keeper_paused_work_disposition_receipt
module Transaction = Keeper_paused_work_source_terminal_transaction

let test_switch : Eio.Switch.t option ref = ref None

let current_switch () =
  match !test_switch with
  | Some sw -> sw
  | None -> Alcotest.fail "test Owner switch is not installed"
;;

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

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
;;

let write_json path json =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel ->
    output_string channel (Yojson.Safe.to_string json))
;;

let write_text path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel text)
;;

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let receipt_path config ~keeper_name ~operator_operation_id =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Workspace.masc_root_dir config)
          ("paused-work-dispositions-"
           ^ Masc.Keeper_paused_work_disposition_receipt.store_version))
       ("keeper-" ^ sha256 keeper_name))
    ("operation-" ^ sha256 operator_operation_id ^ ".json")
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
         }
       in
       Keeper_meta_store.replace_snapshot config meta |> require_ok "persist Keeper metadata";
       (match
          Keeper_owner_registry.install_from_store
            ~sw:(current_switch ())
            ~operation_runner:None
           ~on_turn_slot_released:None
            config
        with
        | Ok count -> Alcotest.(check int) "installed owner count" 1 count
        | Error error ->
          Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
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
       let source_incarnation =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load source-terminal incarnation"
         |> State.select_when
              ~now:(Unix.gettimeofday ())
              ~ready:(Queue.stimulus_identity_equal source)
         |> require_some "select source-terminal event"
         |> fun selection -> selection.admitted_revision
       in
       let request : Transaction.request =
         { source
         ; source_incarnation
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

let transition_receipt_of_applied = function
  | Transaction.Applied
      (Keeper_registry_event_queue.Acked receipt
      | Keeper_registry_event_queue.Already_acked receipt) -> receipt
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
          (match List.assoc_opt "transition" receipt_fields with
           | Some (`Assoc action_fields) ->
             state_fields, outbox_fields, receipt_fields, action_fields
           | Some _ | None -> Alcotest.fail "source ACK receipt must be an object")
        | Some _ | None -> Alcotest.fail "source ACK outbox receipt must be an object")
     | Some _ | None -> Alcotest.fail "source ACK must retain exactly one durable outbox entry")
  | _ -> Alcotest.fail "source ACK state must be a JSON object"
;;

let source_ack_transition_state (request : Transaction.request) state =
  let source_terminal : State.accepted_source_terminal =
    State.
      { source = request.source
    ; source_incarnation = request.source_incarnation
    ; operator_operation_id = request.operator_operation_id
    ; source_receipt = request.source_receipt
    }
  in
  State.ack_pending_source_terminal
    ~applied_at:2.0
    ~source_terminal
    state
  |> require_ok "create source ACK transition"
;;

let required_string_field label field fields =
  match List.assoc_opt field fields with
  | Some (`String value) -> value
  | Some _ | None -> Alcotest.failf "%s omitted %s" label field
;;

let test_source_ack_wire_is_current_only () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let original =
      Persistence.load_state_result ~base_path:config.Workspace.base_path ~keeper_name
      |> require_ok "load source ACK state"
    in
    let acknowledged, result = source_ack_transition_state request original in
    (match result with
     | State.Transition_applied _ -> ()
     | State.Transition_already_applied _ -> Alcotest.fail "first source ACK was a replay");
    let canonical_json = State.to_yojson acknowledged in
    let state_fields, _outbox_fields, receipt_fields, action_fields =
      source_ack_wire_fields canonical_json
    in
    Alcotest.(check (option string))
      "source ACK writes v12 state"
      (Some State.schema)
      (match List.assoc_opt "schema" state_fields with
       | Some (`String schema) -> Some schema
       | Some _ | None -> None);
    Alcotest.(check (option string))
      "source ACK writes its own durable kind"
      (Some "ack_source_terminal")
      (match List.assoc_opt "kind" action_fields with
       | Some (`String kind) -> Some kind
       | Some _ | None -> None);
    Alcotest.(check bool)
      "source ACK receipt does not carry a lease id"
      true
      (not (List.mem_assoc "lease_id" receipt_fields));
    Alcotest.(check bool)
      "source ACK receipt does not carry a lease sequence"
      true
      (not (List.mem_assoc "lease_sequence" receipt_fields));
    let canonical_transition_id =
      "pending-source-terminal-ack:" ^ request.operator_operation_id
    in
    let canonical_event_id = "keeper-event-queue-transition:" ^ canonical_transition_id in
    Alcotest.(check string)
      "source ACK writes its canonical transition identity"
      canonical_transition_id
      (required_string_field "source ACK receipt" "transition_id" receipt_fields);
    Alcotest.(check string)
      "source ACK writes its canonical event identity"
      canonical_event_id
      (required_string_field "source ACK receipt" "event_id" receipt_fields);
    let retired_state =
      state_fields
      |> replace_field "schema" (`String "keeper.event_queue.state.v11")
      |> fun fields -> `Assoc fields
    in
    (match State.of_yojson retired_state with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "retired event queue state schema was accepted");
    let retired_receipt =
      `Assoc (("lease_id", `String "lease:1") :: receipt_fields)
    in
    (match State.transition_receipt_of_yojson retired_receipt with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "retired lease receipt was accepted"))
;;

let test_source_ack_identity_survives_checkpoint_reload () =
  with_source_terminal_lane (fun _config _keeper_name _meta request ->
    let initial =
      State.empty
      |> State.with_revision request.source_incarnation
      |> State.with_pending (Queue.enqueue Queue.empty request.source)
    in
    let first, first_result = source_ack_transition_state request initial in
    let first_receipt =
      match first_result with
      | State.Transition_applied receipt -> receipt
      | State.Transition_already_applied _ -> Alcotest.fail "first source ACK was a replay"
    in
    let projected =
      State.mark_transition_projected ~transition_id:first_receipt.transition_id first
      |> require_ok "project first source ACK"
    in
    let reloaded = State.to_yojson projected |> State.of_yojson |> require_ok "reload projected ACK" in
    let second_resolution =
      match request.source_receipt with
      | State.Hitl_terminal resolution ->
        { resolution with approval_id = "approval-terminal-2" }
      | State.Fusion_terminal _
      | State.Turn_completed
      | State.Turn_attempt_terminal _ ->
        Alcotest.fail "fixture must carry a HITL terminal receipt"
    in
    let second_source : Queue.stimulus =
      { post_id = Queue.hitl_resolution_post_id second_resolution
      ; urgency = Queue.Immediate
      ; arrived_at = 3.0
      ; payload = Queue.Hitl_resolved second_resolution
      }
    in
    let second_state = State.with_pending (Queue.enqueue Queue.empty second_source) reloaded in
    let second_selection =
      State.select_when
        ~now:(Unix.gettimeofday ())
        ~ready:(Queue.stimulus_identity_equal second_source)
        second_state
      |> require_some "select second source-terminal event"
    in
    let second_request : Transaction.request =
      { source = second_source
      ; source_incarnation = second_selection.admitted_revision
      ; source_receipt = State.Hitl_terminal second_resolution
      ; operator_operation_id = "operator-source-terminal-2"
      }
    in
    let _, second_result = source_ack_transition_state second_request second_state in
    let second_receipt =
      match second_result with
      | State.Transition_applied receipt -> receipt
      | State.Transition_already_applied _ -> Alcotest.fail "second source ACK was a replay"
    in
    Alcotest.(check string)
      "first source ACK derives identity from its operation"
      "pending-source-terminal-ack:operator-source-terminal-1"
      first_receipt.transition_id;
    Alcotest.(check string)
      "second source ACK derives identity from its operation"
      "pending-source-terminal-ack:operator-source-terminal-2"
      second_receipt.transition_id;
    Alcotest.(check bool)
      "checkpoint reload cannot reuse the first source ACK identity"
      true
      (not (String.equal first_receipt.transition_id second_receipt.transition_id)))
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

let test_unrelated_enqueue_preserves_source_terminal_incarnation () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let unrelated : Queue.stimulus =
      { post_id = "unrelated-source-terminal"
      ; urgency = Queue.Low
      ; arrived_at = 2.0
      ; payload = Queue.Bootstrap
      }
    in
    Persistence.update_result
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun pending -> Queue.enqueue pending unrelated)
    |> require_ok "enqueue unrelated source-terminal event";
    let result =
      Transaction.ack_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "ACK source terminal after unrelated enqueue"
    in
    check_applied result.projection;
    let state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load source-terminal result after unrelated enqueue"
    in
    Alcotest.(check int)
      "only unrelated source-terminal event remains"
      1
      (Queue.length (State.pending state));
    Alcotest.(check bool)
      "unrelated source-terminal event is preserved"
      true
      (State.pending state
       |> Queue.to_list
       |> List.exists (Queue.stimulus_identity_equal unrelated)))
;;

let test_reinserted_source_rejects_old_terminal_incarnation () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let base_path = config.Workspace.base_path in
    let old_selection : State.pending_selection =
      { source = request.source
      ; admitted_revision = request.source_incarnation
      }
    in
    Persistence.ack_pending_result
      ~base_path
      ~keeper_name
      ~selection:old_selection
      ()
    |> require_ok "remove old source-terminal incarnation";
    Persistence.update_result ~base_path ~keeper_name (fun pending ->
      Queue.enqueue pending request.source)
    |> require_ok "reinsert source-terminal event";
    (match Transaction.ack_pending config ~keeper_name request with
     | Error { cause = Transaction.Source_queue_validation_failed _; _ } -> ()
     | Error error -> Alcotest.fail (Transaction.error_to_string error)
     | Ok _ ->
       Alcotest.fail "old source-terminal incarnation ACKed the reinserted source");
    (match
       Receipt.load
         config
         ~keeper_name
         ~operator_operation_id:request.operator_operation_id
     with
     | Ok None -> ()
     | Ok (Some _) ->
       Alcotest.fail "old source-terminal incarnation persisted a receipt"
     | Error detail -> Alcotest.fail detail);
    let state =
      Persistence.load_state_result ~base_path ~keeper_name
      |> require_ok "load reinserted source-terminal event"
    in
    Alcotest.(check int)
      "reinserted source-terminal event remains"
      1
      (Queue.length (State.pending state)))
;;

let test_terminal_ack_replays_after_projection_and_snapshot_reload () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let pre_state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load source-terminal ACK pre-state"
    in
    let first =
      Transaction.ack_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit source-terminal ACK"
    in
    check_applied first.projection;
    let transition_receipt =
      transition_receipt_of_applied first.projection
    in
    let staged =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load owner-projected source-terminal ACK"
    in
    Alcotest.(check int)
      "owner-facing source-terminal ACK retires its transition outbox"
      0
      (List.length (State.transition_outbox staged));
    let outbox_entry : State.outbox_entry =
      { receipt = transition_receipt; stimuli = [ request.source ] }
    in
    let projected =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "reload projected source-terminal ACK"
    in
    (match State.last_transition projected with
     | Some { transition = State.Ack_source_terminal _; _ } -> ()
     | Some _ | None -> Alcotest.fail "projected source-terminal ACK lost its replay witness");
    let transition_wal_path =
      Filename.concat
        (Filename.concat
           (Common.keepers_runtime_dir_of_base ~base_path:config.Workspace.base_path)
           keeper_name)
        "event-queue-transitions-v7.jsonl"
    in
    let residual_wal_row =
      `Assoc
        [ "schema", `String "masc.keeper_event_queue.transition.v7"
        ; "base_path", `String config.Workspace.base_path
        ; "keeper_name", `String keeper_name
        ; "pre_state", State.to_yojson pre_state
        ; "outbox_entry", State.outbox_entry_to_yojson outbox_entry
        ]
    in
    let residual_wal_bytes = Yojson.Safe.to_string residual_wal_row ^ "\n" in
    write_text transition_wal_path residual_wal_bytes;
    let observed =
      Persistence.observe_snapshot_with_errors
        ~base_path:config.Workspace.base_path
        ~keeper_name
    in
    Alcotest.(check int)
      "lock-free operator observation reports no read errors"
      0
      (List.length observed.read_errors);
    Alcotest.(check int)
      "lock-free operator observation preserves the pending projection"
      (Queue.length (State.pending projected))
      (Queue.length observed.pending);
    Alcotest.(check string)
      "lock-free operator observation preserves residual WAL bytes"
      residual_wal_bytes
      (In_channel.with_open_bin transition_wal_path In_channel.input_all);
    let validated =
      Persistence.validate_existing_state_read_only_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "validate residual transition WAL without mutation"
    in
    (match State.last_transition validated with
     | Some receipt when State.transition_receipt_equal receipt outbox_entry.receipt -> ()
     | Some _ | None ->
       Alcotest.fail "read-only validation lost the projected source ACK witness");
    Alcotest.(check string)
      "read-only validation preserves residual WAL bytes"
      residual_wal_bytes
      (In_channel.with_open_bin transition_wal_path In_channel.input_all);
    let recovered_after_projection =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "replay residual transition WAL after projection"
    in
    (match State.last_transition recovered_after_projection with
     | Some receipt when State.transition_receipt_equal receipt outbox_entry.receipt -> ()
     | Some _ | None ->
       Alcotest.fail "residual WAL did not preserve the projected source ACK witness");
    let replay =
      Transaction.ack_pending config ~keeper_name request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay source-terminal ACK after projection"
    in
    (match replay.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed ->
       Alcotest.fail "post-projection replay replaced the source-terminal receipt");
    check_applied replay.projection;
    let replayed =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "reload replayed projected source-terminal ACK"
    in
    Alcotest.(check int64)
      "post-projection replay does not append a second transition"
      (State.revision projected)
      (State.revision replayed);
    Alcotest.(check int)
      "post-projection replay keeps source removed"
      0
      (Queue.length (State.pending replayed)))
;;

let test_projected_wal_recovery_allows_next_source_ack () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let second_resolution =
      match request.source_receipt with
      | State.Hitl_terminal resolution ->
        { resolution with approval_id = "approval-terminal-after-projection" }
      | State.Fusion_terminal _
      | State.Turn_completed
      | State.Turn_attempt_terminal _ ->
        Alcotest.fail "fixture must carry a HITL terminal receipt"
    in
    let second_source : Queue.stimulus =
      { post_id = Queue.hitl_resolution_post_id second_resolution
      ; urgency = Queue.Immediate
      ; arrived_at = 3.0
      ; payload = Queue.Hitl_resolved second_resolution
      }
    in
    Persistence.update_result
      ~base_path:config.Workspace.base_path
      ~keeper_name
      (fun pending -> Queue.enqueue pending second_source)
    |> require_ok "seed second source-terminal event";
    let first_pre_state =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load first source-terminal ACK pre-state"
    in
    let first_request = request in
    let first =
      Transaction.ack_pending config ~keeper_name first_request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit first source-terminal ACK"
    in
    check_applied first.projection;
    let first_transition_receipt =
      transition_receipt_of_applied first.projection
    in
    let staged =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load first owner-projected source-terminal ACK"
    in
    Alcotest.(check int)
      "first owner-facing ACK retires its transition outbox"
      0
      (List.length (State.transition_outbox staged));
    let first_outbox : State.outbox_entry =
      { receipt = first_transition_receipt; stimuli = [ first_request.source ] }
    in
    let transition_wal_path =
      Filename.concat
        (Filename.concat
           (Common.keepers_runtime_dir_of_base ~base_path:config.Workspace.base_path)
           keeper_name)
        "event-queue-transitions-v7.jsonl"
    in
    let residual_wal_row =
      `Assoc
        [ "schema", `String "masc.keeper_event_queue.transition.v7"
        ; "base_path", `String config.Workspace.base_path
        ; "keeper_name", `String keeper_name
        ; "pre_state", State.to_yojson first_pre_state
        ; "outbox_entry", State.outbox_entry_to_yojson first_outbox
        ]
    in
    write_text transition_wal_path (Yojson.Safe.to_string residual_wal_row ^ "\n");
    let recovered =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "recover projected first ACK WAL"
    in
    let residual_wal = In_channel.with_open_bin transition_wal_path In_channel.input_all in
    Alcotest.(check string) "projected WAL is retired during recovery" "" residual_wal;
    let second_request : Transaction.request =
      { source = second_source
      ; source_incarnation =
          (State.select_when
             ~now:(Unix.gettimeofday ())
             ~ready:(Queue.stimulus_identity_equal second_source)
             recovered
           |> require_some "select second recovered source")
            .admitted_revision
      ; source_receipt = State.Hitl_terminal second_resolution
      ; operator_operation_id = "operator-source-terminal-after-projection"
      }
    in
    let second =
      Transaction.ack_pending config ~keeper_name second_request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "commit second source-terminal ACK"
    in
    check_applied second.projection;
    let final =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "load second projected source-terminal ACK"
    in
    (match State.last_transition final with
     | Some { transition = State.Ack_source_terminal _; transition_id; _ } ->
       Alcotest.(check string)
         "second projected transition has its own operation identity"
         "pending-source-terminal-ack:operator-source-terminal-after-projection"
         transition_id
     | Some _ | None -> Alcotest.fail "second source-terminal ACK was not projected");
    Alcotest.(check int)
      "second source-terminal ACK removes its already-pending source"
      0
      (Queue.length (State.pending final));
    Alcotest.(check int)
      "both projected ACK witnesses survive"
      2
      (List.length (State.projected_dispositions final));
    let replay_first =
      Transaction.ack_pending config ~keeper_name first_request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "replay first source-terminal ACK after second projection"
    in
    (match replay_first.commit_status with
     | Transaction.Already_committed -> ()
     | Transaction.Committed ->
       Alcotest.fail "older source-terminal ACK was committed twice");
    (match replay_first.projection with
     | Transaction.Applied
         (Keeper_registry_event_queue.Already_acked
            { transition_id; _ }) ->
       Alcotest.(check string)
         "older ACK keeps its transition identity"
         ("pending-source-terminal-ack:"
          ^ first_request.operator_operation_id)
         transition_id
     | Transaction.Applied (Keeper_registry_event_queue.Acked _) ->
       Alcotest.fail "older source-terminal ACK was applied twice"
     | Transaction.Applied
         (Keeper_registry_event_queue.Ack_committed_followup_failed
            { detail; _ }) ->
       Alcotest.fail detail
     | Transaction.Committed_followup_failed failure ->
       Alcotest.fail
         (Transaction.error_to_string
            { cause = failure; reservation_release = None }));
    let replayed =
      Persistence.load_state_result
        ~base_path:config.Workspace.base_path
        ~keeper_name
      |> require_ok "reload replayed first source-terminal ACK"
    in
    Alcotest.(check int64)
      "older ACK replay does not revise"
      (State.revision final)
      (State.revision replayed);
    Alcotest.(check int)
      "older ACK replay preserves both witnesses"
      2
      (List.length (State.projected_dispositions replayed)))
;;

let test_retired_v3_receipt_file_is_rejected () =
  with_source_terminal_lane (fun config keeper_name meta request ->
    let operation : Receipt.source_terminal_operation =
      { source = request.source
      ; source_incarnation = request.source_incarnation
      ; source_receipt = request.source_receipt
      }
    in
    let current : Receipt.t =
      { keeper_name
      ; expected_trace_id = meta.runtime.trace_id
      ; operator_operation_id = request.operator_operation_id
      ; requested_at = 2.0
      ; operation = Receipt.Ack_source_terminal operation
      }
    in
    let legacy =
      match Receipt.to_yojson current with
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
               | "operation", _ ->
                 "operation", `String "settle_from_source_terminal"
               | "schema", _ ->
                 "schema", `String "masc.keeper.paused-work-disposition.v3"
               | "source_terminal", _ -> "source_terminal", source_terminal
               | field -> field)
             fields)
      | _ -> Alcotest.fail "source-terminal receipt must be a JSON object"
    in
    (match Receipt.of_yojson legacy with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "public receipt codec accepted recovery-only v3");
    write_json
      (receipt_path
         config
         ~keeper_name
         ~operator_operation_id:request.operator_operation_id)
      legacy;
    (match
       Receipt.load
         config
         ~keeper_name
         ~operator_operation_id:request.operator_operation_id
     with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "durable load accepted retired v3 receipt"))
;;

let test_source_terminal_busy_has_zero_mutation () =
  with_source_terminal_lane (fun config keeper_name _meta request ->
    let base_path = config.Workspace.base_path in
    (match
       Keeper_owner_registry.run_maintenance_if_idle
         ~base_path
         ~keeper_name
         (fun () -> Transaction.ack_pending config ~keeper_name request)
     with
     | Ok (`Ran (Error { cause = Transaction.Admission_busy _; _ })) -> ()
     | Ok (`Ran (Error error)) -> Alcotest.fail (Transaction.error_to_string error)
     | Error error ->
       Alcotest.fail (Keeper_owner_registry.command_error_to_string error)
     | Ok (`Ran (Ok _) | `Busy _) ->
       Alcotest.fail "source-terminal ACK was not deferred by Keeper Owner");
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
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  test_switch := Some sw;
  Alcotest.run
    "keeper paused-work source-terminal transaction"
    [ ( "Ack_source_terminal"
      , [ Alcotest.test_case
            "writes current-only ACK wire"
            `Quick
            test_source_ack_wire_is_current_only
        ; Alcotest.test_case
            "exact receipt ACKs pending"
            `Quick
            test_exact_terminal_receipt_acks_pending
        ; Alcotest.test_case
            "unrelated enqueue preserves source-terminal incarnation"
            `Quick
            test_unrelated_enqueue_preserves_source_terminal_incarnation
        ; Alcotest.test_case
            "reinserted source rejects old terminal incarnation"
            `Quick
            test_reinserted_source_rejects_old_terminal_incarnation
        ; Alcotest.test_case
            "replays after outbox projection and snapshot reload"
            `Quick
            test_terminal_ack_replays_after_projection_and_snapshot_reload
        ; Alcotest.test_case
            "old ACK replays after a different projected ACK"
            `Quick
            test_projected_wal_recovery_allows_next_source_ack
        ; Alcotest.test_case
            "source ACK identity survives checkpoint reload"
            `Quick
            test_source_ack_identity_survives_checkpoint_reload
        ; Alcotest.test_case
            "retired v3 receipt is rejected"
            `Quick
            test_retired_v3_receipt_file_is_rejected
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
