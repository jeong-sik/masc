open Alcotest
open Masc

module Registry_event_queue_source = Keeper_registry_event_queue
module Keeper_registry_event_queue = struct
  include Registry_event_queue_source

  let snapshot ~base_path keeper_name =
    match snapshot_result ~base_path keeper_name with
    | Ok queue -> queue
    | Error detail -> fail detail
  ;;
end

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let path = Filename.temp_file "schedule_consumer_dispatch_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)
;;

let write_empty_file path =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> ())
;;

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)
;;

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))
;;

let rec jsonl_rows_under path =
  if Sys.is_directory path
  then
    Sys.readdir path
    |> Array.to_list
    |> List.concat_map (fun entry -> jsonl_rows_under (Filename.concat path entry))
  else if Filename.check_suffix path ".jsonl"
  then
    read_file path
    |> String.split_on_char '\n'
    |> List.filter_map (fun line ->
      let line = String.trim line in
      if String.equal line "" then None else Some (Yojson.Safe.from_string line))
  else []
;;

let reaction_ledger_dir ~base_path ~keeper_name =
  (* Ask the writer where it writes. Rebuilding the path here made a storage
     generation bump silently point the test at an empty old namespace. *)
  Masc.Keeper_reaction_ledger.store_dir
    ~masc_root:(Common.masc_dir_from_base_path ~base_path)
    ~keeper_name
;;

let write_malformed_reaction_ledger_row ~base_path ~keeper_name =
  let month_dir =
    Filename.concat (reaction_ledger_dir ~base_path ~keeper_name) "2026-01"
  in
  mkdir_p month_dir;
  write_file (Filename.concat month_dir "01.jsonl") "not-json\n"
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  let pool =
    Domain_pool.create
      ~sw
      ~domain_count:1
      (Eio.Stdenv.domain_mgr env)
  in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Unix.putenv "MASC_BASE_PATH" dir;
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "1";
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
   | Ok _ -> ()
   | Error error -> fail (Keeper_owner_registry.install_error_to_string error));
  Executor_pool_ref.For_testing.with_pool
    (Domain_pool.executor_pool pool)
    (fun () -> f config)
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let keeper_meta_for_name keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "trace_id", `String ("trace-" ^ keeper_name)
        ])
  with
  | Ok meta -> meta
  | Error msg -> fail ("keeper meta parse failed: " ^ msg)
;;

let persist_keeper_meta ?proactive_enabled config keeper_name =
  let meta =
    let meta = keeper_meta_for_name keeper_name in
    match proactive_enabled with
    | None -> meta
    | Some enabled ->
      { meta with
        autoboot_enabled = true
      ; proactive = { enabled }
      }
  in
  (match Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> fail ("keeper meta write failed: " ^ detail));
  meta
;;

let register_keeper ?proactive_enabled config keeper_name =
  let meta =
    let meta = keeper_meta_for_name keeper_name in
    match proactive_enabled with
    | None -> meta
    | Some enabled ->
      { meta with
        autoboot_enabled = true
      ; proactive = { enabled }
      }
  in
  (match
     Keeper_owner_registry.create_meta
       ~base_path:config.Workspace_utils.base_path
       meta
   with
   | Ok (Some _) -> ()
   | Ok None -> fail "owner metadata creation removed its snapshot"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  Keeper_registry.For_testing.register
    ~base_path:config.Workspace_utils.base_path
    keeper_name
    meta
;;

let register_offline_keeper ?proactive_enabled config keeper_name =
  let meta =
    let meta = keeper_meta_for_name keeper_name in
    match proactive_enabled with
    | None -> meta
    | Some enabled ->
      { meta with
        autoboot_enabled = true
      ; proactive = { enabled }
      }
  in
  (match
     Keeper_owner_registry.create_meta
       ~base_path:config.Workspace_utils.base_path
       meta
   with
   | Ok (Some _) -> ()
   | Ok None -> fail "owner metadata creation removed its snapshot"
   | Error error -> fail (Keeper_owner_registry.command_error_to_string error));
  ignore
    (Keeper_registry.register_offline
       ~base_path:config.Workspace_utils.base_path
       keeper_name
       meta)
;;

let dashboard_schedule_row_exn dashboard ~schedule_id =
  let open Yojson.Safe.Util in
  match
    dashboard
    |> member "requests"
    |> to_list
    |> List.find_opt (fun row ->
      String.equal (row |> member "schedule_id" |> to_string) schedule_id)
  with
  | Some row -> row
  | None -> fail ("schedule missing from dashboard projection: " ^ schedule_id)
;;

let board_post_payload =
  `Assoc
    [ "kind", `String "masc.board_post"
    ; ( "body"
      , `Assoc
          [ "title", `String "Scheduled check-in"
          ; "content", `String "Daily schedule fired"
          ; "author", `String "schedule-bot"
          ; "hearth", `String "ops"
          ; "ttl_hours", `Int 0
          ; "meta", `Assoc [ "purpose", `String "test" ]
          ] )
    ]
;;

let keeper_wake_payload_for keeper_name =
  `Assoc
    [ "kind", `String "masc.keeper_wake"
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String keeper_name
          ; "title", `String "Scheduled lane wake"
          ; "message", `String "Run the scheduled maintenance lane now."
          ; "urgency", `String "immediate"
          ] )
    ]
;;

let keeper_wake_payload = keeper_wake_payload_for "schedule-keeper"

let keeper_wake_payload_with_result_delivery channel =
  match
    Schedule_payload_projection.set_keeper_wake_result_delivery
      ~payload:keeper_wake_payload
      ~channel:(Some channel)
  with
  | Ok payload -> payload
  | Error detail -> fail detail
;;

let unsupported_payload =
  `Assoc
    [ "kind", `String "legacy.unsupported_scheduler_payload"
    ; "body", `Assoc [ "message", `String "This payload is not in the schedule consumer catalog." ]
    ]
;;

let canonical_keeper_wake_receipt_fields () =
  [ "kind", `String "masc.keeper_wake.enqueued"
  ; "keeper_name", `String "schedule-keeper"
  ; "schedule_instance_id", `String "canonical-instance"
  ; "schedule_id", `String "canonical-schedule"
  ; "urgency", `String "immediate"
  ; "post_id", `String "canonical-occurrence"
  ; "queue", `String "keeper_event_queue"
  ; "stimulus", `String "schedule_due"
  ; "stimulus_id", `String "canonical-occurrence"
  ; "result_delivery_policy", `String "none"
  ; "reaction_ledger_status", `String "recorded"
  ; "reaction_ledger_error", `Null
  ; "occurrence_status", `String "awaiting_ack"
  ; "activation_status", `String "deferred"
  ; "activation_reason", `String "owner_unknown"
  ; "activation_detail", `String "owner metadata unavailable"
  ]
;;

let set_receipt_field name value fields =
  (name, value) :: List.remove_assoc name fields
;;

let test_keeper_wake_receipt_decoder_rejects_noncanonical_shapes () =
  let canonical = canonical_keeper_wake_receipt_fields () in
  (match Server_schedule_consumers.dispatch_receipt_of_detail (`Assoc canonical) with
   | Ok _ -> ()
   | Error detail -> fail ("canonical receipt rejected: " ^ detail));
  let failed_terminal =
    canonical
    |> set_receipt_field "occurrence_status" (`String "already_failed")
    |> set_receipt_field "activation_status" (`String "not_required")
    |> set_receipt_field "activation_reason" `Null
    |> set_receipt_field "activation_detail" `Null
  in
  (match
     Server_schedule_consumers.dispatch_receipt_of_detail (`Assoc failed_terminal)
   with
   | Ok
       (Server_schedule_consumers.Keeper_wake_enqueued
          { occurrence_status =
              Server_schedule_consumers.Keeper_wake_already_failed
          ; _
          }) ->
     ()
   | Ok _ -> fail "already_failed receipt decoded to another terminal state"
   | Error detail -> fail ("already_failed receipt rejected: " ^ detail));
  let reject label fields =
    match Server_schedule_consumers.dispatch_receipt_of_detail (`Assoc fields) with
    | Error _ -> ()
    | Ok _ -> fail (label ^ " was accepted")
  in
  reject
    "recorded receipt carrying an error"
    (canonical
     |> set_receipt_field "reaction_ledger_error" (`String "unexpected"));
  reject
    "reaction ledger error without failure status"
    (canonical
     |> set_receipt_field "reaction_ledger_status" `Null
     |> set_receipt_field "reaction_ledger_error" (`String "unexpected"));
  reject
    "signaled activation carrying deferred reason"
    (canonical
     |> set_receipt_field "activation_status" (`String "signaled"));
  reject
    "detail-free activation reason carrying detail"
    (canonical
     |> set_receipt_field "activation_reason" (`String "autoboot_disabled"));
  reject
    "terminal occurrence carrying deferred activation"
    (canonical
     |> set_receipt_field "occurrence_status" (`String "already_acked"));
  reject
    "awaiting occurrence carrying not-required activation"
    (canonical
     |> set_receipt_field "activation_status" (`String "not_required")
     |> set_receipt_field "activation_reason" `Null
     |> set_receipt_field "activation_detail" `Null);
  reject
    "unknown result delivery policy"
    (canonical
     |> set_receipt_field "result_delivery_policy" (`String "best_effort"))
;;

let create_board_schedule config =
  match
    Schedule_service.create config ~schedule_id:"board-sched-1"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:board_post_payload ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_keeper_wake_schedule ?recurrence config =
  match
    Schedule_service.create config ~schedule_id:"keeper-wake-sched-1"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:keeper_wake_payload ~source:Schedule_domain.Operator_request
      ?recurrence ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_routed_keeper_wake_schedule config channel =
  match
    Schedule_service.create
      config
      ~schedule_id:"keeper-wake-routed-sched-1"
      ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at:200.0
      ~payload:(keeper_wake_payload_with_result_delivery channel)
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_named_keeper_wake_schedule config ~schedule_id ~keeper_name =
  match
    Schedule_service.create
      config
      ~schedule_id
      ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at:200.0
      ~payload:(keeper_wake_payload_for keeper_name)
      ~source:Schedule_domain.Operator_request
      ()
  with
  | Ok request -> request
  | Error error ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string error)
;;

let create_unsupported_schedule config =
  match
    Schedule_service.create config ~schedule_id:"unsupported-live-sched"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:unsupported_payload ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_invalid_keeper_wake_schedule config =
  let payload =
    `Assoc
      [ "kind", `String "masc.keeper_wake"
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String "../bad"
            ; "message", `String "This must not report success."
            ] )
      ]
  in
  match
    Schedule_service.create config ~schedule_id:"invalid-keeper-wake-sched"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let tick_ok config ~now =
  match
    Schedule_runner.tick ~consumer:Server_schedule_consumers.consumer config ~now
  with
  | Ok result -> result
  | Error err -> fail (Schedule_runner.runner_error_to_string err)
;;

