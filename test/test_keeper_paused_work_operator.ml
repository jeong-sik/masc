open Masc

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Disposition = Keeper_paused_work_disposition_receipt
module Operator = Keeper_paused_work_operator

let test_switch : Eio.Switch.t option ref = ref None

let current_switch () =
  match !test_switch with
  | Some sw -> sw
  | None -> Alcotest.fail "paused-work operator Owner switch is not installed"
;;
module Cancellation = Keeper_paused_work_cancellation_transaction

let require_ok label = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s: %s" label detail
;;

let require_inventory_ok label = function
  | Ok value -> value
  | Error error ->
    Alcotest.failf "%s: %s" label (Operator.inventory_error_to_string error)
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

let int64_json value = `Intlit (Int64.to_string value)

let int64_of_json label = function
  | `Int value -> Int64.of_int value
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some parsed -> parsed
     | None -> Alcotest.failf "%s: invalid int64 literal %S" label value)
  | json ->
    Alcotest.failf "%s: expected int or intlit, got %s" label (Yojson.Safe.to_string json)
;;

let board_source : Queue.stimulus =
  { post_id = "paused-work-operator-source"
  ; urgency = Queue.Normal
  ; arrived_at = 1.0
  ; payload = Queue.Bootstrap
  }
;;

let terminal_source () =
  let channel =
    Keeper_continuation_channel.dashboard ~thread_id:"operator-thread"
    |> require_ok "construct terminal channel"
  in
  let resolution : Queue.hitl_resolution =
    { approval_id = "operator-approval"
    ; decision = Queue.Hitl_approved
    ; channel
    }
  in
  ( ({ post_id = Queue.hitl_resolution_post_id resolution
    ; urgency = Queue.Immediate
    ; arrived_at = 2.0
    ; payload = Queue.Hitl_resolved resolution
    } : Queue.stimulus)
  , channel )
;;

