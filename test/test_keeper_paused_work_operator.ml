open Masc

module Queue = Keeper_event_queue
module State = Keeper_event_queue_state
module Persistence = Keeper_event_queue_persistence
module Disposition = Keeper_paused_work_disposition_receipt
module Operator = Keeper_paused_work_operator

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
  ( { post_id = Queue.hitl_resolution_post_id resolution
    ; urgency = Queue.Immediate
    ; arrived_at = 2.0
    ; payload = Queue.Hitl_resolved resolution
    }
  , channel )
;;

let common operation fields =
  `Assoc
    ([ "schema", `String "masc.keeper.paused-work.operator-request.v1"
     ; "operation", `String operation
     ]
     @ fields)
;;

let test_strict_request_codec () =
  let resume =
    common
      "resume_owner"
      [ "owner_generation", `Int 7
      ; "operator_operation_id", `String "operator-resume"
      ]
  in
  (match Operator.request_of_yojson resume with
   | Ok
       (Operator.Resume_owner
         { owner_generation = 7; operator_operation_id = "operator-resume" }) ->
     ()
   | Ok _ -> Alcotest.fail "resume request decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
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
      ; "source_revision", int64_json 11L
      ; "owner_generation", `Int 7
      ; "operator_operation_id", `String "operator-cancel"
      ; "reason", `String "operator rejected retained work"
      ; "settled_at", `Float 3.0
      ]
  in
  (match Operator.request_of_yojson cancel with
   | Ok (Operator.Cancel_pending request) ->
     Alcotest.(check bool) "cancel source exact" true (request.source = board_source);
     Alcotest.(check int64) "cancel revision exact" 11L request.source_revision
   | Ok _ -> Alcotest.fail "pending cancellation decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
  let terminal_source, channel = terminal_source () in
  let transfer =
    common
      "transfer_owner"
      [ "source", Queue.stimulus_to_yojson terminal_source
      ; "source_revision", int64_json 12L
      ; "owner_generation", `Int 7
      ; "target_generation", `Int 8
      ; "to_keeper", `String "successor"
      ; ( "continuation_binding"
        , Disposition.continuation_binding_to_yojson (Disposition.Routed channel) )
      ; "operator_operation_id", `String "operator-transfer"
      ; "settled_at", `Float 4.0
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
  let source_terminal =
    common
      "settle_from_source_terminal"
      [ "source", Queue.stimulus_to_yojson terminal_source
      ; "source_revision", int64_json 13L
      ; "owner_generation", `Int 7
      ; "source_receipt_kind", `String "hitl_terminal"
      ; "operator_operation_id", `String "operator-source-terminal"
      ; "settled_at", `Float 5.0
      ]
  in
  (match Operator.request_of_yojson source_terminal with
   | Ok (Operator.Settle_from_source_terminal request) ->
     Alcotest.(check bool)
       "source terminal exact"
       true
       (request.source = terminal_source)
   | Ok _ -> Alcotest.fail "source-terminal decoded to the wrong operation"
   | Error detail -> Alcotest.fail detail);
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
            ; "runtime_id", `String "runtime.primary"
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
        ; runtime = { meta.runtime with generation = 17 }
        }
      in
      Keeper_meta_store.write_meta config meta |> require_ok "persist inventory metadata";
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
        (json |> member "queue" |> member "revision" |> to_int64);
      Alcotest.(check int)
        "inventory exact pending count"
        1
        (json |> member "queue" |> member "pending" |> to_list |> List.length);
      ignore
        (Persistence.claim_when_result
           ~base_path
           ~keeper_name
           ~claimed_at:3.0
           ~ready:(fun _ -> true)
           ()
         |> require_ok "claim inventory source"
         |> require_some "inventory active lease");
      let active_state =
        Persistence.load_state_result ~base_path ~keeper_name
        |> require_ok "load active inventory state"
      in
      let active_inventory =
        Operator.inventory_json config ~keeper_name
        |> require_inventory_ok "project active paused-work inventory"
      in
      let lease_json = active_inventory |> member "queue" |> member "active_lease" in
      let active_cancel =
        common
          "cancel_accepted"
          [ "source_state", `String "active_lease"
          ; "lease", lease_json
          ; "source_revision", int64_json (State.revision active_state)
          ; "owner_generation", `Int 17
          ; "operator_operation_id", `String "operator-cancel-active"
          ; "reason", `String "operator cancelled active retained work"
          ; "settled_at", `Float 4.0
          ]
      in
      match Operator.request_of_yojson active_cancel with
      | Ok (Operator.Cancel_active_lease _) -> ()
      | Ok _ -> Alcotest.fail "active lease cancellation decoded incorrectly"
      | Error detail -> Alcotest.fail detail)
;;

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Alcotest.run
    "keeper paused-work operator"
    [ ( "codec"
      , [ Alcotest.test_case "strict four-way request codec" `Quick test_strict_request_codec ] )
    ; ( "inventory"
      , [ Alcotest.test_case
            "durable exact identity and revision"
            `Quick
            test_inventory_exposes_exact_durable_fences
        ] )
    ]
;;