let find_wake
      state
      ~schedule_instance_id
      ~schedule_id
      ~due_at
      ~payload_digest
  =
  List.find_opt
    (fun (wake : Schedule_domain.wake_record) ->
       String.equal wake.schedule_instance_id schedule_instance_id
       && String.equal wake.schedule_id schedule_id
       && Float.equal wake.due_at due_at
       && String.equal wake.payload_digest payload_digest)
    state.Schedule_store.wakes
;;

let single_occurrence_id (result : Schedule_runner.tick_result) =
  match result.emitted with
  | [ signal ] -> Schedule_occurrence_id.to_string signal.occurrence_id
  | signals ->
    failf "expected one emitted schedule occurrence, got %d" (List.length signals)
;;

let pending_selection_exn ~base_path ~keeper_name =
  match
    Keeper_event_queue_persistence.select_when_result
      ~base_path
      ~keeper_name
      ~now:(Unix.gettimeofday ())
      ~ready:(fun _ -> true)
  with
  | Ok (Some selection) -> selection
  | Ok None -> fail "expected pending keeper selection"
  | Error detail -> fail detail
;;

let runner_status_json_after_dispatches (result : Schedule_runner.tick_result) =
  Schedule_runner_status.reset_for_test ();
  let wake_enqueue_counts =
    Server_bootstrap_maintenance.wake_enqueue_counts_of_dispatches result.dispatches
  in
  Schedule_runner_status.record_tick_ok
    ~wake_enqueue_counts
    ~started_at:201.0
    ~finished_at:201.25
    result;
  Schedule_runner_status.snapshot ()
  |> Schedule_runner_status.snapshot_to_yojson ~now:201.5 ~stale_after_sec:10.0
;;

let test_board_post_schedule_is_rejected_without_mutation () =
  with_workspace
  @@ fun config ->
  let request = create_board_schedule config in
  let result = tick_ok config ~now:201.0 in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch status" "unsupported"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule failed" "failed"
       (Schedule_domain.schedule_status_to_string stored.status));
  check int "board remains unchanged" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()))
;;

(* The Keeper store answering "no such name" and the store failing to answer
   are different facts. The receipt folded both into owner_unknown plus a
   detail string; the first is now its own word, with nothing to parse. *)