let common operation fields =
  `Assoc
    ([ "schema", `String "masc.keeper.paused-work.operator-request.v4"
     ; "operation", `String operation
     ]
     @ fields)
;;

let with_source_terminal_lane f =
  let base_path = Filename.temp_dir "keeper-paused-work-operator-terminal" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
       let config = Workspace.default_config base_path in
       ignore (Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "paused-work-operator-terminal" in
       let meta =
         Masc_test_deps.meta_of_json_fixture
           (`Assoc
             [ "name", `String keeper_name
             ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
             ; "trace_id", `String "trace-paused-work-operator-terminal"
             ; "autoboot_enabled", `Bool false
             ])
         |> require_ok "parse source-terminal metadata"
       in
       let meta =
         { meta with
           paused = true
         ; latched_reason =
             Some
               (Keeper_latched_reason.Operator_paused
                  { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })
         }
       in
       Keeper_meta_store.replace_snapshot config meta |> require_ok "persist source-terminal metadata";
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
       let source, _channel = terminal_source () in
       Persistence.update_result ~base_path ~keeper_name (fun pending ->
         Queue.enqueue pending source)
       |> require_ok "seed source-terminal event";
       let source_incarnation =
         Persistence.load_state_result ~base_path ~keeper_name
         |> require_ok "load source-terminal state"
         |> State.select_when
              ~ready:(Queue.stimulus_identity_equal source)
         |> require_some "select source-terminal event"
         |> fun selection -> selection.admitted_revision
       in
       let source_receipt =
         State.source_terminal_receipt_of_stimulus source
         |> require_ok "derive source-terminal receipt"
       in
       let request : Keeper_paused_work_source_terminal_transaction.request =
         { source
         ; source_incarnation
         ; source_receipt
         ; operator_operation_id = "operator-source-terminal-response"
         }
       in
       f config keeper_name request)
;;

let test_strict_request_codec () =
  let resume =
    common
      "resume_owner"
      [ "operator_operation_id", `String "operator-resume"
      ]
  in
  (match Operator.request_of_yojson resume with
   | Ok
       (Operator.Resume_owner
         { operator_operation_id = "operator-resume" }) ->
     ()
   | Ok _ -> Alcotest.fail "resume request decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
  let obsolete_v2_resume =
    match resume with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "schema", _ -> "schema", `String "masc.keeper.paused-work.operator-request.v2"
             | field -> field)
           fields)
    | _ -> Alcotest.fail "resume fixture must be a JSON object"
  in
  (match Operator.request_of_yojson obsolete_v2_resume with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "request codec accepted obsolete v2 schema");
  let with_extra =
    match resume with
    | `Assoc fields -> `Assoc (("unexpected", `Bool true) :: fields)
    | _ -> assert false
  in
  (match Operator.request_of_yojson with_extra with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "request codec accepted an extra field");
  let cancel =
    common
      "cancel_accepted"
      [ "source_state", `String "pending"
      ; "source", Queue.stimulus_to_yojson board_source
      ; "source_incarnation", int64_json 11L
      ; "operator_operation_id", `String "operator-cancel"
      ; "reason", `String "operator rejected retained work"
      ]
  in
  (match Operator.request_of_yojson cancel with
   | Ok (Operator.Cancel_pending request) ->
     Alcotest.(check bool) "cancel source exact" true (request.source = board_source);
     Alcotest.(check int64)
       "cancel incarnation exact"
       11L
       request.source_incarnation
  | Ok _ -> Alcotest.fail "pending cancellation decoded to the wrong operation"
  | Error detail -> Alcotest.fail detail);
  let cancel_with_obsolete_settled_at =
    match cancel with
    | `Assoc fields -> `Assoc (("settled_at", `Float 3.0) :: fields)
    | _ -> Alcotest.fail "cancel fixture must be a JSON object"
  in
  (match Operator.request_of_yojson cancel_with_obsolete_settled_at with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "cancel request accepted obsolete settled_at field");
  let terminal_source, channel = terminal_source () in
  let transfer =
    common
      "transfer_owner"
      [ "source", Queue.stimulus_to_yojson terminal_source
      ; "source_incarnation", int64_json 12L
      ; "to_keeper", `String "successor"
      ; ( "continuation_binding"
        , Disposition.continuation_binding_to_yojson (Disposition.Routed channel) )
      ; "operator_operation_id", `String "operator-transfer"
      ]
  in
  (match Operator.request_of_yojson transfer with
   | Ok (Operator.Transfer_owner { to_keeper = "successor"; request }) ->
     Alcotest.(check bool)
       "transfer source exact"
       true
       (request.source = terminal_source)
   | Ok _ -> Alcotest.fail "transfer decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
  let transfer_with_obsolete_settled_at =
    match transfer with
    | `Assoc fields -> `Assoc (("settled_at", `Float 4.0) :: fields)
    | _ -> Alcotest.fail "transfer fixture must be a JSON object"
  in
  (match Operator.request_of_yojson transfer_with_obsolete_settled_at with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "transfer request accepted obsolete settled_at field");
  let source_terminal =
    common
      "ack_source_terminal"
      [ "source", Queue.stimulus_to_yojson terminal_source
      ; "source_incarnation", int64_json 13L
      ; "source_receipt_kind", `String "hitl_terminal"
      ; "operator_operation_id", `String "operator-source-terminal"
      ]
  in
  (match Operator.request_of_yojson source_terminal with
   | Ok (Operator.Ack_source_terminal request) ->
     Alcotest.(check bool)
       "source terminal exact"
       true
       (request.source = terminal_source)
   | Ok _ -> Alcotest.fail "source-terminal decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
  let source_terminal_with_obsolete_settled_at =
    match source_terminal with
    | `Assoc fields -> `Assoc (("settled_at", `Float 5.0) :: fields)
    | _ -> Alcotest.fail "source-terminal fixture must be a JSON object"
  in
  (match Operator.request_of_yojson source_terminal_with_obsolete_settled_at with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "source-terminal request accepted obsolete settled_at field");
  let mismatched_source_terminal =
    match source_terminal with
    | `Assoc fields ->
      `Assoc
        (List.map
           (function
             | "source_receipt_kind", _ ->
               "source_receipt_kind", `String "fusion_terminal"
             | field -> field)
           fields)
    | _ -> assert false
  in
  (match Operator.request_of_yojson mismatched_source_terminal with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "source-terminal request accepted a mismatched receipt")
;;

let test_source_terminal_outcome_is_ack_boundary () =
  with_source_terminal_lane (fun config keeper_name request ->
    let outcome =
      match Operator.execute config ~keeper_name (Operator.Ack_source_terminal request) with
      | Ok outcome -> outcome
      | Error error -> Alcotest.fail (Operator.error_to_string error)
    in
    let json = Operator.outcome_to_yojson outcome in
    let open Yojson.Safe.Util in
    let receipt_fields =
      match json |> member "receipt" with
      | `Assoc fields -> fields
      | _ -> Alcotest.fail "operator response omitted durable source-ACK receipt"
    in
    let source_terminal_fields =
      match List.assoc_opt "source_terminal" receipt_fields with
      | Some (`Assoc fields) -> fields
      | _ -> Alcotest.fail "durable source-ACK receipt omitted source_terminal"
    in
    Alcotest.(check bool)
      "source-terminal outcome projection is complete"
      true
      (Operator.outcome_projection_complete outcome);
    Alcotest.(check string)
      "operator response names source ACK"
      "ack_source_terminal"
      (json |> member "operation" |> to_string);
    Alcotest.(check string)
      "durable receipt names source ACK"
      "ack_source_terminal"
      (json |> member "receipt" |> member "operation" |> to_string);
    Alcotest.(check (list string))
      "durable source-terminal receipt has the exact hard-cut fields"
      [ "source"; "source_incarnation"; "source_receipt_kind" ]
      (source_terminal_fields
       |> List.map fst
       |> List.sort String.compare))
;;

let test_inventory_exposes_exact_durable_fences () =
  let base_path = Filename.temp_dir "keeper-paused-work-operator" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let keeper_name = "paused-work-inventory" in
      let meta =
        Masc_test_deps.meta_of_json_fixture
          (`Assoc
            [ "name", `String keeper_name
            ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
            ; "trace_id", `String "trace-paused-work-inventory"
            ; "autoboot_enabled", `Bool false
            ])
        |> require_ok "parse inventory metadata"
      in
      let meta =
        { meta with
          paused = true
        ; latched_reason =
            Some
              (Keeper_latched_reason.Operator_paused
                 { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive })
        }
      in
      Keeper_meta_store.replace_snapshot config meta |> require_ok "persist inventory metadata";
      Persistence.update_result ~base_path ~keeper_name (fun pending ->
        Queue.enqueue pending board_source)
      |> require_ok "persist inventory source";
      let state =
        Persistence.load_state_result ~base_path ~keeper_name
        |> require_ok "load inventory state"
      in
      let json =
        Operator.inventory_json config ~keeper_name
        |> require_inventory_ok "project paused-work inventory"
      in
      let open Yojson.Safe.Util in
      Alcotest.(check string)
        "inventory trace fence"
        "trace-paused-work-inventory"
        (json |> member "owner" |> member "trace_id" |> to_string);
      Alcotest.(check int)
        "inventory generation fence"
        17
        (json |> member "owner" |> member "generation" |> to_int);
      Alcotest.(check int64)
        "inventory revision fence"
        (State.revision state)
        (json |> member "queue" |> member "revision" |> int64_of_json "queue.revision");
      Alcotest.(check int)
        "inventory exact pending count"
        1
        (json |> member "queue" |> member "pending" |> to_list |> List.length);
      Alcotest.(check int)
        "inventory exact accepted transfer projection count"
        0
        (json
         |> member "queue"
         |> member "accepted_transfer_projection_count"
         |> to_int))
;;

let admission_error_json block =
  Operator.error_to_yojson
    (Operator.Cancellation_rejected (Cancellation.Admission_busy block))
;;

let test_admission_busy_http_json_preserves_typed_detail () =
  let open Yojson.Safe.Util in
  let holder =
    admission_error_json
      (Keeper_owner.Turn_busy
         (Some { lane = Keeper_owner.Chat_operation; started_at = 42.5 }))
  in
  Alcotest.(check string)
    "holder error code"
    "keeper_owner_busy"
    (holder |> member "error_code" |> to_string);
  Alcotest.(check string)
    "holder kind"
    "turn_busy"
    (holder |> member "admission" |> member "kind" |> to_string);
  Alcotest.(check string)
    "holder lane"
    "chat_operation"
    (holder |> member "admission" |> member "holder" |> member "lane" |> to_string);
  Alcotest.(check (float 0.0))
    "holder start"
    42.5
    (holder
     |> member "admission"
     |> member "holder"
     |> member "started_at"
     |> to_float);
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  let shutdown =
    admission_error_json
      (Keeper_owner.Shutdown_requested operation_id)
  in
  Alcotest.(check string)
    "shutdown operation id"
    (Keeper_shutdown_types.Operation_id.to_string operation_id)
    (shutdown |> member "admission" |> member "operation_id" |> to_string)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  test_switch := Some sw;
  Alcotest.run
    "keeper paused-work operator"
    [ ( "codec"
      , [ Alcotest.test_case "strict four-way request codec" `Quick test_strict_request_codec ] )
    ; ( "source terminal"
      , [ Alcotest.test_case
            "outcome is ACK boundary"
            `Quick
            test_source_terminal_outcome_is_ack_boundary
        ] )
    ; ( "inventory"
      , [ Alcotest.test_case
            "durable exact identity and revision"
            `Quick
            test_inventory_exposes_exact_durable_fences
        ] )
    ; ( "admission"
      , [ Alcotest.test_case
            "HTTP JSON preserves typed busy detail"
            `Quick
            test_admission_busy_http_json_preserves_typed_detail
        ] )
    ]
;;
