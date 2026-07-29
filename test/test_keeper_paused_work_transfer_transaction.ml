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

let sha256 value = Digestif.SHA256.(digest_string value |> to_hex)

let receipt_path config ~keeper_name ~operator_operation_id =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Workspace.masc_root_dir config)
          "paused-work-dispositions-v5")
       ("keeper-" ^ sha256 keeper_name))
    ("operation-" ^ sha256 operator_operation_id ^ ".json")
;;

let write_meta config ~keeper_name ~trace_id ~generation ~paused =
  let meta =
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
         ; "trace_id", `String trace_id
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
    ; runtime = { meta.runtime with nonce = generation }
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
         ; owner_nonce = source_meta.runtime.nonce
         ; target_generation = target_meta.runtime.nonce
         ; continuation_binding = Receipt.Routed channel
         ; operator_operation_id = "operator-transfer-1"
         }
       in
       f config from_keeper to_keeper source_meta target_meta request)
;;

let check_applied ~expected_target = function
  | Transaction.Applied target_projection ->
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

let test_transfer_commits_exact_pending_move () =
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
    let open Yojson.Safe.Util in
    Alcotest.(check bool)
      "transfer receipt omits removed settled_at"
      true
      (match Receipt.to_yojson first.receipt |> member "transfer" |> member "settled_at" with
       | `Null -> true
       | _ -> false);
    let obsolete_v2_receipt =
      match Receipt.to_yojson first.receipt with
      | `Assoc fields ->
        `Assoc
          (List.map
             (function
               | "schema", _ -> "schema", `String "masc.keeper.paused-work-disposition.v2"
               | field -> field)
             fields)
      | _ -> Alcotest.fail "transfer receipt must be a JSON object"
    in
    (match Receipt.of_yojson obsolete_v2_receipt with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "transfer receipt accepted obsolete v2 schema");
    assert_converged config ~from_keeper ~to_keeper request.source)
;;

let test_retired_v2_receipt_file_is_rejected () =
  with_transfer_lane
  @@ fun config from_keeper to_keeper source_meta target_meta request ->
  let transfer : Receipt.transfer_owner =
    { from_keeper
    ; to_keeper
    ; target_trace_id = target_meta.runtime.trace_id
    ; target_generation = request.target_generation
    ; source = request.source
    ; source_revision = request.source_revision
    ; continuation_binding = request.continuation_binding
    }
  in
  let current : Receipt.t =
    { keeper_name = from_keeper
    ; expected_trace_id = source_meta.runtime.trace_id
    ; expected_generation = request.owner_nonce
    ; operator_operation_id = request.operator_operation_id
    ; requested_at = 2.0
    ; operation = Receipt.Transfer_owner transfer
    }
  in
  let legacy =
    match Receipt.to_yojson current with
    | `Assoc fields ->
      let transfer =
        match List.assoc_opt "transfer" fields with
        | Some (`Assoc transfer_fields) ->
          `Assoc (("settled_at", `Float 2.0) :: transfer_fields)
        | Some _ | None -> Alcotest.fail "transfer receipt must contain an object"
      in
      `Assoc
        (List.map
           (function
             | "schema", _ ->
               "schema", `String "masc.keeper.paused-work-disposition.v2"
             | "transfer", _ -> "transfer", transfer
             | field -> field)
           fields)
    | _ -> Alcotest.fail "transfer receipt must be a JSON object"
  in
  (match Receipt.of_yojson legacy with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "public receipt codec accepted recovery-only v2");
  write_json
    (receipt_path
       config
       ~keeper_name:from_keeper
       ~operator_operation_id:request.operator_operation_id)
    legacy;
  match
    Receipt.load
      config
      ~keeper_name:from_keeper
      ~operator_operation_id:request.operator_operation_id
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "durable load accepted retired v2 transfer receipt"
;;

let test_retired_receipt_directory_is_not_read () =
  with_transfer_lane
  @@ fun config from_keeper to_keeper _source_meta _target_meta request ->
  let retired_path =
    Filename.concat
      (Filename.concat
         (Filename.concat
            (Workspace.masc_root_dir config)
            "paused-work-dispositions")
         ("keeper-" ^ sha256 from_keeper))
      ("operation-" ^ sha256 request.operator_operation_id ^ ".json")
  in
  let retired_bytes =
    "retired paused-work receipt must remain opaque: not-json\000settlement_id"
  in
  mkdir_p (Filename.dirname retired_path);
  Out_channel.with_open_bin retired_path (fun channel ->
    output_string channel retired_bytes);
  (match
     Receipt.load
       config
       ~keeper_name:from_keeper
       ~operator_operation_id:request.operator_operation_id
   with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "retired receipt directory was read"
   | Error detail -> Alcotest.fail detail);
  Transaction.transfer_pending config ~from_keeper ~to_keeper request
  |> Result.map_error Transaction.error_to_string
  |> require_ok "commit beside retired receipt directory"
  |> fun result -> check_applied ~expected_target:Transaction.Enqueued result.projection;
  Alcotest.(check bool)
    "current receipt uses a disjoint path"
    true
    (Sys.file_exists
       (receipt_path
          config
          ~keeper_name:from_keeper
          ~operator_operation_id:request.operator_operation_id));
  Alcotest.(check string)
    "retired receipt is not consumed or rewritten"
    retired_bytes
    (In_channel.with_open_bin retired_path In_channel.input_all)
;;

let test_transfer_busy_has_zero_mutation () =
  with_transfer_lane (fun config from_keeper to_keeper _source_meta _target_meta request ->
    let base_path = config.Workspace.base_path in
    (match
       Keeper_turn_admission.run_admin_if_free
         ~base_path
         ~keeper_name:from_keeper
         (fun () ->
            Transaction.transfer_pending config ~from_keeper ~to_keeper request)
     with
     | `Ran (Error { cause = Transaction.Admission_busy _; _ }) -> ()
     | `Ran (Error error) -> Alcotest.fail (Transaction.error_to_string error)
     | `Ran (Ok _) | `Busy _ ->
       Alcotest.fail "transfer was not deferred by turn admission");
    let source =
      Persistence.load_state_result ~base_path ~keeper_name:from_keeper
      |> require_ok "load admission-busy source"
    in
    let target =
      Persistence.load_state_result ~base_path ~keeper_name:to_keeper
      |> require_ok "load admission-busy target"
    in
    Alcotest.(check int) "busy retains source" 1 (Queue.length (State.pending source));
    Alcotest.(check int) "busy leaves target empty" 0 (Queue.length (State.pending target)))
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
    (* Consume the transferred source the way production does. Once the target
       has consumed the source, replaying the transfer must not enqueue it
       again. *)
    let selection =
      Persistence.peek_when_result
        ~base_path
        ~keeper_name:to_keeper
        ~ready:(fun _ -> true)
      |> require_ok "peek transferred target source"
      |> require_some "transferred target selection"
    in
    (match
       Persistence.ack_pending_result
         ~base_path
         ~keeper_name:to_keeper
         ~selection
         ()
     with
     | Ok Persistence.Ack_applied -> ()
     | Ok (Persistence.Ack_applied_followup_failed detail) ->
       Alcotest.failf "target ACK cleanup failed: %s" detail
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

let test_replay_after_source_ack_projects_target () =
  with_transfer_lane (fun config from_keeper to_keeper source_meta target_meta request ->
    let transfer : Receipt.transfer_owner =
      { from_keeper
      ; to_keeper
      ; target_trace_id = target_meta.runtime.trace_id
      ; target_generation = request.target_generation
      ; source = request.source
      ; source_revision = request.source_revision
      ; continuation_binding = request.continuation_binding
      }
    in
    let receipt : Receipt.t =
      { keeper_name = from_keeper
      ; expected_trace_id = source_meta.runtime.trace_id
      ; expected_generation = request.owner_nonce
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
      ; owner_nonce = request.owner_nonce
      ; operator_operation_id = request.operator_operation_id
      ; from_keeper
      ; to_keeper
      }
    in
    (* The source ACK is only a fixture precondition here. *)
    ignore
      (Keeper_registry_event_queue.transfer_pending_accepted_result
         ~base_path:config.Workspace.base_path
         from_keeper
         ~current_owner_nonce:request.owner_nonce
         ~applied_at:receipt.requested_at
         ~transfer:causal
       |> require_ok "simulate committed source ACK");
    let replay =
      Transaction.transfer_pending config ~from_keeper ~to_keeper request
      |> Result.map_error Transaction.error_to_string
      |> require_ok "resume after source ACK"
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
            "commit exact pending move"
            `Quick
            test_transfer_commits_exact_pending_move
        ; Alcotest.test_case
            "retired v2 receipt is rejected"
            `Quick
            test_retired_v2_receipt_file_is_rejected
        ; Alcotest.test_case
            "retired receipt directory is not read"
            `Quick
            test_retired_receipt_directory_is_not_read
        ; Alcotest.test_case
            "admission busy has zero mutation"
            `Quick
            test_transfer_busy_has_zero_mutation
        ; Alcotest.test_case
            "stale source revision has no effect"
            `Quick
            test_stale_source_revision_has_no_receipt_or_target_effect
        ; Alcotest.test_case
            "replay after source ACK projects target"
            `Quick
            test_replay_after_source_ack_projects_target
        ] )
    ]
;;