let test_keeper_wake_consumer_names_an_absent_owner () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "the stimulus is still enqueued durably" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  match
    Schedule_store.last_wake_for_schedule_instance
      (Schedule_store.read_state config)
      ~schedule_instance_id:request.schedule_instance_id
      ~schedule_id:request.schedule_id
  with
  | None -> fail "missing wake record"
  | Some wake ->
    (match wake.detail with
     | None -> fail "wake detail missing"
     | Some detail ->
       let open Yojson.Safe.Util in
       check string "activation deferred" "deferred"
         (detail |> member "activation_status" |> to_string);
       check string "an absent owner is its own reason" "owner_absent"
         (detail |> member "activation_reason" |> to_string);
       check bool "and carries no detail string" true
         (detail |> member "activation_detail" = `Null);
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { activation_outcome =
                  Server_schedule_consumers.Keeper_wake_activation_deferred
                    Server_schedule_consumers.Keeper_wake_activation_owner_absent
              ; _
              }) ->
          ()
        | Ok _ -> fail "receipt decoded to a different activation outcome"
        | Error reason -> fail ("receipt did not decode: " ^ reason)))
;;

let test_keeper_wake_consumer_records_wake_receipt () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let result =
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      tick_ok config ~now:201.0)
  in
  let occurrence_id = single_occurrence_id result in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch status" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  let runner_status = runner_status_json_after_dispatches result in
  let runner_counts =
    Yojson.Safe.Util.(runner_status |> member "last_counts")
  in
  check string "runner health stays ok" "ok"
    Yojson.Safe.Util.(runner_status |> member "status" |> to_string);
  check int "runner wake enqueued from production receipt" 1
    Yojson.Safe.Util.(runner_counts |> member "wake_enqueued" |> to_int);
  check int "runner wake failed stays zero" 0
    Yojson.Safe.Util.(runner_counts |> member "wake_failed" |> to_int);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "accepted schedule missing"
   | Some stored ->
     check string "one-shot wake delivery completes" "succeeded"
       (Schedule_domain.schedule_status_to_string stored.status));
  (match
     Schedule_store.last_wake_for_schedule_instance
       (Schedule_store.read_state config)
       ~schedule_instance_id:request.schedule_instance_id
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing wake record"
   | Some wake ->
     check string "wake receipt status" "succeeded"
       (Schedule_domain.wake_status_to_string wake.status);
     check (option (float 0.001)) "wake receipt is finished" (Some 201.0)
       wake.finished_at;
     (match wake.detail with
      | Some detail ->
        let open Yojson.Safe.Util in
        check string "wake detail kind" "masc.keeper_wake.enqueued"
          (detail |> member "kind" |> to_string);
        check string "wake detail queue" "keeper_event_queue"
          (detail |> member "queue" |> to_string);
        check string "wake detail stimulus" "schedule_due"
          (detail |> member "stimulus" |> to_string);
        check string "legacy wake has explicit no-result receipt" "none"
          (detail |> member "result_delivery_policy" |> to_string);
        check string "wake keeper" "schedule-keeper"
          (detail |> member "keeper_name" |> to_string);
        check string "durable enqueue is separate from activation" "deferred"
          (detail |> member "activation_status" |> to_string);
        check string "missing owner truth fails activation closed" "owner_unknown"
          (detail |> member "activation_reason" |> to_string);
        check string
          "absent executor produces typed no-activation"
          "durable keeper metadata read unavailable: executor pool is not installed"
          (detail |> member "activation_detail" |> to_string)
      | None -> fail "wake detail missing"));
  let queue =
    Keeper_registry_event_queue.snapshot
      ~base_path:config.Workspace_utils.base_path
      "schedule-keeper"
  in
  check int "one keeper event queued" 1 (Keeper_event_queue.length queue);
  (match Keeper_event_queue.dequeue queue with
   | None -> fail "expected queued scheduled wake"
   | Some (stimulus, rest) ->
     check bool "queue rest empty" true (Keeper_event_queue.is_empty rest);
     check string "post id is occurrence id" occurrence_id stimulus.post_id;
     check string "urgency" "immediate"
       (Keeper_event_queue.urgency_to_string stimulus.urgency);
     check (float 0.001) "arrived_at from tick now" 201.0 stimulus.arrived_at;
     (match stimulus.payload with
     | Keeper_event_queue.Schedule_due wake ->
       check string "wake occurrence identity" occurrence_id wake.occurrence_id;
       check string "wake schedule" request.schedule_id wake.schedule_id;
       check string "wake title" "Scheduled lane wake" (Option.get wake.title);
       check string "wake message" "Run the scheduled maintenance lane now."
         wake.message;
       check string "wake digest"
         (Schedule_domain.payload_digest request.payload)
         wake.payload_digest;
       check bool "legacy schedule has no result destination" true
         (Option.is_none wake.result_delivery)
      | _ -> fail "expected Schedule_due payload"))
  ;
  check int "keeper wake does not create board posts" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()));
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row = dashboard_schedule_row_exn dashboard ~schedule_id:request.schedule_id in
    check bool "running one-shot has no next due occurrence" true
      (row |> member "next_due_at" |> to_option to_float |> Option.is_none);
    let receipt = row |> member "dispatch_receipt" in
    check string "receipt recognized" "recognized"
      (receipt |> member "projection_status" |> to_string);
    check string "receipt kind" "masc.keeper_wake.enqueued"
      (receipt |> member "kind" |> to_string);
    check string "receipt occurrence awaits ack" "awaiting_ack"
      (receipt |> member "occurrence_status" |> to_string);
    check string "receipt activation is deferred" "deferred"
      (receipt |> member "activation_status" |> to_string);
    check string "receipt activation reason is typed" "owner_unknown"
      (receipt |> member "activation_reason" |> to_string);
    check string "receipt queue" "keeper_event_queue"
      (receipt |> member "queue" |> to_string);
    check string "receipt stimulus" "schedule_due"
      (receipt |> member "stimulus" |> to_string);
    check string "receipt keeper" "schedule-keeper"
      (receipt |> member "keeper_name" |> to_string);
    check string "receipt schedule instance" request.schedule_instance_id
      (receipt |> member "schedule_instance_id" |> to_string);
    check string "receipt schedule" request.schedule_id
      (receipt |> member "schedule_id" |> to_string);
    check string "receipt urgency" "immediate"
      (receipt |> member "urgency" |> to_string);
    check string "receipt post id" occurrence_id
      (receipt |> member "post_id" |> to_string);
    check string "receipt reaction ledger recorded" "recorded"
      (receipt |> member "reaction_ledger_status" |> to_string);
    check string "receipt result policy remains explicit" "none"
      (receipt |> member "result_delivery_policy" |> to_string);
    let queue_evidence = row |> member "keeper_queue_evidence" in
    check string "queue evidence matched" "matched_pending"
      (queue_evidence |> member "projection_status" |> to_string);
    check string "queue evidence source" "durable_event_queue_snapshot"
      (queue_evidence |> member "source" |> to_string);
    check string "queue evidence keeper" "schedule-keeper"
      (queue_evidence |> member "keeper_name" |> to_string);
    check string "queue evidence stimulus" "schedule_due"
      (queue_evidence |> member "stimulus" |> to_string);
    check string "queue evidence matched bucket" "pending"
      (queue_evidence |> member "matched_bucket" |> to_string);
    check string "queue evidence matched payload" "schedule_due"
      (queue_evidence |> member "matched_payload_kind" |> to_string);
    check string "queue evidence matched schedule" request.schedule_id
      (queue_evidence |> member "matched_schedule_id" |> to_string);
    check string "queue evidence matched schedule instance"
      request.schedule_instance_id
      (queue_evidence |> member "matched_schedule_instance_id" |> to_string);
    check (float 0.001) "queue evidence wake due_at" request.due_at
      (queue_evidence |> member "wake_due_at" |> to_float);
    check string "queue evidence wake digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "wake_payload_digest" |> to_string);
    check (float 0.001) "queue evidence matched due_at" request.due_at
      (queue_evidence |> member "matched_due_at" |> to_float);
    check string "queue evidence matched digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "matched_payload_digest" |> to_string);
    check int "queue evidence pending count" 1
      (queue_evidence |> member "pending_count" |> to_int);
    check int "queue evidence read errors" 0
      (queue_evidence |> member "read_errors" |> to_list |> List.length)
  ; let terminal_dashboard =
      Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
    in
    let terminal_row =
      dashboard_schedule_row_exn terminal_dashboard ~schedule_id:request.schedule_id
    in
    check string "wake receipt succeeded" "succeeded"
      (terminal_row |> member "last_wake" |> member "status" |> to_string);
    check string "terminal projection retains recognized receipt" "recognized"
      (terminal_row
       |> member "dispatch_receipt"
       |> member "projection_status"
       |> to_string);
    check string "the schedule reached succeeded" "succeeded"
      (terminal_row |> member "status" |> to_string)
;;

let test_routed_schedule_carries_occurrence_destination_to_keeper () =
  with_workspace
  @@ fun config ->
  let channel =
    match
      Keeper_continuation_channel.slack
        ~team_id:(Some "team-1")
        ~channel_id:"channel-1"
        ~thread_ts:(Some "1710000000.100")
        ~user_id:"user-1"
    with
    | Ok channel -> channel
    | Error detail -> fail detail
  in
  let request = create_routed_keeper_wake_schedule config channel in
  let result =
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      tick_ok config ~now:201.0)
  in
  let occurrence_id = single_occurrence_id result in
  let queue =
    Keeper_registry_event_queue.snapshot
      ~base_path:config.Workspace_utils.base_path
      "schedule-keeper"
  in
  let stimulus =
    match Keeper_event_queue.dequeue queue with
    | Some (stimulus, _) -> stimulus
    | None -> fail "expected routed scheduled wake"
  in
  (match stimulus.payload with
   | Keeper_event_queue.Schedule_due wake ->
     check string "schedule occurrence survives due consumption"
       occurrence_id
       wake.occurrence_id;
     (match wake.result_delivery with
      | Some persisted ->
        check bool "exact schedule result route survives due consumption" true
          (Keeper_continuation_channel.same_route channel persisted)
      | None -> fail "scheduled result destination was lost");
     (match Keeper_event_queue.continuation_channel_of_payload stimulus.payload with
      | Some named ->
        check bool "payload accessor names the exact continuation channel" true
          (Keeper_continuation_channel.same_route channel named)
      | None -> fail "routed schedule payload names no continuation channel")
   | _ -> fail "expected Schedule_due payload");
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row = dashboard_schedule_row_exn dashboard ~schedule_id:request.schedule_id in
  check string "the schedule FSM reached succeeded" "succeeded"
    (row |> member "status" |> to_string);
  check string "dispatch receipt preserves routed result policy" "reply_to_origin"
    (row
     |> member "dispatch_receipt"
     |> member "result_delivery_policy"
     |> to_string);
;;

let test_recurring_wakes_keep_distinct_occurrence_ids () =
  with_workspace
  @@ fun config ->
  let _request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
      config
  in
  let first_id = tick_ok config ~now:201.0 |> single_occurrence_id in
  let second_id = tick_ok config ~now:261.0 |> single_occurrence_id in
  check bool "recurrences have distinct identities" false (String.equal first_id second_id);
  let queued =
    Keeper_registry_event_queue.snapshot
      ~base_path:config.Workspace_utils.base_path
      "schedule-keeper"
    |> Keeper_event_queue.to_list
  in
  check int "both occurrences remain queued" 2 (List.length queued);
  check (list string) "queue preserves occurrence order" [ first_id; second_id ]
    (List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id) queued)
;;

let test_reused_schedule_id_does_not_match_pruned_terminal_receipt () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let first = create_named_keeper_wake_schedule config ~schedule_id:"reused-id" ~keeper_name in
  let first_tick = tick_ok config ~now:201.0 in
  let first_signal =
    match first_tick.emitted with
    | [ signal ] -> signal
    | signals -> failf "expected one first signal, got %d" (List.length signals)
  in
  let first_selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       keeper_name
       ~applied_at:202.0
       ~selection:first_selection
       ~detail:"first schedule occurrence completed"
   with
   | Ok (Keeper_registry_event_queue.Acked _)
   | Ok (Keeper_registry_event_queue.Already_acked _) -> ()
   | Ok
       (Keeper_registry_event_queue.Ack_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail -> fail detail);
  (match
     Keeper_event_queue_recovery.project_owner_result
       ~base_path
       ~keeper_name
   with
   | Ok Keeper_event_queue_recovery.No_pending_transition -> ()
   | Ok _ -> fail "owner terminalization left a transition for recovery"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  (match Schedule_store.prune_completed config with
   | Ok (_, 1) -> ()
   | Ok (_, count) -> failf "expected one pruned schedule, got %d" count
   | Error error -> fail (Schedule_store.store_error_to_string error));
  let second =
    create_named_keeper_wake_schedule config ~schedule_id:"reused-id" ~keeper_name
  in
  check bool "schedule recreation gets a new durable instance" false
    (String.equal first.schedule_instance_id second.schedule_instance_id);
  let second_tick = tick_ok config ~now:201.0 in
  let second_signal =
    match second_tick.emitted with
    | [ signal ] -> signal
    | signals -> failf "expected one second signal, got %d" (List.length signals)
  in
  check bool "recreated occurrence has a new identity" false
    (String.equal
       (Schedule_occurrence_id.to_string first_signal.occurrence_id)
       (Schedule_occurrence_id.to_string second_signal.occurrence_id));
  match
    find_wake
      (Schedule_store.read_state config)
      ~schedule_instance_id:second.schedule_instance_id
      ~schedule_id:second.schedule_id
      ~due_at:second.due_at
      ~payload_digest:(Schedule_domain.payload_digest second.payload)
  with
  | Some wake ->
    check string "recreated wake gets its own successful receipt"
      "succeeded"
      (Schedule_domain.wake_status_to_string wake.status)
  | None -> fail "recreated wake missing"
;;

let test_cancelled_schedule_enqueued_wake_is_removed_at_cancel_boundary () =
  (* task-370 live evidence: 17 cancelled schedules' enqueued wakes sat in
     awaiting_ack for up to 22.8 days, surviving four restarts and three
     builds. A cancelled schedule has no future occurrence that could consume
     its leftover wake, so the queue-evidence projection must classify the
     match as a retained terminal remainder, never as [matched_pending]. *)
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  (* Recurring, as in the live evidence (all 17 retained samples were
     hourly/daily/cron/interval): a one-shot that fired is already Succeeded
     and not cancellable, so it cannot produce this retained shape. *)
  let request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
      config
  in
  (* Fire the occurrence: the wake is enqueued to the keeper queue and its
     receipt lands in the schedule ledger (awaiting_ack, never consumed). *)
  let _ = tick_ok config ~now:201.0 in
  check int "wake is enqueued before cancellation" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  (match Server_schedule_consumers.cancel_keeper_schedules config ~keeper_name with
   | Ok () -> ()
   | Error error -> fail (Schedule_store.store_error_to_string error));
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | Some stored ->
     check string "schedule is cancelled" "cancelled"
       (Schedule_domain.schedule_status_to_string stored.status)
   | None -> fail "cancelled schedule missing");
  (* Cancel propagation (task-370 contract item 2): the cancel boundary must
     remove the cancelled schedule's already-enqueued utterance from the
     durable keeper queue. Retaining it produced the live evidence this test
     used to assert: 17 cancelled schedules' enqueued wakes sat in
     awaiting_ack for up to 22.8 days, surviving four restarts and three
     builds, re-visited every maintenance cycle. A cancelled schedule has no
     future occurrence that could consume its leftover wake. *)
  check int "cancel boundary removes the enqueued wake" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let row = dashboard_schedule_row_exn dashboard ~schedule_id:request.schedule_id in
  let open Yojson.Safe.Util in
  let queue_evidence = row |> member "keeper_queue_evidence" in
  (* Cancel propagation: the queue-evidence projection must now report the
     cancelled schedule with no pending remainder — the enqueued utterance
     left the durable queue at the cancel boundary. *)
  check string "cancelled schedule wake is withdrawn at cancel"
    "withdrawn_at_cancel"
    (queue_evidence |> member "projection_status" |> to_string);
  check string "retained classification names the schedule status" "cancelled"
    (queue_evidence |> member "schedule_status" |> to_string);
  (* No pending match means no match fields: the utterance is withdrawn, and
     [matched_bucket]/[matched_schedule_id] are absent rather than null. *)
  check int "retained wake no longer counts in pending" 0
    (queue_evidence |> member "pending_count" |> to_int);
  (* Disposition at the cancel boundary (task-1198): the in-flight wake row
     itself must be terminal, not left [Wake_running] forever. In this
     scenario the runner already settled the occurrence to [succeeded]
     before the cancel landed, so the row is terminal via the runner's own
     disposition; a still-running row would have been disposed by the
     cancel boundary with the same detail preserved. *)
  let state = Schedule_store.read_state config in
  let settled =
    List.find_opt
      (fun (w : Schedule_domain.wake_record) ->
         String.equal w.schedule_id request.schedule_id)
      state.Schedule_store.wakes
  in
  (match settled with
   | None -> fail "cancelled schedule's wake row missing from ledger"
   | Some w ->
     check bool "cancelled schedule's wake is terminal" true
       (match w.status with
        | Wake_running -> false
        | Wake_succeeded | Wake_failed -> true))
;;

let test_keeper_purge_cancels_future_schedule_intent () =  with_workspace
  @@ fun config ->
  let keeper_name = "purged-keeper" in
  let request =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"future-purge-schedule"
      ~keeper_name
  in
  (match Server_schedule_consumers.cancel_keeper_schedules config ~keeper_name with
   | Ok () -> ()
   | Error error -> fail (Schedule_store.store_error_to_string error));
  match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
  | Some stored ->
    check string "future wake is cancelled" "cancelled"
      (Schedule_domain.schedule_status_to_string stored.status)
  | None -> fail "cancelled future schedule missing"
;;

let test_owner_absent_pending_demand_is_drained_not_retained () =
  (* Owner-absent termination (task-370 contract item 1): durable pending
     work under a name the Keeper store does not know used to be retained and
     re-visited every maintenance cycle -- 881 retained visits for
     one keeper on 2026-08-25, surviving restarts. No cycle can
     make that wait productive: the work can never execute until the name is
     registered. The recovery loop must drain it through the exact
     accepted-cancellation transition instead of retaining it. *)
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  (* A queue directory for a name that was never registered in the Keeper
     store -- the exact orphan shape the recovery loop discovers. *)
  let orphan_name = "keeper-never-registered" in
  let wake : Keeper_event_queue.scheduled_wake =
    { occurrence_id = "orphan-occurrence"
    ; schedule_instance_id = "orphan-instance"
    ; schedule_id = "orphan-schedule"
    ; due_at = 200.0
    ; payload_digest = "orphan-digest"
    ; title = None
    ; message = "orphaned wake"
    ; result_delivery = None
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = "orphan-post"
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 200.0
    ; payload = Keeper_event_queue.Schedule_due wake
    }
  in
  (match
     Keeper_registry_event_queue.enqueue_stimulus_durable_result
       ~base_path
       orphan_name
       stimulus
   with
   | Keeper_registry_event_queue.Stimulus_enqueued -> ()
   | Keeper_registry_event_queue.Stimulus_already_present ->
     fail "orphan stimulus already present in a fresh workspace"
   | Keeper_registry_event_queue.Stimulus_storage_error detail ->
     fail ("orphan enqueue failed: " ^ detail));
  let pending_before =
    Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name:orphan_name
    |> function
    | Ok state -> Keeper_event_queue.length (Keeper_event_queue_state.pending state)
    | Error detail -> fail detail
  in
  check int "orphan queue holds one pending stimulus before drain" 1 pending_before;
  (match
     Keeper_registry_event_queue.drain_owner_absent_pending_result
       ~base_path
       orphan_name
       ~applied_at:201.0
       ~reason:"owner absent from keeper store; pending demand cannot execute"
   with
   | Ok 1 -> ()
   | Ok n -> failf "expected exactly one drained stimulus, got %d" n
   | Error detail -> fail ("owner-absent drain failed: " ^ detail));
  let pending_after =
    Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name:orphan_name
    |> function
    | Ok state -> Keeper_event_queue.length (Keeper_event_queue_state.pending state)
    | Error detail -> fail detail
  in
  check int "orphan queue is empty after drain" 0 pending_after;
  (* The drain must be idempotent: a second visit finds nothing to retain. *)
  (match
     Keeper_registry_event_queue.drain_owner_absent_pending_result
       ~base_path
       orphan_name
       ~applied_at:202.0
       ~reason:"owner absent from keeper store; pending demand cannot execute"
   with
   | Ok 0 -> ()
   | Ok n -> failf "second drain should find nothing, got %d" n
   | Error detail -> fail ("second owner-absent drain failed: " ^ detail))
;;

let test_shutdown_fence_rejects_schedule_intake_before_enqueue () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_shutdown_intake_fence.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_shutdown_intake_fence.Reserved _ -> ()
   | Keeper_shutdown_intake_fence.Already_reserved _ ->
     fail "fresh shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_shutdown_intake_fence.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
         : Keeper_shutdown_intake_fence.rollback_result))
    (fun () ->
       let request = create_keeper_wake_schedule config in
       let result = tick_ok config ~now:201.0 in
       (match result.dispatches with
        | [ { status = Schedule_runner.Dispatch_failed; error = Some detail; _ } ] ->
          check string
            "dispatch reports exact shutdown fence"
            (Printf.sprintf
               "retryable schedule dispatch failure: scheduled keeper wake rejected by shutdown fence keeper=%s operation=%s"
               keeper_name
               (Keeper_shutdown_types.Operation_id.to_string operation_id))
            detail
        | _ -> fail "shutdown-fenced dispatch did not remain retryable");
       check int "shutdown-fenced dispatch writes no queue entry" 0
         (Keeper_registry_event_queue.snapshot ~base_path keeper_name
          |> Keeper_event_queue.length);
       match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "shutdown-fenced schedule remains due" "due"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "shutdown-fenced schedule disappeared")
;;

let test_shutdown_fence_covers_direct_durable_queue_producers () =
  with_workspace
  @@ fun config ->
  let keeper_name = "direct-queue-producer-fenced" in
  let base_path = config.Workspace_utils.base_path in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id = "direct-queue-producer-fenced-stimulus"
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = 201.0
    ; payload = Keeper_event_queue.Bootstrap
    }
  in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_shutdown_intake_fence.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_shutdown_intake_fence.Reserved _ -> ()
   | Keeper_shutdown_intake_fence.Already_reserved _ ->
     fail "fresh direct-producer shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_shutdown_intake_fence.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
         : Keeper_shutdown_intake_fence.rollback_result))
    (fun () ->
       let expected_rejection =
         Printf.sprintf
           "keeper durable intake rejected by shutdown operation=%s"
           (Keeper_shutdown_types.Operation_id.to_string operation_id)
       in
       (match
          Keeper_registry_event_queue.enqueue_durable_result
            ~base_path
            keeper_name
            stimulus
        with
        | Error detail ->
          check string "direct durable enqueue reports shutdown fence"
            expected_rejection
            detail
        | Ok () -> fail "direct durable enqueue bypassed shutdown fence");
       (match
          Keeper_registry_event_queue.enqueue_stimulus_durable_result
            ~base_path
            keeper_name
            stimulus
        with
        | Keeper_registry_event_queue.Stimulus_storage_error detail ->
          check string "direct stimulus enqueue reports shutdown fence"
            expected_rejection
            detail
        | Keeper_registry_event_queue.Stimulus_enqueued
        | Keeper_registry_event_queue.Stimulus_already_present ->
          fail "direct stimulus enqueue bypassed shutdown fence");
       Keeper_registry_event_queue.enqueue ~base_path keeper_name stimulus;
       check int "direct enqueue writes no queue entry" 0
         (Keeper_registry_event_queue.snapshot ~base_path keeper_name
          |> Keeper_event_queue.length))
;;

let test_transferred_retry_uses_resolved_owner_shutdown_fence () =
  with_workspace
  @@ fun config ->
  let source_keeper = "schedule-transfer-source" in
  let target_keeper = "schedule-transfer-target" in
  let base_path = config.Workspace_utils.base_path in
  let source_ledger = reaction_ledger_dir ~base_path ~keeper_name:source_keeper in
  mkdir_p (Filename.dirname source_ledger);
  write_empty_file source_ledger;
  let request =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"resolved-owner-fence"
      ~keeper_name:source_keeper
  in
  let first = tick_ok config ~now:201.0 in
  check string "first dispatch remains retryable" "failed"
    (Schedule_runner.dispatch_status_to_string (List.hd first.dispatches).status);
  Sys.remove source_ledger;
  mkdir_p source_ledger;
  let selection = pending_selection_exn ~base_path ~keeper_name:source_keeper in
  let target_meta = persist_keeper_meta config target_keeper in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; operator_operation_id = "resolved-owner-fence-transfer"
    ; from_keeper = source_keeper
    ; to_keeper = target_keeper
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       source_keeper
       ~applied_at:201.5
       ~transfer
   with
   | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
     fail "first resolved-owner transfer was already applied"
   | Ok
       (Keeper_registry_event_queue.Transition_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail ->
     fail (Keeper_registry_event_queue.transfer_pending_error_to_string detail));
  (match
     Keeper_event_queue_recovery.project_owner_result
       ~base_path
       ~keeper_name:source_keeper
   with
   | Ok Keeper_event_queue_recovery.Transition_converged -> ()
   | Ok _ -> fail "resolved-owner transfer projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_shutdown_intake_fence.begin_shutdown
       ~base_path
       ~keeper_name:target_keeper
       ~operation_id
   with
   | Keeper_shutdown_intake_fence.Reserved _ -> ()
   | Keeper_shutdown_intake_fence.Already_reserved _ ->
     fail "fresh target shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_shutdown_intake_fence.rollback_shutdown
           ~base_path
           ~keeper_name:target_keeper
           ~operation_id
         : Keeper_shutdown_intake_fence.rollback_result))
    (fun () ->
       let retried = tick_ok config ~now:202.0 in
       (match retried.dispatches with
        | [ { status = Schedule_runner.Dispatch_failed
            ; error = Some detail
            ; _
            } ] ->
          check string
            "retry reports the resolved owner fence"
            (Printf.sprintf
               "retryable schedule dispatch failure: scheduled keeper wake rejected by shutdown fence keeper=%s operation=%s"
               target_keeper
               (Keeper_shutdown_types.Operation_id.to_string operation_id))
            detail
        | _ -> fail "transferred retry bypassed the resolved owner fence");
       check int "target occurrence remains durable" 1
         (Keeper_registry_event_queue.snapshot ~base_path target_keeper
          |> Keeper_event_queue.length);
       match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "resolved-owner fence leaves retry due" "due"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "resolved-owner schedule disappeared")
;;

let test_shutdown_join_waits_for_inflight_schedule_intake () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  let request = create_keeper_wake_schedule config in
  let signal =
    match Schedule_runner.tick config ~now:201.0 with
    | Ok { emitted = [ signal ]; _ } -> signal
    | Ok _ -> fail "expected one durable schedule signal"
    | Error error -> fail (Schedule_runner.runner_error_to_string error)
  in
  let running =
    match
      Schedule_store.start_due_candidate
        config
        ~now:201.5
        ~schedule_id:request.schedule_id
    with
    | Ok running -> running
    | Error error -> fail (Schedule_store.store_error_to_string error)
  in
  let intake_started, intake_started_u = Eio.Promise.create () in
  let release_intake, release_intake_u = Eio.Promise.create () in
  let join_completed, join_completed_u = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
       match
         Server_schedule_consumers.consumer.dispatch
           config
           ~now:202.0
           signal
           running
           ~commit_acceptance:(fun _detail ->
             Eio.Promise.resolve intake_started_u ();
             Eio.Promise.await release_intake;
             Error
               (Schedule_runner.Retryable_dispatch_failure
                  "test releases schedule acceptance"))
       with
       | Error (Schedule_runner.Retryable_dispatch_failure _) -> ()
       | Error (Schedule_runner.Terminal_dispatch_rejection detail) ->
         fail ("schedule intake became terminal: " ^ detail)
       | Ok _ -> fail "test acceptance unexpectedly committed")
    (fun () ->
       Eio.Promise.await intake_started;
       (match
          Keeper_shutdown_intake_fence.begin_shutdown
            ~base_path
            ~keeper_name
            ~operation_id
        with
        | Keeper_shutdown_intake_fence.Reserved _ -> ()
        | Keeper_shutdown_intake_fence.Already_reserved _ ->
          fail "fresh shutdown fence was already reserved");
       Fun.protect
         ~finally:(fun () ->
           ignore
             (Keeper_shutdown_intake_fence.rollback_shutdown
                ~base_path
                ~keeper_name
                ~operation_id
              : Keeper_shutdown_intake_fence.rollback_result))
         (fun () ->
            Eio.Fiber.both
              (fun () ->
                 Keeper_shutdown_intake_fence.await_idle_after_shutdown
                   ~base_path
                   ~keeper_name;
                 Eio.Promise.resolve join_completed_u ())
              (fun () ->
                 Eio.Fiber.yield ();
                 check bool "shutdown join waits for durable intake" true
                   (Option.is_none (Eio.Promise.peek join_completed));
                 Eio.Promise.resolve release_intake_u ();
                 Eio.Promise.await join_completed)))
;;

let test_keeper_wake_durable_state_failure_retries_same_occurrence () =
  with_workspace
  @@ fun config ->
  let keeper_owner_path =
    Filename.concat
      (Common.keepers_runtime_dir_of_base
         ~base_path:config.Workspace_utils.base_path)
      "schedule-keeper"
  in
  mkdir_p keeper_owner_path;
  let queue_path = Filename.concat keeper_owner_path "event-queue-v18.json" in
  mkdir_p queue_path;
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  let occurrence_id = single_occurrence_id result in
  (match List.hd result.dispatches with
   | { status = Schedule_runner.Dispatch_failed; error = Some message; _ } ->
     check bool "storage failure is explicit" true
       (String_util.contains_substring
          message
          "scheduled keeper wake durable state read failed")
   | _ -> fail "durable state read failure must not report dispatch success");
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule remains retryable" "due"
       (Schedule_domain.schedule_status_to_string stored.status));
  Unix.rmdir queue_path;
  check int "failed commit leaves no queued wake after storage repair" 0
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot
          ~base_path:config.Workspace_utils.base_path
          "schedule-keeper"));
  let retried = tick_ok config ~now:202.0 in
  check int "signal log is not duplicated" 0 (List.length retried.emitted);
  (match List.hd retried.dispatches with
   | { status = Schedule_runner.Dispatch_succeeded; _ } -> ()
   | _ -> fail "next sequential tick did not retry the durable enqueue");
  let queued =
    Keeper_registry_event_queue.snapshot
      ~base_path:config.Workspace_utils.base_path
      "schedule-keeper"
    |> Keeper_event_queue.to_list
  in
  check (list string) "retry preserves occurrence id" [ occurrence_id ]
    (List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id) queued)
;;

let test_cancelled_occurrence_recovery_does_not_enqueue_again () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let entry = register_keeper config keeper_name in
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path keeper_name)
    (fun () ->
      let request = create_keeper_wake_schedule config in
      let signal =
        match Schedule_runner.tick config ~now:201.0 with
        | Ok { emitted = [ signal ]; _ } -> signal
        | Ok _ -> fail "expected one durable schedule signal"
        | Error err -> fail (Schedule_runner.runner_error_to_string err)
      in
      let running =
        match
          Schedule_store.start_due_candidate
            config
            ~now:201.5
            ~schedule_id:request.schedule_id
        with
        | Ok running -> running
        | Error err -> fail (Schedule_store.store_error_to_string err)
      in
      Atomic.set entry.fiber_wakeup false;
      (match
         Server_schedule_consumers.consumer.dispatch
           config
           ~now:202.0
           signal
           running
           ~commit_acceptance:(fun _detail ->
             Error
               (Schedule_runner.Retryable_dispatch_failure
                  "simulate crash before schedule acceptance"))
       with
       | Ok _ -> ()
       | Error (Schedule_runner.Retryable_dispatch_failure _) -> ()
       | Error (Schedule_runner.Terminal_dispatch_rejection detail) ->
         fail ("initial schedule occurrence dispatch was terminal: " ^ detail));
      check bool "initial cancelled dispatch wakes lane" true
        (Atomic.get entry.fiber_wakeup);
      let pending_state =
        Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name
        |> function
        | Ok state -> state
        | Error detail -> fail detail
      in
      let selection =
        Keeper_event_queue_state.select_when
          ~now:(Unix.gettimeofday ())
          ~ready:(fun _ -> true)
          pending_state
        |> function
        | Some selection -> selection
        | None -> fail "schedule cancellation source was not selectable"
      in
      let cancellation : Keeper_event_queue_state.accepted_cancellation =
        { source = selection.source
        ; source_incarnation = selection.admitted_revision
        ; operator_operation_id = "cancel-schedule-occurrence"
        ; reason = "operator cancelled retained schedule work"
        }
      in
      (match
         Keeper_registry_event_queue.cancel_pending_accepted_result
           ~base_path
           keeper_name
          ~applied_at:203.0
          ~cancellation
       with
       | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
       | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
         fail "first schedule cancellation was already recorded"
       | Ok (Keeper_registry_event_queue.Transition_committed_followup_failed _) ->
         fail "schedule cancellation follow-up failed"
       | Error detail -> fail detail);
      let transition_wal_path =
        Filename.concat
          (Filename.concat
             (Common.keepers_runtime_dir_of_base ~base_path)
             keeper_name)
          "event-queue-transitions-v7.jsonl"
      in
      check bool "cancellation WAL survives until projection" true
        (Sys.file_exists transition_wal_path
         && String.trim (read_file transition_wal_path) <> "");
      (* #26074: projection is driven only by the janitor, so ordinary queue
         traffic races it. An enqueue between the transition and the projection
         bumps the snapshot revision; if the transition WAL is still on disk at
         that point, every later load replays a row whose [source_incarnation] no
         longer matches and the owner latches into "reset required" with no
         runtime exit - the projector itself cannot recover because it begins
         with [load_state_unlocked]. Drive that exact interleaving here. *)
      let interleaved_stimulus : Keeper_event_queue.stimulus =
        { cancellation.source with
          post_id = "interleaved-enqueue-during-transition"
        ; arrived_at = 203.5
        }
      in
      Keeper_registry_event_queue.enqueue ~base_path keeper_name interleaved_stimulus;
      (match Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name with
       | Ok _ -> ()
       | Error detail ->
         failf "enqueue after transition made the event queue unloadable: %s" detail);
      (* Withdraw the interleaved stimulus so the assertions below still measure
         what the cancelled retry produced rather than what this probe added. *)
      (match
         Keeper_registry_event_queue.drop_by_post_id
           ~base_path
           keeper_name
           ~post_id:interleaved_stimulus.post_id
       with
       | Ok _ -> ()
       | Error message -> fail ("interleaved stimulus drop failed: " ^ message));
      (match
         Keeper_event_queue_recovery.project_owner_result ~base_path ~keeper_name
       with
       | Ok
           ( Keeper_event_queue_recovery.No_pending_transition
           | Keeper_event_queue_recovery.Transition_converged ) ->
         ()
       | Ok Keeper_event_queue_recovery.Claim_busy ->
         fail "scheduled cancellation projection was deferred by a busy owner claim"
       | Error error ->
         fail (Keeper_event_queue_recovery.projection_error_to_string error));
      check string "projected cancellation retires WAL" ""
        (read_file transition_wal_path);
      (match Schedule_store.recover_running_on_startup config ~now:204.0 with
       | Ok (_, 1) -> ()
       | Ok (_, recovered) -> failf "expected one recovered schedule, got %d" recovered
       | Error err -> fail (Schedule_store.store_error_to_string err));
      Atomic.set entry.fiber_wakeup false;
      let retried = tick_ok config ~now:205.0 in
      (match List.hd retried.dispatches with
       | { status = Schedule_runner.Dispatch_succeeded
         ; detail = Some detail
         ; _
         } ->
         check string "retry observes terminal cancellation" "already_cancelled"
           Yojson.Safe.Util.(detail |> member "occurrence_status" |> to_string);
         check string "terminal cancellation needs no activation" "not_required"
           Yojson.Safe.Util.(detail |> member "activation_status" |> to_string)
       | _ -> fail "cancelled retry terminal receipt missing");
      check int "cancelled retry enqueues no second occurrence" 0
        (Keeper_registry_event_queue.snapshot ~base_path keeper_name
         |> Keeper_event_queue.length);
      (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "cancelled wake was already delivered" "succeeded"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "cancelled schedule missing");
      (match
         find_wake
           (Schedule_store.read_state config)
           ~schedule_instance_id:request.schedule_instance_id
           ~schedule_id:request.schedule_id
           ~due_at:request.due_at
           ~payload_digest:(Schedule_domain.payload_digest request.payload)
       with
       | Some wake ->
         check string "cancelled occurrence wake receipt succeeded" "succeeded"
           (Schedule_domain.wake_status_to_string wake.status)
       | None -> fail "cancelled occurrence wake missing");
      let stimulus_id =
        Schedule_occurrence_id.to_string signal.occurrence_id
      in
      match
        Keeper_reaction_ledger.event_queue_reaction_evidence_result
          ~base_path
          ~keeper_name
          ~stimulus_id
      with
      | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
        check bool "reaction ledger preserves terminal cancellation" true
          evidence.event_queue_cancelled_seen
      | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
        fail "cancelled occurrence evidence was quarantined"
      | Error error ->
        fail
          (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
             error))
;;

let test_terminal_retry_repairs_missing_stimulus_ledger () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let keeper_dir =
    Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers")
      keeper_name
  in
  mkdir_p keeper_dir;
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  mkdir_p (Filename.dirname ledger_dir);
  write_empty_file ledger_dir;
  ignore (create_keeper_wake_schedule config : Schedule_domain.schedule_request);
  let first = tick_ok config ~now:201.0 in
  let stimulus_id = single_occurrence_id first in
  check string "first dispatch is retryable failure" "failed"
    (Schedule_runner.dispatch_status_to_string (List.hd first.dispatches).status);
  rm_rf ledger_dir;
  mkdir_p ledger_dir;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  let original_stimulus = selection.source in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       keeper_name
       ~applied_at:201.5
       ~selection
       ~detail:"terminal before schedule retry"
   with
   | Ok (Keeper_registry_event_queue.Acked _)
   | Ok (Keeper_registry_event_queue.Already_acked _) -> ()
   | Ok
       (Keeper_registry_event_queue.Ack_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail -> fail detail);
  let later_stimulus =
    match original_stimulus.payload with
    | Keeper_event_queue.Schedule_due wake ->
      { original_stimulus with
        post_id = "later-projected-schedule-occurrence"
      ; arrived_at = 201.75
      ; payload =
          Keeper_event_queue.Schedule_due
            { wake with occurrence_id = "later-projected-schedule-occurrence" }
      }
    | _ -> fail "expected the original schedule stimulus"
  in
  Keeper_registry_event_queue.enqueue ~base_path keeper_name later_stimulus;
  let later_selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       keeper_name
       ~applied_at:201.8
       ~selection:later_selection
       ~detail:"later terminal displaces schedule retry into compact history"
   with
   | Ok (Keeper_registry_event_queue.Acked _)
   | Ok (Keeper_registry_event_queue.Already_acked _) -> ()
   | Ok
       (Keeper_registry_event_queue.Ack_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail -> fail detail);
  let compact_state =
    match Keeper_registry_event_queue.durable_state_result ~base_path keeper_name with
    | Ok state -> state
    | Error detail -> fail detail
  in
  (match
     Keeper_event_queue_state.projected_dispositions compact_state
     |> List.find_opt (function
       | Keeper_event_queue_state.Projected_witness witness ->
         String.equal witness.post_id stimulus_id
       | Keeper_event_queue_state.Current_receipt _ -> false)
   with
   | Some (Keeper_event_queue_state.Projected_witness _) -> ()
   | Some (Keeper_event_queue_state.Current_receipt _) | None ->
     fail "older schedule terminal did not become a compact witness");
  let conflicting_stimulus =
    match original_stimulus.payload with
    | Keeper_event_queue.Schedule_due wake ->
      { original_stimulus with
        arrived_at = 201.9
      ; payload =
          Keeper_event_queue.Schedule_due
            { wake with message = "changed message for the same occurrence" }
      }
    | _ -> fail "expected the original schedule stimulus"
  in
  (match
     Server_schedule_consumers.accept_keeper_wake_occurrence
       ~base_path
       ~keeper_name
       ~expected_owner:keeper_name
       ~stimulus_id
       conflicting_stimulus
   with
   | Error (Schedule_runner.Retryable_dispatch_failure detail) ->
     check bool "changed compact source is rejected explicitly" true
       (String_util.contains_substring detail "compact source conflicts")
   | Error (Schedule_runner.Terminal_dispatch_rejection detail) ->
     fail ("changed compact source became terminal: " ^ detail)
   | Ok _ -> fail "changed compact source reused the durable occurrence");
  let retried = tick_ok config ~now:202.0 in
  (match List.hd retried.dispatches with
   | { status = Schedule_runner.Dispatch_succeeded
     ; detail = Some detail
     ; _
     } ->
     check string "retry observes terminal failure" "already_failed"
       Yojson.Safe.Util.(detail |> member "occurrence_status" |> to_string);
     check string "terminal retry needs no activation" "not_required"
       Yojson.Safe.Util.(detail |> member "activation_status" |> to_string)
   | _ -> fail "terminal retry did not preserve the failed disposition");
  check int "terminal retry enqueues no second occurrence" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  let durable_state =
    match Keeper_registry_event_queue.durable_state_result ~base_path keeper_name with
    | Ok state -> state
    | Error detail -> fail detail
  in
  check int "terminal retry retires the reaction outbox" 0
    (Keeper_event_queue_state.transition_outbox durable_state |> List.length);
  let repaired_arrived_at =
    jsonl_rows_under ledger_dir
    |> List.find_map (fun row ->
      let open Yojson.Safe.Util in
      if String.equal (row |> member "record_kind" |> to_string_option |> Option.value ~default:"") "stimulus"
         && String.equal
              (row |> member "stimulus_id" |> to_string_option |> Option.value ~default:"")
              stimulus_id
      then row |> member "stimulus" |> member "arrived_at_unix" |> to_float_option
      else None)
  in
  check (option (float 0.001)) "ledger repair preserves durable source arrival"
    (Some original_stimulus.arrived_at)
    repaired_arrived_at;
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id
  with
  | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
    check bool "terminal retry repairs missing stimulus" true evidence.stimulus_seen;
    check bool "terminal reaction remains recorded" true evidence.event_queue_ack_seen;
    check int "one stimulus and one terminal reaction remain" 2
      evidence.matched_record_count
  | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
    fail "terminal retry evidence was quarantined"
  | Error error ->
    fail
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
;;

let test_terminal_retry_requires_acceptance_commit () =
  with_workspace
  @@ fun config ->
  let keeper_name = "terminal-acceptance-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let ledger_path = reaction_ledger_dir ~base_path ~keeper_name in
  mkdir_p (Filename.dirname ledger_path);
  write_empty_file ledger_path;
  let request =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"terminal-acceptance-commit"
      ~keeper_name
  in
  let first = tick_ok config ~now:201.0 in
  let signal =
    match first.emitted with
    | [ signal ] -> signal
    | signals -> failf "expected one terminal retry signal, got %d" (List.length signals)
  in
  Sys.remove ledger_path;
  mkdir_p ledger_path;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       keeper_name
       ~applied_at:201.5
       ~selection
       ~detail:"terminal acceptance evidence"
   with
   | Ok (Keeper_registry_event_queue.Acked _)
   | Ok (Keeper_registry_event_queue.Already_acked _) -> ()
   | Ok
       (Keeper_registry_event_queue.Ack_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail -> fail detail);
  let running =
    match
      Schedule_store.start_due_candidate
        config
        ~now:202.0
        ~schedule_id:request.schedule_id
    with
    | Ok running -> running
    | Error error -> fail (Schedule_store.store_error_to_string error)
  in
  let commit_calls = Atomic.make 0 in
  (match
     Server_schedule_consumers.consumer.dispatch
       config
       ~now:202.0
       signal
       running
       ~commit_acceptance:(fun _detail ->
         Atomic.incr commit_calls;
         Error
           (Schedule_runner.Retryable_dispatch_failure
              "terminal acceptance commit probe"))
   with
   | Error (Schedule_runner.Retryable_dispatch_failure detail) ->
     check string "terminal result waits for acceptance commit"
       "terminal acceptance commit probe"
       detail
   | Error (Schedule_runner.Terminal_dispatch_rejection detail) ->
     fail ("terminal retry became a payload rejection: " ^ detail)
   | Ok _ -> fail "terminal retry returned before acceptance commit");
  check int "terminal retry invokes one acceptance commit" 1
    (Atomic.get commit_calls)
;;

let test_retry_before_terminal_reconciliation_retains_wake () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  mkdir_p ledger_dir;
  Unix.chmod ledger_dir 0o500;
  ignore (create_keeper_wake_schedule config);
  let first = tick_ok config ~now:201.0 in
  Unix.chmod ledger_dir 0o755;
  check string "first dispatch is retryable failure" "failed"
    (Schedule_runner.dispatch_status_to_string (List.hd first.dispatches).status);
  rm_rf ledger_dir;
  let retried = tick_ok config ~now:202.0 in
  check string "retry dispatch succeeds" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd retried.dispatches).status);
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "schedule selection was reconciled as a spent grant replay"
   | Error detail -> fail detail);
  check int "retry wake remains pending" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let test_deferred_keeper_wake_not_running_is_retryable () =
  with_workspace
  @@ fun config ->
  let keeper_name = "offline-schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  register_offline_keeper ~proactive_enabled:true config keeper_name;
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister ~base_path keeper_name)
    (fun () ->
       let request =
         create_named_keeper_wake_schedule
           config
           ~schedule_id:"deferred-wake-not-running"
           ~keeper_name
       in
       let result = tick_ok config ~now:201.0 in
       check int "one dispatch attempted" 1 (List.length result.dispatches);
       let dispatch = List.hd result.dispatches in
       check string "dispatch returns retryable failure" "failed"
         (Schedule_runner.dispatch_status_to_string dispatch.status);
       (match dispatch.error with
        | Some detail ->
          check bool "retryable failure explicitly mentions owner not running" true
            (String_util.contains_substring detail "deferred owner-not-running")
        | None -> fail "dispatch error detail missing");
       (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
        | None -> fail "schedule missing"
        | Some stored ->
          check string "schedule remains due for retry" "due"
            (Schedule_domain.schedule_status_to_string stored.status));
       check int "stimulus is enqueued and remains pending" 1
         (Keeper_event_queue.length
            (Keeper_registry_event_queue.snapshot ~base_path keeper_name));
       let retried = tick_ok config ~now:202.0 in
       check int "one retry dispatch attempted" 1 (List.length retried.dispatches);
       check int "queue does not accumulate duplicate entries on retry" 1
         (Keeper_event_queue.length
            (Keeper_registry_event_queue.snapshot ~base_path keeper_name)))
;;

let test_due_schedule_wakes_live_keeper_with_proactive_disabled () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let entry =
    register_keeper ~proactive_enabled:false config keeper_name
  in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister ~base_path keeper_name)
    (fun () ->
       let request = create_keeper_wake_schedule config in
       Atomic.set entry.fiber_wakeup false;
       let result = tick_ok config ~now:201.0 in
       check bool "due schedule signals the live owner" true
         (Atomic.get entry.fiber_wakeup);
       match
         Schedule_store.last_wake_for_schedule_instance
           (Schedule_store.read_state config)
           ~schedule_instance_id:request.schedule_instance_id
           ~schedule_id:request.schedule_id
       with
       | Some { detail = Some detail; _ } ->
         check string "activation is signaled" "signaled"
           Yojson.Safe.Util.(detail |> member "activation_status" |> to_string);
         check string "proactive policy is not an activation blocker" ""
           (match
              Yojson.Safe.Util.(detail |> member "activation_reason")
            with
            | `Null -> ""
            | json -> Yojson.Safe.to_string json);
         check int "one schedule dispatch completed" 1
           (List.length result.dispatches)
       | Some _ -> fail "schedule wake detail missing"
       | None -> fail "schedule wake missing")
;;

let test_keeper_wake_queue_evidence_rejects_stale_occurrence () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  let occurrence_id = tick_ok config ~now:201.0 |> single_occurrence_id in
  (match
     Keeper_registry_event_queue.drop_by_post_id
       ~base_path
       keeper_name
       ~post_id:occurrence_id
   with
   | Error message -> fail ("drop failed: " ^ message)
   | Ok removed -> check int "removed current occurrence" 1 (List.length removed));
  let stale_payload_json =
    `Assoc
      [ "kind", `String "masc.keeper_wake"
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String keeper_name
            ; "title", `String "Scheduled lane wake"
            ; "message", `String "Run a different scheduled occurrence."
            ; "urgency", `String "immediate"
            ] )
      ]
  in
  let stale_payload =
    match Schedule_domain.payload_of_yojson stale_payload_json with
    | Ok payload -> payload
    | Error message -> fail ("stale payload parse failed: " ^ message)
  in
  let stale_wake : Keeper_event_queue.scheduled_wake =
    { occurrence_id = "stale-schedule-occurrence"
    ; schedule_instance_id = request.schedule_instance_id
    ; schedule_id = request.schedule_id
    ; due_at = request.due_at +. 60.0
    ; payload_digest = Schedule_domain.payload_digest stale_payload
    ; title = Some "Scheduled lane wake"
    ; message = "Run a different scheduled occurrence."
    ; result_delivery = None
    }
  in
  let stale_stimulus : Keeper_event_queue.stimulus =
    { post_id = "stale-schedule-occurrence"
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = request.due_at +. 61.0
    ; payload = Keeper_event_queue.Schedule_due stale_wake
    }
  in
  Keeper_registry_event_queue.enqueue ~base_path keeper_name stale_stimulus;
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row =
    dashboard
    |> member "requests"
    |> to_list
    |> List.find_opt (fun row ->
      String.equal
        (row |> member "schedule_id" |> to_string)
        request.schedule_id)
  in
  match row with
  | None -> fail "keeper wake schedule missing from dashboard projection"
  | Some row ->
    let queue_evidence = row |> member "keeper_queue_evidence" in
    check string "stale occurrence does not match" "not_found"
      (queue_evidence |> member "projection_status" |> to_string);
    check (float 0.001) "queue evidence wake due_at" request.due_at
      (queue_evidence |> member "wake_due_at" |> to_float);
    check string "queue evidence wake digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "wake_payload_digest" |> to_string);
    check int "stale occurrence still visible as pending" 1
      (queue_evidence |> member "pending_count" |> to_int)
;;

let test_dashboard_live_supported_non_terminal_evidence_matches_supported_request () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let evidence = dashboard |> member "live_supported_non_terminal_evidence" in
  check string "live supported evidence matched" "matched_supported_non_terminal"
    (evidence |> member "projection_status" |> to_string);
  check string "live supported evidence source" "schedule_store"
    (evidence |> member "source" |> to_string);
  check int "one supported request" 1
    (evidence |> member "supported_request_count" |> to_int);
  check int "one supported non-terminal request" 1
    (evidence |> member "supported_non_terminal_count" |> to_int);
  check int "one supported live request" 1
    (evidence |> member "supported_live_count" |> to_int);
  check int "no unsupported requests" 0
    (evidence |> member "unsupported_request_count" |> to_int);
  check (list string) "matched schedule ids" [ request.schedule_id ]
    (evidence |> member "matched_schedule_ids" |> to_list |> List.map to_string)
;;

let test_dashboard_live_supported_non_terminal_evidence_reports_absent_supported_payloads
      ()
  =
  with_workspace
  @@ fun config ->
  ignore (create_unsupported_schedule config : Schedule_domain.schedule_request);
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let evidence = dashboard |> member "live_supported_non_terminal_evidence" in
  check string "live supported evidence absent" "no_supported_payload_rows"
    (evidence |> member "projection_status" |> to_string);
  check int "no supported requests" 0
    (evidence |> member "supported_request_count" |> to_int);
  check int "no supported live requests" 0
    (evidence |> member "supported_live_count" |> to_int);
  check int "one unsupported request" 1
    (evidence |> member "unsupported_request_count" |> to_int);
  check int "no matched schedule ids" 0
    (evidence |> member "matched_schedule_ids" |> to_list |> List.length)
;;

 let test_keeper_wake_ledger_failure_is_retryable () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let keeper_dir =
    Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers")
      keeper_name
  in
  mkdir_p keeper_dir;
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  mkdir_p (Filename.dirname ledger_dir);
  write_empty_file ledger_dir;
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  let occurrence_id = single_occurrence_id result in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch reports retryable failure" "failed"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule remains due" "due"
       (Schedule_domain.schedule_status_to_string stored.status));
  (match (List.hd result.dispatches).error with
   | Some detail ->
     check bool "ledger failure is explicit" true
       (String_util.contains_substring detail "keeper reaction ledger")
   | None -> fail "ledger failure detail missing");
  Sys.remove ledger_dir;
  mkdir_p ledger_dir;
  let retried = tick_ok config ~now:202.0 in
  check string "retry repairs ledger then succeeds" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd retried.dispatches).status);
  check int "retry reuses the pending queue entry" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  match
    Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path
      ~keeper_name
      ~stimulus_id:occurrence_id
  with
  | Ok (Keeper_reaction_ledger.Evidence_complete evidence) ->
    check int "repair writes one canonical stimulus row" 1 evidence.matched_record_count
  | Ok (Keeper_reaction_ledger.Evidence_quarantined _) ->
    fail "repaired occurrence evidence was quarantined"
  | Error error ->
    fail
      (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
         error)
;;

let test_unattributed_ledger_damage_does_not_block_occurrences () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let damaged_keeper = "damaged-ledger-keeper" in
  let healthy_keeper = "healthy-ledger-keeper" in
  write_malformed_reaction_ledger_row
    ~base_path
    ~keeper_name:damaged_keeper;
  let damaged =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"damaged-ledger-schedule"
      ~keeper_name:damaged_keeper
  in
  let healthy =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"healthy-ledger-schedule"
      ~keeper_name:healthy_keeper
  in
  let result = tick_ok config ~now:201.0 in
  check int "both due occurrences are dispatched" 2 (List.length result.dispatches);
  let dispatch schedule_id =
    List.find
      (fun (item : Schedule_runner.dispatch_result) ->
        String.equal item.schedule_id schedule_id)
      result.dispatches
  in
  let damaged_dispatch = dispatch damaged.schedule_id in
  let healthy_dispatch = dispatch healthy.schedule_id in
  check string
    "unattributed damage cannot block a new occurrence"
    "succeeded"
    (Schedule_runner.dispatch_status_to_string damaged_dispatch.status);
  check string
    "other keeper lane continues"
    "succeeded"
    (Schedule_runner.dispatch_status_to_string healthy_dispatch.status);
  check int
    "damaged keeper still receives its identified occurrence"
    1
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot ~base_path damaged_keeper));
  check int
    "healthy keeper received its own occurrence"
    1
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot ~base_path healthy_keeper))
;;

let test_dashboard_keeps_unattributed_damage_out_of_exact_evidence () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  check string
    "initial dispatch succeeds"
    "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  write_malformed_reaction_ledger_row
    ~base_path:config.Workspace_utils.base_path
    ~keeper_name:"schedule-keeper";
  let evidence =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
    |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
    |> Yojson.Safe.Util.member "keeper_reaction_evidence"
  in
  let open Yojson.Safe.Util in
  check string
    "dashboard preserves exact occurrence evidence"
    "matched_stimulus"
    (evidence |> member "projection_status" |> to_string);
  check int
    "only the identified occurrence row is matched"
    1
    (evidence |> member "matched_record_count" |> to_int)
;;

let test_dashboard_projects_quarantined_and_unreadable_reaction_evidence () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  let stimulus_id = single_occurrence_id result in
  Dated_jsonl.append
    (Dated_jsonl.create
       ~base_dir:(reaction_ledger_dir ~base_path ~keeper_name)
       ())
    (`Assoc
        [ "schema", `String Masc.Keeper_reaction_ledger.schema
        ; "record_kind", `String "reaction"
        ; "event_id", `String (stimulus_id ^ ":reaction:turn_started")
        ; "keeper_name", `String keeper_name
        ; "recorded_at_unix", `Float 202.0
        ; "stimulus_id", `String stimulus_id
        ; ( "reaction"
          , `Assoc
              [ "kind", `String "unknown_custom"
              ; "source", `String "keeper_event_queue"
              ] )
        ]);
  let evidence () =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
    |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
    |> Yojson.Safe.Util.member "keeper_reaction_evidence"
  in
  let open Yojson.Safe.Util in
  let quarantined = evidence () in
  check string
    "matching semantic-invalid row is quarantined"
    "quarantined"
    (quarantined |> member "projection_status" |> to_string);
  check int
    "dashboard matching quarantine count"
    1
    (quarantined |> member "quarantined_record_count" |> to_int);
  check string
    "dashboard typed quarantine reason"
    "unknown_reaction_kind"
    (quarantined |> member "reason" |> to_string);
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  rm_rf ledger_dir;
  write_empty_file ledger_dir;
  let unreadable = evidence () in
  check string
    "storage failure is not projected as empty evidence"
    "read_error"
    (unreadable |> member "projection_status" |> to_string);
  check bool
    "storage failure reason is explicit"
    true
    (unreadable |> member "reason" |> to_string |> String.length > 0)
;;

let test_keeper_wake_consumer_rejects_invalid_keeper_name () =
  with_workspace
  @@ fun config ->
  let request = create_invalid_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch status" "unsupported"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule failed" "failed"
       (Schedule_domain.schedule_status_to_string stored.status));
  (match
     Schedule_store.last_wake_for_schedule_instance
       (Schedule_store.read_state config)
       ~schedule_instance_id:request.schedule_instance_id
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing unsupported wake"
   | Some wake ->
     check string "wake failed" "failed"
       (Schedule_domain.wake_status_to_string wake.status);
     check (option string) "wake error"
       (Some
          (Schedule_supported_kinds.keeper_wake_target_name_error
             ~field:"masc.keeper_wake payload body.keeper_name"))
       wake.error);
  let queue_discovery =
    Keeper_event_queue_persistence.discover_keeper_names_with_durable_state
      ~base_path:config.Workspace_utils.base_path
  in
  check bool "invalid keeper wake creates no durable queue owner" false
    (List.mem "../bad" queue_discovery.keeper_names)
;;

(* A resolved approval wakes its Keeper so it re-evaluates immediately. Host
   replay consumes the one-shot grant before executing the effect, but that
   transition is terminal only after the replay outcome is durable. *)
let approved_grant_fixture ~base_path ~keeper_name ~input =
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
  let approval_id =
    match
      Keeper_approval_queue.submit_pending
        ~keeper_name
        ~tool_name:"external-effect"
        ~call_summary:None
        ~input
        ~base_path
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Keeper_approval_queue.resolve_with_policy
       ~base_path
       ~id:approval_id
       ~decision:Keeper_approval_queue_rules_types.Decision.Approve
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.resolve_error_to_string error));
  approval_id
;;

(* Resolving an approval for a Keeper that holds no live lane persists the
   [Hitl_resolved] wake for replay, which is the exact queue state this
   reconciliation reads. Assert it rather than enqueueing a second copy. *)
let check_single_queued_replay ~base_path ~keeper_name =
  check int "resolution queued exactly one replay" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let replay_result_ref () =
  match
    Tool_output.make_artifact_ref
      ~sha256:(String.make 64 'a')
      ~bytes:2
      ~preview:"ok"
      ~mime:"text/plain"
  with
  | Ok reference -> reference
  | Error detail -> fail (Tool_output.make_error_to_string detail)
;;

let approval_lifecycle_phases ~base_path ~keeper_name =
  Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name
  |> List.filter_map (fun (message : Keeper_chat_store.chat_message) ->
    Option.map
      (fun lifecycle -> lifecycle.Keeper_chat_store.phase)
      message.approval_lifecycle)
;;

let test_consumed_grant_without_outcome_stays_actionable () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "spent-grant-keeper" in
  ignore (persist_keeper_meta config keeper_name : Keeper_meta_contract.keeper_meta);
  let input = `Assoc [ "target", `String "spent-grant" ] in
  let approval_id = approved_grant_fixture ~base_path ~keeper_name ~input in
  (match
     Keeper_approval_queue.consume_approved_resolution
       ~base_path
       ~id:approval_id
       ~keeper_name
       ~tool_name:"external-effect"
       ~input
   with
   | Ok (Keeper_approval_queue.Consumption_committed _) -> ()
   | Ok Keeper_approval_queue.Consumption_already_committed ->
     fail "grant was already consumed before the test consumed it"
   | Ok Keeper_approval_queue.Consumption_not_matching ->
     fail "exact grant did not match its own request"
   | Error error -> fail (Keeper_approval_queue.grant_error_to_string error));
  check_single_queued_replay ~base_path ~keeper_name;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     match selection.Keeper_event_queue_state.source.payload with
     | Keeper_event_queue.Hitl_resolved resolution ->
       Keeper_approval_queue.ensure_settled_continuation_chat_projection
         ~base_path
         ~keeper_name
         ~resolution
     | _ -> fail "fixture selection was not an approval resolution"
   with
   | Ok Keeper_approval_queue.Continuation_projection_not_ready -> ()
   | Ok Keeper_approval_queue.Continuation_projection_recorded ->
     fail "continuation was recorded before replay outcome durability"
   | Error detail -> fail detail);
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "consumed replay was discarded before its outcome became durable"
   | Error detail -> fail detail);
  check int "repairable replay stays queued" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let test_consumed_grant_with_outcome_retires_without_a_turn () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "spent-grant-keeper" in
  ignore (persist_keeper_meta config keeper_name : Keeper_meta_contract.keeper_meta);
  let input = `Assoc [ "target", `String "spent-grant" ] in
  let approval_id = approved_grant_fixture ~base_path ~keeper_name ~input in
  (match
     Keeper_approval_queue.consume_approved_resolution
       ~base_path
       ~id:approval_id
       ~keeper_name
       ~tool_name:"external-effect"
       ~input
   with
   | Ok (Keeper_approval_queue.Consumption_committed _) -> ()
   | Ok Keeper_approval_queue.Consumption_already_committed ->
     fail "grant was already consumed before the test consumed it"
   | Ok Keeper_approval_queue.Consumption_not_matching ->
     fail "exact grant did not match its own request"
   | Error error -> fail (Keeper_approval_queue.grant_error_to_string error));
  (match
     Keeper_approval_queue.record_consumed_resolution_replay
       ~base_path
       ~id:approval_id
       ~outcome:(Keeper_approval_queue.Replay_applied (replay_result_ref ()))
   with
   | Ok Keeper_approval_queue.Replay_recorded -> ()
   | Ok Keeper_approval_queue.Replay_already_recorded ->
     fail "replay outcome was already recorded before the test"
   | Error error -> fail (Keeper_approval_queue.grant_error_to_string error));
  Keeper_approval_queue.For_testing.reset_runtime_state ();
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
  check_single_queued_replay ~base_path ~keeper_name;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "replay drained before the continuation turn was recorded"
   | Error detail -> fail detail);
  check int "replay waits for continuation receipt" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  (match
     match selection.Keeper_event_queue_state.source.payload with
     | Keeper_event_queue.Hitl_resolved resolution ->
       Keeper_approval_queue.ensure_settled_continuation_chat_projection
         ~base_path
         ~keeper_name
         ~resolution
     | _ -> fail "fixture selection was not an approval resolution"
   with
   | Ok Keeper_approval_queue.Continuation_projection_recorded -> ()
   | Ok Keeper_approval_queue.Continuation_projection_not_ready ->
     fail "durable replay was not ready for continuation projection"
   | Error detail -> fail detail);
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable ->
     fail "durable replay outcome was left at the queue head"
   | Error detail -> fail detail);
  check int "spent grant replay left the queue" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  check int "drain committed resolution, replay, and continuation receipts" 3
    (approval_lifecycle_phases ~base_path ~keeper_name |> List.length)
;;

let test_projection_failure_keeps_spent_replay_queued () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "spent-grant-projection-failure" in
  ignore (persist_keeper_meta config keeper_name : Keeper_meta_contract.keeper_meta);
  let input = `Assoc [ "target", `String "projection-failure" ] in
  let approval_id = approved_grant_fixture ~base_path ~keeper_name ~input in
  (match
     Keeper_approval_queue.consume_approved_resolution
       ~base_path
       ~id:approval_id
       ~keeper_name
       ~tool_name:"external-effect"
       ~input
   with
   | Ok (Keeper_approval_queue.Consumption_committed _) -> ()
   | Ok _ | Error _ -> fail "fixture grant was not consumed");
  (match
     Keeper_approval_queue.record_consumed_resolution_replay
       ~base_path
       ~id:approval_id
       ~outcome:(Keeper_approval_queue.Replay_applied (replay_result_ref ()))
   with
   | Ok Keeper_approval_queue.Replay_recorded -> ()
   | Ok _ | Error _ -> fail "fixture replay outcome was not recorded");
  let chat_path = Keeper_chat_store.chat_path ~base_dir:base_path ~keeper_name in
  let channel = open_out_gen [ Open_append; Open_text ] 0o600 chat_path in
  output_string channel
    ({|{"id":"malformed-projection","role":"system","content":"bad","ts":9999999999.0,"delivery_key":{"kind":"approval_lifecycle","approval_id":"appr_bad"}}|}
     ^ "\n");
  close_out channel;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Error _ -> ()
   | Ok _ -> fail "spent replay drained without a readable chat projection receipt");
  check int "projection failure keeps replay queued" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let test_rejected_resolution_projection_precedes_turn_intake () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "rejected-grant-projection" in
  ignore (persist_keeper_meta config keeper_name : Keeper_meta_contract.keeper_meta);
  (match Keeper_approval_queue.install_persistence ~base_path with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.install_error_to_string error));
  let approval_id =
    match
      Keeper_approval_queue.submit_pending
        ~keeper_name
        ~tool_name:"external-effect"
        ~call_summary:None
        ~input:(`Assoc [ "target", `String "reject" ])
        ~base_path
        ()
    with
    | Ok submission -> submission.approval_id
    | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Keeper_approval_queue.resolve_with_policy
       ~base_path
       ~id:approval_id
       ~decision:(Keeper_approval_queue_rules_types.Decision.Reject "operator denied")
       ()
   with
   | Ok _ -> ()
   | Error error -> fail (Keeper_approval_queue.resolve_error_to_string error));
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "rejection was drained before its Keeper turn consumed it"
   | Error detail -> fail detail);
  check int "rejection owns one visible resolution receipt" 1
    (approval_lifecycle_phases ~base_path ~keeper_name |> List.length);
  (match
     match selection.Keeper_event_queue_state.source.payload with
     | Keeper_event_queue.Hitl_resolved resolution ->
       Keeper_approval_queue.ensure_settled_continuation_chat_projection
         ~base_path
         ~keeper_name
         ~resolution
     | _ -> fail "fixture selection was not an approval resolution"
   with
   | Ok Keeper_approval_queue.Continuation_projection_recorded -> ()
   | Ok Keeper_approval_queue.Continuation_projection_not_ready ->
     fail "rejection incorrectly waited for a replay outcome"
   | Error detail -> fail detail);
  check int "completed rejection turn owns a continuation receipt" 2
    (approval_lifecycle_phases ~base_path ~keeper_name |> List.length);
  check int "rejection stays queued for the continuation turn" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable ->
     fail "recorded rejection continuation was delivered to a second turn"
   | Error detail -> fail detail);
  check int "recorded rejection continuation drains after restart" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let test_unconsumed_grant_replay_stays_actionable () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "live-grant-keeper" in
  ignore (persist_keeper_meta config keeper_name : Keeper_meta_contract.keeper_meta);
  let input = `Assoc [ "target", `String "live-grant" ] in
  ignore (approved_grant_fixture ~base_path ~keeper_name ~input : string);
  check_single_queued_replay ~base_path ~keeper_name;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "an unconsumed grant was discarded before its Keeper could use it"
   | Error detail -> fail detail);
  check int "unconsumed grant replay stays queued" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let () =
  run "Schedule_consumer_dispatch"
    [ ( "keeper_wake"
      , [ test_case "board post schedule is rejected without mutation" `Quick
            test_board_post_schedule_is_rejected_without_mutation
        ; test_case "keeper wake names an absent owner" `Quick
            test_keeper_wake_consumer_names_an_absent_owner
        ; test_case "keeper wake records wake receipt" `Quick
            test_keeper_wake_consumer_records_wake_receipt
        ; test_case "routed schedule carries occurrence destination to Keeper" `Quick
            test_routed_schedule_carries_occurrence_destination_to_keeper
        ; test_case "recurring wakes keep distinct occurrence ids" `Quick
            test_recurring_wakes_keep_distinct_occurrence_ids
        ; test_case "reused schedule id does not match pruned terminal receipt"
            `Quick
            test_reused_schedule_id_does_not_match_pruned_terminal_receipt
        ; test_case "keeper purge cancels future schedule intent" `Quick
            test_keeper_purge_cancels_future_schedule_intent
        ; test_case "cancelled schedule enqueued wake leaves queue at cancel boundary"
            `Quick
            test_cancelled_schedule_enqueued_wake_is_removed_at_cancel_boundary
        ; test_case "owner absent pending demand is drained not retained" `Quick
            test_owner_absent_pending_demand_is_drained_not_retained
        ; test_case "shutdown fence rejects schedule intake before enqueue" `Quick
            test_shutdown_fence_rejects_schedule_intake_before_enqueue
        ; test_case "shutdown fence covers direct durable queue producers" `Quick
            test_shutdown_fence_covers_direct_durable_queue_producers
        ; test_case "transferred retry uses resolved owner shutdown fence" `Quick
            test_transferred_retry_uses_resolved_owner_shutdown_fence
        ; test_case "shutdown join waits for in-flight schedule intake" `Quick
            test_shutdown_join_waits_for_inflight_schedule_intake
        ; test_case "keeper wake durable state failure retries same occurrence" `Quick
            test_keeper_wake_durable_state_failure_retries_same_occurrence
        ; test_case "cancelled occurrence recovery does not enqueue again"
            `Quick
            test_cancelled_occurrence_recovery_does_not_enqueue_again
        ; test_case "terminal retry repairs missing stimulus ledger"
            `Quick
            test_terminal_retry_repairs_missing_stimulus_ledger
        ; test_case "terminal retry requires acceptance commit" `Quick
            test_terminal_retry_requires_acceptance_commit
        ; test_case "retry before terminal reconciliation retains wake"
            `Quick
            test_retry_before_terminal_reconciliation_retains_wake
        ; test_case "deferred keeper wake when not running is retryable"
            `Quick
            test_deferred_keeper_wake_not_running_is_retryable
        ; test_case "due wake bypasses proactive policy" `Quick
            test_due_schedule_wakes_live_keeper_with_proactive_disabled
        ; test_case "keeper wake queue evidence rejects stale occurrence" `Quick
            test_keeper_wake_queue_evidence_rejects_stale_occurrence
        ; test_case "dashboard live supported non-terminal evidence matches supported request"
            `Quick
            test_dashboard_live_supported_non_terminal_evidence_matches_supported_request
        ; test_case "dashboard live supported non-terminal evidence reports absent supported payloads"
            `Quick
            test_dashboard_live_supported_non_terminal_evidence_reports_absent_supported_payloads
        ; test_case "keeper wake ledger failure is retryable" `Quick
            test_keeper_wake_ledger_failure_is_retryable
        ; test_case "unattributed ledger damage does not block occurrences" `Quick
            test_unattributed_ledger_damage_does_not_block_occurrences
        ; test_case "dashboard keeps unattributed damage out of exact evidence" `Quick
            test_dashboard_keeps_unattributed_damage_out_of_exact_evidence
        ; test_case "dashboard projects quarantined and unreadable reaction evidence"
            `Quick
            test_dashboard_projects_quarantined_and_unreadable_reaction_evidence
        ; test_case "keeper wake rejects invalid keeper name" `Quick
            test_keeper_wake_consumer_rejects_invalid_keeper_name
        ; test_case "keeper wake receipt decoder rejects noncanonical shapes"
            `Quick
            test_keeper_wake_receipt_decoder_rejects_noncanonical_shapes
        ; test_case "consumed grant without outcome stays actionable" `Quick
            test_consumed_grant_without_outcome_stays_actionable
        ; test_case "consumed grant with outcome retires without a turn" `Quick
            test_consumed_grant_with_outcome_retires_without_a_turn
        ; test_case "projection failure keeps spent replay queued" `Quick
            test_projection_failure_keeps_spent_replay_queued
        ; test_case "rejection projection precedes turn intake" `Quick
            test_rejected_resolution_projection_precedes_turn_intake
        ; test_case "unconsumed grant replay stays actionable" `Quick
            test_unconsumed_grant_replay_stays_actionable
        ] )
    ]
;;
