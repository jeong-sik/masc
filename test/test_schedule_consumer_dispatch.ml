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

let reaction_ledger_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Common.keepers_runtime_dir_of_base ~base_path)
          keeper_name)
       "reaction-ledger")
    "v5"
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
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
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
        ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
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
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error detail -> fail ("keeper meta write failed: " ^ detail));
  meta
;;

let register_keeper ?proactive_enabled config keeper_name =
  let meta = persist_keeper_meta ?proactive_enabled config keeper_name in
  Keeper_registry.For_testing.register
    ~base_path:config.Workspace_utils.base_path
    keeper_name
    meta
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
    ; "schema_version", `Int 1
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
    ; "schema_version", `Int 1
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

let unsupported_payload =
  `Assoc
    [ "kind", `String "legacy.unsupported_scheduler_payload"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "message", `String "This payload is not in the schedule consumer catalog." ]
    ]
;;

let canonical_keeper_wake_receipt_fields () =
  [ "kind", `String "masc.keeper_wake.enqueued"
  ; "keeper_name", `String "schedule-keeper"
  ; "schedule_id", `String "canonical-schedule"
  ; "urgency", `String "immediate"
  ; "post_id", `String "canonical-occurrence"
  ; "queue", `String "keeper_event_queue"
  ; "stimulus", `String "schedule_due"
  ; "stimulus_id", `String "canonical-occurrence"
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
     |> set_receipt_field "activation_detail" `Null)
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
      ; "schema_version", `Int 1
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

let latest_execution_exn config ~schedule_id =
  match
    Schedule_store.last_execution_for_schedule
      (Schedule_store.read_state config)
      ~schedule_id
  with
  | Some execution -> execution
  | None -> fail ("missing execution for schedule " ^ schedule_id)
;;

let single_keeper_settlement_exn config execution =
  match Server_schedule_consumers.consumer.settlements config [ execution ] with
  | [ Ok settlement ] -> settlement
  | [ Error detail ] -> fail detail
  | settlements ->
    failf "expected one settlement result, got %d" (List.length settlements)
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

let test_keeper_wake_consumer_records_dispatch_without_work_success () =
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
     check string "one-shot remains running until work completion" "running"
       (Schedule_domain.schedule_status_to_string stored.status));
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing execution record"
   | Some execution ->
     check string "execution status" "dispatched"
       (Schedule_domain.execution_status_to_string execution.status);
     check (option (float 0.001)) "accepted work is unfinished" None
       execution.finished_at;
     (match execution.detail with
      | Some detail ->
        let open Yojson.Safe.Util in
        check string "execution detail kind" "masc.keeper_wake.enqueued"
          (detail |> member "kind" |> to_string);
        check string "execution detail queue" "keeper_event_queue"
          (detail |> member "queue" |> to_string);
        check string "execution detail stimulus" "schedule_due"
          (detail |> member "stimulus" |> to_string);
        check string "execution keeper" "schedule-keeper"
          (detail |> member "keeper_name" |> to_string);
        check string "durable enqueue is separate from activation" "deferred"
          (detail |> member "activation_status" |> to_string);
        check string "missing owner truth fails activation closed" "owner_unknown"
          (detail |> member "activation_reason" |> to_string);
        check string
          "absent executor produces typed no-activation"
          "durable keeper metadata read unavailable: executor pool is not installed"
          (detail |> member "activation_detail" |> to_string)
      | None -> fail "execution detail missing"));
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
       check string "wake schedule" request.schedule_id wake.schedule_id;
       check string "wake title" "Scheduled lane wake" (Option.get wake.title);
       check string "wake message" "Run the scheduled maintenance lane now."
         wake.message;
       check string "wake digest"
         (Schedule_domain.payload_digest request.payload)
         wake.payload_digest
      | _ -> fail "expected Schedule_due payload"))
  ;
  check int "keeper wake does not create board posts" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()));
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
    check string "receipt schedule" request.schedule_id
      (receipt |> member "schedule_id" |> to_string);
    check string "receipt urgency" "immediate"
      (receipt |> member "urgency" |> to_string);
    check string "receipt post id" occurrence_id
      (receipt |> member "post_id" |> to_string);
    check string "receipt reaction ledger recorded" "recorded"
      (receipt |> member "reaction_ledger_status" |> to_string);
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
    check (float 0.001) "queue evidence execution due_at" request.due_at
      (queue_evidence |> member "execution_due_at" |> to_float);
    check string "queue evidence execution digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "execution_payload_digest" |> to_string);
    check (float 0.001) "queue evidence matched due_at" request.due_at
      (queue_evidence |> member "matched_due_at" |> to_float);
    check string "queue evidence matched digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "matched_payload_digest" |> to_string);
    check int "queue evidence pending count" 1
      (queue_evidence |> member "pending_count" |> to_int);
    check int "queue evidence read errors" 0
      (queue_evidence |> member "read_errors" |> to_list |> List.length)
  ; (match
       Schedule_store.complete_dispatched_occurrence
         config
         ~now:202.0
         ~schedule_id:request.schedule_id
         ~due_at:request.due_at
         ~payload_digest:(Schedule_domain.payload_digest request.payload)
         ()
     with
     | Ok _ -> ()
     | Error err -> fail (Schedule_store.store_error_to_string err));
    let terminal_dashboard =
      Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
    in
    let terminal_row =
      dashboard_schedule_row_exn terminal_dashboard ~schedule_id:request.schedule_id
    in
    check string "terminal execution succeeded" "succeeded"
      (terminal_row |> member "last_execution" |> member "status" |> to_string);
    check string "terminal projection retains recognized receipt" "recognized"
      (terminal_row
       |> member "dispatch_receipt"
       |> member "projection_status"
       |> to_string)
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

let test_reclaim_uses_occurrence_keeper_after_recurring_request_update () =
  with_workspace
  @@ fun config ->
  let request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 3600 })
      config
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  let updated_payload =
    match Schedule_domain.payload_of_yojson (keeper_wake_payload_for "next-keeper") with
    | Ok payload -> payload
    | Error detail -> fail detail
  in
  (match
     Schedule_service.update
       config
       ~schedule_id:request.schedule_id
       ~due_at:3801.0
       ~expires_at:None
       ~payload:updated_payload
   with
   | Ok _ -> ()
   | Error error ->
     fail (Schedule_service.service_error_to_string error));
  match single_keeper_settlement_exn config execution with
  | Schedule_runner.Consumer_holds_occurrence -> ()
  | Schedule_runner.Consumer_completed_occurrence
  | Schedule_runner.Consumer_failed_occurrence _
  | Schedule_runner.Consumer_cancelled_occurrence _ ->
    fail "updated recurring request changed the occurrence owner to settled"
  | Schedule_runner.Consumer_lost_occurrence detail ->
    fail ("updated recurring request changed the occurrence owner: " ^ detail)
;;

let test_reclaim_follows_transfer_durable_state () =
  with_workspace
  @@ fun config ->
  let source_keeper = "schedule-keeper" in
  let target_keeper = "transferred-schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 3600 })
      config
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  let selection = pending_selection_exn ~base_path ~keeper_name:source_keeper in
  let target_meta = persist_keeper_meta config target_keeper in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; owner_nonce = 17
    ; operator_operation_id = "transfer-scheduled-occurrence"
    ; from_keeper = source_keeper
    ; to_keeper = target_keeper
    ; target_generation = target_meta.runtime.nonce
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       source_keeper
       ~current_owner_nonce:17
       ~applied_at:202.0
       ~transfer
   with
   | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
     fail "first transfer was already applied"
   | Ok
       (Keeper_registry_event_queue.Transition_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail ->
     fail (Keeper_registry_event_queue.transfer_pending_error_to_string detail));
  (match single_keeper_settlement_exn config execution with
   | Schedule_runner.Consumer_holds_occurrence -> ()
   | _ -> fail "unprojected transfer was not retained as durable work");
  (match
     Keeper_event_queue_recovery.project_owner_result
       ~base_path
       ~keeper_name:source_keeper
   with
   | Ok Keeper_event_queue_recovery.Transition_converged -> ()
   | Ok _ -> fail "transfer projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  (match single_keeper_settlement_exn config execution with
   | Schedule_runner.Consumer_holds_occurrence -> ()
   | _ -> fail "projected target occurrence was not retained as durable work");
  let target_selection =
    pending_selection_exn ~base_path ~keeper_name:target_keeper
  in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       target_keeper
     ~current_owner_nonce:23
     ~applied_at:203.0
     ~selection:target_selection
       ~detail:"scheduled occurrence failed"
   with
   | Ok (Keeper_registry_event_queue.Acked _)
   | Ok (Keeper_registry_event_queue.Already_acked _) -> ()
   | Ok
       (Keeper_registry_event_queue.Ack_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail -> fail detail);
  (match single_keeper_settlement_exn config execution with
   | Schedule_runner.Consumer_failed_occurrence detail ->
     check string
       "failed turn reason remains typed"
       "scheduled occurrence failed"
       detail
   | _ -> fail "target failed-turn receipt did not preserve failure");
  (match
     Keeper_event_queue_recovery.project_owner_result
       ~base_path
       ~keeper_name:target_keeper
   with
   | Ok Keeper_event_queue_recovery.Transition_converged -> ()
   | Ok _ -> fail "terminal ACK projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  let target_state =
    match
      Keeper_registry_event_queue.durable_state_result ~base_path target_keeper
    with
    | Ok state -> state
    | Error detail -> fail detail
  in
  check int "terminal outbox retired after projection" 0
    (Keeper_event_queue_state.transition_outbox target_state |> List.length);
  check int "terminal receipt retained in checkpoint" 1
    (Keeper_event_queue_state.projected_transition_receipts target_state
     |> List.filter (fun receipt ->
       match receipt.Keeper_event_queue_state.transition with
       | Keeper_event_queue_state.Ack_source_terminal terminal ->
         String.equal terminal.source.post_id selection.source.post_id
       | Keeper_event_queue_state.Cancel_accepted _
       | Keeper_event_queue_state.Transfer_accepted _ -> false)
     |> List.length);
  let transition_wal_path =
    Filename.concat
      (Filename.concat
         (Common.keepers_runtime_dir_of_base ~base_path)
         target_keeper)
      "event-queue-transitions-v5.jsonl"
  in
  check string "checkpointed transition WAL compacted" ""
    (read_file transition_wal_path);
  match single_keeper_settlement_exn config execution with
  | Schedule_runner.Consumer_failed_occurrence detail ->
    check string
      "checkpoint preserves failed turn reason"
      "scheduled occurrence failed"
      detail
  | _ -> fail "checkpoint reload lost the failed occurrence disposition"
;;

let test_reclaim_resolves_current_incarnation_after_transfer_back () =
  with_workspace
  @@ fun config ->
  let keeper_a = "schedule-keeper" in
  let keeper_b = "transfer-return-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 3600 })
      config
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  let meta_a = persist_keeper_meta config keeper_a in
  let meta_b = persist_keeper_meta config keeper_b in
  let transfer ~from_keeper ~to_keeper ~owner_nonce ~operation_id ~applied_at =
    let selection = pending_selection_exn ~base_path ~keeper_name:from_keeper in
    let accepted : Keeper_registry_event_queue.accepted_transfer =
      { source = selection.source
      ; source_incarnation = selection.admitted_revision
      ; owner_nonce
      ; operator_operation_id = operation_id
      ; from_keeper
      ; to_keeper
      ; target_generation =
          (if String.equal to_keeper keeper_a then meta_a else meta_b).runtime.nonce
      ; target_trace_id =
          (if String.equal to_keeper keeper_a then meta_a else meta_b).runtime.trace_id
      }
    in
    (match
       Keeper_registry_event_queue.transfer_pending_accepted_result
         ~base_path
         from_keeper
         ~current_owner_nonce:owner_nonce
         ~applied_at
         ~transfer:accepted
     with
     | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
     | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
       fail "first transfer application was reported as replay"
     | Ok
         (Keeper_registry_event_queue.Transition_committed_followup_failed
            { detail; _ }) ->
       fail detail
     | Error detail ->
       fail (Keeper_registry_event_queue.transfer_pending_error_to_string detail));
    match
      Keeper_event_queue_recovery.project_owner_result
        ~base_path
        ~keeper_name:from_keeper
    with
    | Ok Keeper_event_queue_recovery.Transition_converged -> ()
    | Ok _ -> fail "transfer projection did not converge"
    | Error error ->
      fail (Keeper_event_queue_recovery.projection_error_to_string error)
  in
  transfer
    ~from_keeper:keeper_a
    ~to_keeper:keeper_b
    ~owner_nonce:31
    ~operation_id:"scheduled-a-to-b"
    ~applied_at:202.0;
  transfer
    ~from_keeper:keeper_b
    ~to_keeper:keeper_a
    ~owner_nonce:32
    ~operation_id:"scheduled-b-to-a"
    ~applied_at:203.0;
  match single_keeper_settlement_exn config execution with
  | Schedule_runner.Consumer_holds_occurrence -> ()
  | Schedule_runner.Consumer_completed_occurrence
  | Schedule_runner.Consumer_failed_occurrence _
  | Schedule_runner.Consumer_cancelled_occurrence _ ->
    fail "returned current incarnation was mistaken for historical terminal state"
  | Schedule_runner.Consumer_lost_occurrence detail ->
    fail ("returned current incarnation was reported lost: " ^ detail)
;;

let test_reclaim_revalidates_cached_transfer_target_absence () =
  with_workspace
  @@ fun config ->
  let keeper_a = "cached-transfer-source" in
  let keeper_b = "cached-transfer-target" in
  let base_path = config.Workspace_utils.base_path in
  let request_x =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"cached-target-existing"
      ~keeper_name:keeper_b
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let execution_x = latest_execution_exn config ~schedule_id:request_x.schedule_id in
  let stale_b_state =
    match Keeper_registry_event_queue.existing_durable_state_result ~base_path keeper_b with
    | Ok state -> state
    | Error detail -> fail detail
  in
  let request_y =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"cached-target-transferred"
      ~keeper_name:keeper_a
  in
  ignore (tick_ok config ~now:202.0 : Schedule_runner.tick_result);
  let execution_y = latest_execution_exn config ~schedule_id:request_y.schedule_id in
  let selection = pending_selection_exn ~base_path ~keeper_name:keeper_a in
  let target_meta = persist_keeper_meta config keeper_b in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; owner_nonce = 41
    ; operator_operation_id = "cached-a-to-b"
    ; from_keeper = keeper_a
    ; to_keeper = keeper_b
    ; target_generation = target_meta.runtime.nonce
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       keeper_a
       ~current_owner_nonce:41
       ~applied_at:203.0
       ~transfer
   with
   | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
     fail "first cached transfer was already applied"
   | Ok
       (Keeper_registry_event_queue.Transition_committed_followup_failed
          { detail; _ }) ->
     fail detail
   | Error detail ->
     fail (Keeper_registry_event_queue.transfer_pending_error_to_string detail));
  (match
     Keeper_event_queue_recovery.project_owner_result
       ~base_path
       ~keeper_name:keeper_a
   with
   | Ok Keeper_event_queue_recovery.Transition_converged -> ()
   | Ok _ -> fail "cached transfer projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  let target_reads = ref 0 in
  let read_state ~base_path requested_keeper =
    if String.equal requested_keeper keeper_b
    then (
      incr target_reads;
      if Int.equal !target_reads 1
      then Ok stale_b_state
      else
        Keeper_registry_event_queue.existing_durable_state_result
          ~base_path
          requested_keeper)
    else
      Keeper_registry_event_queue.existing_durable_state_result
        ~base_path
        requested_keeper
  in
  let settlements =
    Server_schedule_consumers.For_testing.settlements_with_read_state
      ~read_state
      config
      [ execution_x; execution_y ]
  in
  (match settlements with
   | [ Ok Schedule_runner.Consumer_holds_occurrence
     ; Ok Schedule_runner.Consumer_holds_occurrence
     ] -> ()
   | _ -> fail "fresh transfer target state was not revalidated");
  check int "stale target absence triggers one exact reread" 2 !target_reads
;;

let test_reclaim_keeps_occurrence_when_queue_snapshot_is_missing () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request =
    create_keeper_wake_schedule
      ~recurrence:(Schedule_domain.Interval { interval_sec = 3600 })
      config
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  let queue_path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      "event-queue-v15.json"
  in
  Sys.remove queue_path;
  let outcome =
    match
      Schedule_runner.reclaim_lost_occurrences
        ~consumer:Server_schedule_consumers.consumer
        config
        ~now:202.0
    with
    | Ok outcome -> outcome
    | Error error -> fail (Schedule_runner.runner_error_to_string error)
  in
  check int "missing snapshot reclaims nothing" 0 outcome.reclaimed;
  check int "missing snapshot is one typed consumer failure" 1
    (List.length outcome.failures);
  (match outcome.failures with
   | [ Schedule_runner.Occurrence_reclaim_failure
         { occurrence_id; error = detail }
     ] ->
     let expected_occurrence_id =
       Schedule_occurrence_id.make
         ~schedule_id:execution.schedule_id
         ~due_at:execution.due_at
         ~payload_digest:execution.payload_digest
       |> Schedule_occurrence_id.to_string
     in
     check string "failure keeps exact occurrence identity"
       expected_occurrence_id
       occurrence_id;
     check bool "missing snapshot provenance is explicit" true
       (String_util.contains_substring detail "event queue snapshot is missing")
   | [ Schedule_runner.Settlement_batch_cardinality_mismatch _ ]
   | [ Schedule_runner.Settlement_batch_consumer_failure _ ]
   | []
   | _ :: _ :: _ -> fail "expected one missing-snapshot reclaim failure");
  match
    Schedule_store.execution_for_occurrence
      (Schedule_store.read_state config)
      ~schedule_id:execution.schedule_id
      ~due_at:execution.due_at
      ~payload_digest:execution.payload_digest
  with
  | Some retained ->
    check string "unreadable occurrence remains dispatched"
      "dispatched"
      (Schedule_domain.execution_status_to_string retained.status)
  | None -> fail "missing snapshot caused the occurrence to disappear"
;;

let test_keeper_purge_settles_owned_occurrence_before_queue_delete () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name
       ~operation_id:"purge-op-1"
       ~now:202.0
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  let queue_path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      "event-queue-v15.json"
  in
  Sys.remove queue_path;
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | Some stored ->
     check string "purged one-shot is terminal" "failed"
       (Schedule_domain.schedule_status_to_string stored.status)
   | None -> fail "purged schedule missing");
  match latest_execution_exn config ~schedule_id:request.schedule_id with
  | { status = Schedule_domain.Execution_failed; error = Some reason; _ } ->
    check bool "purge operation remains in terminal evidence" true
      (String_util.contains_substring reason "purge-op-1")
  | execution ->
    failf
      "purged occurrence stayed %s"
      (Schedule_domain.execution_status_to_string execution.status)
;;

let test_keeper_purge_cancels_future_schedule_intent () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let create ~schedule_id ?recurrence () =
    match
      Schedule_service.create
        config
        ~schedule_id
        ~requested_at:100.0
        ~requested_by:(human "operator")
        ~scheduled_by:(automated "scheduler-agent")
        ~due_at:400.0
        ~payload:(keeper_wake_payload_for keeper_name)
        ~source:Schedule_domain.Operator_request
        ?recurrence
        ()
    with
    | Ok request -> request
    | Error error ->
      fail ("create failed: " ^ Schedule_service.service_error_to_string error)
  in
  let one_shot = create ~schedule_id:"purge-future-one-shot" () in
  let recurring =
    create
      ~schedule_id:"purge-future-recurring"
      ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
      ()
  in
  ignore
    (create_named_keeper_wake_schedule
       config
       ~schedule_id:"purge-other-keeper"
       ~keeper_name:"other-keeper"
     : Schedule_domain.schedule_request);
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name
       ~operation_id:"purge-future-op"
       ~now:202.0
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  List.iter
    (fun (request : Schedule_domain.schedule_request) ->
       match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "future target intent is cancelled" "cancelled"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "future target schedule disappeared")
    [ one_shot; recurring ];
  match Schedule_store.get_schedule config ~schedule_id:"purge-other-keeper" with
  | Some stored ->
    check string "unrelated target remains scheduled" "scheduled"
      (Schedule_domain.schedule_status_to_string stored.status)
  | None -> fail "unrelated target schedule disappeared"
;;

let test_keeper_purge_rejects_missing_owned_snapshot () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let queue_path =
    Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
      "event-queue-v15.json"
  in
  Sys.remove queue_path;
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name
       ~operation_id:"purge-op-missing"
       ~now:202.0
   with
   | Ok () -> fail "purge accepted missing schedule evidence"
   | Error detail ->
     check bool "missing evidence blocks purge" true
       (String_util.contains_substring detail "missing durable schedule evidence"));
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  check string "blocked purge keeps occurrence unsettled" "dispatched"
    (Schedule_domain.execution_status_to_string execution.status)
;;

let test_keeper_purge_preflights_whole_batch () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  ignore
    (create_named_keeper_wake_schedule
       config
       ~schedule_id:"purge-batch-a"
       ~keeper_name
     : Schedule_domain.schedule_request);
  ignore
    (create_named_keeper_wake_schedule
       config
       ~schedule_id:"purge-batch-b"
       ~keeper_name
     : Schedule_domain.schedule_request);
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let executions =
    Schedule_store.read_state config
    |> Schedule_store.unsettled_dispatched_occurrences
  in
  let first, second =
    match executions with
    | [ first; second ] -> first, second
    | rows -> failf "expected two dispatched occurrences, got %d" (List.length rows)
  in
  let missing_occurrence =
    Schedule_occurrence_id.make
      ~schedule_id:second.schedule_id
      ~due_at:second.due_at
      ~payload_digest:second.payload_digest
    |> Schedule_occurrence_id.to_string
  in
  (match
     Keeper_registry_event_queue.drop_by_post_id
       ~base_path
       keeper_name
       ~post_id:missing_occurrence
   with
   | Ok [ _ ] -> ()
   | Ok removed -> failf "expected one removed occurrence, got %d" (List.length removed)
   | Error detail -> fail detail);
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name
       ~operation_id:"purge-op-batch"
       ~now:202.0
   with
   | Ok () -> fail "purge accepted a partially invalid evidence batch"
   | Error detail ->
     check bool "later missing evidence blocks whole batch" true
       (String_util.contains_substring detail "missing durable schedule evidence"));
  let state = Schedule_store.read_state config in
  List.iter
    (fun (execution : Schedule_domain.execution_record) ->
       match
         Schedule_store.execution_for_occurrence
           state
           ~schedule_id:execution.schedule_id
           ~due_at:execution.due_at
           ~payload_digest:execution.payload_digest
       with
       | Some retained ->
         check string "preflight failure leaves every occurrence dispatched"
           "dispatched"
           (Schedule_domain.execution_status_to_string retained.status)
       | None -> fail "preflight failure removed an execution")
    [ first; second ]
;;

let test_keeper_purge_rejects_unsettled_transfer_redirect () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let source_keeper = "purge-transfer-source" in
  let target_keeper = "purge-transfer-target" in
  let request =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"purge-transfer-schedule"
      ~keeper_name:source_keeper
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let selection = pending_selection_exn ~base_path ~keeper_name:source_keeper in
  let target_meta = persist_keeper_meta config target_keeper in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; owner_nonce = 41
    ; operator_operation_id = "purge-transfer-op"
    ; from_keeper = source_keeper
    ; to_keeper = target_keeper
    ; target_generation = target_meta.runtime.nonce
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       source_keeper
       ~current_owner_nonce:41
       ~applied_at:202.0
       ~transfer
   with
   | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
     fail "first purge transfer was already applied"
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
   | Ok _ -> fail "purge transfer projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name:source_keeper
       ~operation_id:"purge-source"
       ~now:203.0
   with
   | Ok () -> fail "purge discarded an unsettled transfer redirect"
   | Error detail ->
     check bool "unsettled redirect blocks source purge" true
       (String_util.contains_substring detail "unsettled transferred"));
  let execution = latest_execution_exn config ~schedule_id:request.schedule_id in
  check string "blocked source purge preserves dispatched execution" "dispatched"
    (Schedule_domain.execution_status_to_string execution.status)
;;

let test_keeper_purge_follows_terminal_transfer_redirect () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let source_keeper = "purge-terminal-source" in
  let target_keeper = "purge-terminal-target" in
  let request =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"purge-terminal-transfer-schedule"
      ~keeper_name:source_keeper
  in
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let selection = pending_selection_exn ~base_path ~keeper_name:source_keeper in
  let target_meta = persist_keeper_meta config target_keeper in
  let transfer : Keeper_registry_event_queue.accepted_transfer =
    { source = selection.source
    ; source_incarnation = selection.admitted_revision
    ; owner_nonce = 43
    ; operator_operation_id = "purge-terminal-transfer-op"
    ; from_keeper = source_keeper
    ; to_keeper = target_keeper
    ; target_generation = target_meta.runtime.nonce
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       source_keeper
       ~current_owner_nonce:43
       ~applied_at:202.0
       ~transfer
   with
   | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
   | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
     fail "terminal purge transfer was already applied"
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
   | Ok _ -> fail "terminal purge transfer projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  let target_selection =
    pending_selection_exn ~base_path ~keeper_name:target_keeper
  in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       target_keeper
       ~current_owner_nonce:47
       ~applied_at:203.0
       ~selection:target_selection
       ~detail:"scheduled occurrence failed at target"
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
       ~keeper_name:target_keeper
   with
   | Ok Keeper_event_queue_recovery.Transition_converged -> ()
   | Ok _ -> fail "terminal target projection did not converge"
   | Error error ->
     fail (Keeper_event_queue_recovery.projection_error_to_string error));
  (match
     Server_schedule_consumers.settle_keeper_purge_occurrences
       config
       ~keeper_name:source_keeper
       ~operation_id:"purge-terminal-source"
       ~now:204.0
   with
   | Ok () -> ()
   | Error detail -> fail detail);
  match latest_execution_exn config ~schedule_id:request.schedule_id with
  | { status = Schedule_domain.Execution_failed
    ; error = Some detail
    ; _ } ->
    check string "purge follows terminal transfer failure"
      "scheduled occurrence failed at target"
      detail
  | execution ->
    failf
      "terminal transferred occurrence stayed %s"
      (Schedule_domain.execution_status_to_string execution.status)
;;

let test_shutdown_fence_rejects_schedule_intake_before_enqueue () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_reserved _ -> ()
   | Keeper_turn_admission.Shutdown_already_reserved _ ->
     fail "fresh shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_turn_admission.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
         : Keeper_turn_admission.rollback_shutdown_result))
    (fun () ->
       let request = create_keeper_wake_schedule config in
       let result = tick_ok config ~now:201.0 in
       (match result.dispatches with
        | [ { status = Schedule_runner.Dispatch_failed; error = Some detail; _ } ] ->
          check bool "dispatch reports exact shutdown fence" true
            (String_util.contains_substring detail "rejected by shutdown fence")
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
     Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_reserved _ -> ()
   | Keeper_turn_admission.Shutdown_already_reserved _ ->
     fail "fresh direct-producer shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_turn_admission.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
         : Keeper_turn_admission.rollback_shutdown_result))
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
    ; owner_nonce = 53
    ; operator_operation_id = "resolved-owner-fence-transfer"
    ; from_keeper = source_keeper
    ; to_keeper = target_keeper
    ; target_generation = target_meta.runtime.nonce
    ; target_trace_id = target_meta.runtime.trace_id
    }
  in
  (match
     Keeper_registry_event_queue.transfer_pending_accepted_result
       ~base_path
       source_keeper
       ~current_owner_nonce:53
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
     Keeper_turn_admission.begin_shutdown
       ~base_path
       ~keeper_name:target_keeper
       ~operation_id
   with
   | Keeper_turn_admission.Shutdown_reserved _ -> ()
   | Keeper_turn_admission.Shutdown_already_reserved _ ->
     fail "fresh target shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_turn_admission.rollback_shutdown
           ~base_path
           ~keeper_name:target_keeper
           ~operation_id
         : Keeper_turn_admission.rollback_shutdown_result))
    (fun () ->
       let retried = tick_ok config ~now:202.0 in
       (match retried.dispatches with
        | [ { status = Schedule_runner.Dispatch_failed
            ; error = Some detail
            ; _
            } ] ->
          check bool "retry reports the resolved owner fence" true
            (String_util.contains_substring detail ("keeper=" ^ target_keeper))
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
          Keeper_turn_admission.begin_shutdown
            ~base_path
            ~keeper_name
            ~operation_id
        with
        | Keeper_turn_admission.Shutdown_reserved _ -> ()
        | Keeper_turn_admission.Shutdown_already_reserved _ ->
          fail "fresh shutdown fence was already reserved");
       Fun.protect
         ~finally:(fun () ->
           ignore
             (Keeper_turn_admission.rollback_shutdown
                ~base_path
                ~keeper_name
                ~operation_id
              : Keeper_turn_admission.rollback_shutdown_result))
         (fun () ->
            Eio.Fiber.both
              (fun () ->
                 Keeper_turn_admission.await_idle_after_shutdown
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
  let queue_path = Filename.concat keeper_owner_path "event-queue-v15.json" in
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
      let generation = entry.meta.runtime.nonce in
      let selection =
        Keeper_event_queue_state.select_when
          ~ready:(fun _ -> true)
          pending_state
        |> function
        | Some selection -> selection
        | None -> fail "schedule cancellation source was not selectable"
      in
      let cancellation : Keeper_event_queue_state.accepted_cancellation =
        { source = selection.source
        ; source_incarnation = selection.admitted_revision
        ; owner_nonce = generation
        ; operator_operation_id = "cancel-schedule-occurrence"
        ; reason = "operator cancelled retained schedule work"
        }
      in
      (match
         Keeper_registry_event_queue.cancel_pending_accepted_result
           ~base_path
           keeper_name
          ~current_owner_nonce:generation
          ~applied_at:203.0
          ~cancellation
       with
       | Ok (Keeper_registry_event_queue.Transition_applied _) -> ()
       | Ok (Keeper_registry_event_queue.Transition_already_applied _) ->
         fail "first schedule cancellation was already settled"
       | Ok (Keeper_registry_event_queue.Transition_committed_followup_failed _) ->
         fail "schedule cancellation follow-up failed"
       | Error detail -> fail detail);
      let transition_wal_path =
        Filename.concat
          (Filename.concat
             (Common.keepers_runtime_dir_of_base ~base_path)
             keeper_name)
          "event-queue-transitions-v5.jsonl"
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
       | { status = Schedule_runner.Dispatch_failed
         ; detail = Some detail
         ; error = Some error
         ; _
         } ->
         check string "retry observes terminal cancellation" "already_cancelled"
           Yojson.Safe.Util.(detail |> member "occurrence_status" |> to_string);
         check string "terminal cancellation needs no activation" "not_required"
           Yojson.Safe.Util.(detail |> member "activation_status" |> to_string);
         check bool "terminal cancellation failure is explicit" true
           (String_util.contains_substring error "already cancelled")
       | _ -> fail "cancelled retry terminal receipt missing");
      check int "cancelled retry enqueues no second occurrence" 0
        (Keeper_registry_event_queue.snapshot ~base_path keeper_name
         |> Keeper_event_queue.length);
      (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "cancelled one-shot is terminal" "failed"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "cancelled schedule missing");
      (match
         Schedule_store.execution_for_occurrence
           (Schedule_store.read_state config)
           ~schedule_id:request.schedule_id
           ~due_at:request.due_at
           ~payload_digest:(Schedule_domain.payload_digest request.payload)
       with
       | Some execution ->
         check string "cancelled occurrence execution is terminal" "failed"
           (Schedule_domain.execution_status_to_string execution.status)
       | None -> fail "cancelled occurrence execution missing");
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

let test_terminal_reconciliation_before_retry_recreates_wake () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let ledger_dir = reaction_ledger_dir ~base_path ~keeper_name in
  mkdir_p ledger_dir;
  Unix.chmod ledger_dir 0o500;
  let request = create_keeper_wake_schedule config in
  let first = tick_ok config ~now:201.0 in
  Unix.chmod ledger_dir 0o755;
  check string "first dispatch is retryable failure" "failed"
    (Schedule_runner.dispatch_status_to_string (List.hd first.dispatches).status);
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Spent_schedule_acknowledged -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable ->
     fail "failed occurrence was not reconciled as terminal"
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "schedule selection was reconciled as a spent grant replay"
   | Error detail -> fail detail);
  check int "terminal wake removed before retry" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  rm_rf ledger_dir;
  let retried = tick_ok config ~now:202.0 in
  check string "retry dispatch succeeds" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd retried.dispatches).status);
  check int "retry recreates wake after terminal ACK" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  match
    Schedule_store.execution_for_occurrence
      (Schedule_store.read_state config)
      ~schedule_id:request.schedule_id
      ~due_at:request.due_at
      ~payload_digest:(Schedule_domain.payload_digest request.payload)
  with
  | Some execution ->
    check string "retry remains live" "dispatched"
      (Schedule_domain.execution_status_to_string execution.status)
  | None -> fail "retried execution missing"
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
  Sys.remove ledger_dir;
  mkdir_p ledger_dir;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_registry_event_queue.terminalize_pending_turn_attempt_result
       ~base_path
       keeper_name
       ~current_owner_nonce:91
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
  let retried = tick_ok config ~now:202.0 in
  (match List.hd retried.dispatches with
   | { status = Schedule_runner.Dispatch_failed
     ; detail = Some detail
     ; error = Some error
     ; _
     } ->
     check string "retry observes terminal failure" "already_failed"
       Yojson.Safe.Util.(detail |> member "occurrence_status" |> to_string);
     check string "terminal retry needs no activation" "not_required"
       Yojson.Safe.Util.(detail |> member "activation_status" |> to_string);
     check bool "terminal failure reason is preserved" true
       (String_util.contains_substring error "terminal before schedule retry")
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
       ~current_owner_nonce:97
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
   | Ok Keeper_heartbeat_stimulus_intake.Spent_schedule_acknowledged ->
     fail "non-terminal retry wake was acknowledged"
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged ->
     fail "schedule selection was reconciled as a spent grant replay"
   | Error detail -> fail detail);
  check int "retry wake remains pending" 1
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
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
         Schedule_store.last_execution_for_schedule
           (Schedule_store.read_state config)
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
       | Some _ -> fail "schedule execution detail missing"
       | None -> fail "schedule execution missing")
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
      ; "schema_version", `Int 1
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
    { schedule_id = request.schedule_id
    ; due_at = request.due_at +. 60.0
    ; payload_digest = Schedule_domain.payload_digest stale_payload
    ; title = Some "Scheduled lane wake"
    ; message = "Run a different scheduled occurrence."
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
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
    check (float 0.001) "queue evidence execution due_at" request.due_at
      (queue_evidence |> member "execution_due_at" |> to_float);
    check string "queue evidence execution digest"
      (Schedule_domain.payload_digest request.payload)
      (queue_evidence |> member "execution_payload_digest" |> to_string);
    check int "stale occurrence still visible as pending" 1
      (queue_evidence |> member "pending_count" |> to_int)
;;

let test_dashboard_live_supported_non_terminal_evidence_matches_supported_request () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
        [ "schema", `String "keeper.reaction_ledger.v5"
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
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
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
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing unsupported execution"
   | Some execution ->
     check string "execution failed" "failed"
       (Schedule_domain.execution_status_to_string execution.status);
     check (option string) "execution error"
       (Some
          (Schedule_supported_kinds.keeper_wake_target_name_error
             ~field:"masc.keeper_wake payload body.keeper_name"))
       execution.error);
  let queue_discovery =
    Keeper_event_queue_persistence.discover_keeper_names_with_snapshots
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
        ~input
        ~base_path
        ()
    with
    | Ok id -> id
    | Error error -> fail (Keeper_approval_queue.storage_error_to_string error)
  in
  (match
     Keeper_approval_queue.resolve_with_policy
       ~base_path
       ~id:approval_id
       ~decision:Keeper_approval_queue.Decision.Approve
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

let test_consumed_grant_without_outcome_stays_actionable () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "spent-grant-keeper" in
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
   | Ok Keeper_approval_queue.Consumption_committed -> ()
   | Ok Keeper_approval_queue.Consumption_already_committed ->
     fail "grant was already consumed before the test consumed it"
   | Ok Keeper_approval_queue.Consumption_not_matching ->
     fail "exact grant did not match its own request"
   | Error error -> fail (Keeper_approval_queue.grant_error_to_string error));
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
     fail "consumed replay was discarded before its outcome became durable"
   | Ok Keeper_heartbeat_stimulus_intake.Spent_schedule_acknowledged ->
     fail "grant replay was reconciled as a schedule occurrence"
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
   | Ok Keeper_approval_queue.Consumption_committed -> ()
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
  check_single_queued_replay ~base_path ~keeper_name;
  let selection = pending_selection_exn ~base_path ~keeper_name in
  (match
     Keeper_heartbeat_stimulus_intake.reconcile_spent_selection
       ~config
       ~keeper_name
       selection
   with
   | Ok Keeper_heartbeat_stimulus_intake.Spent_grant_replay_acknowledged -> ()
   | Ok Keeper_heartbeat_stimulus_intake.Selection_actionable ->
     fail "durable replay outcome was left at the queue head"
   | Ok Keeper_heartbeat_stimulus_intake.Spent_schedule_acknowledged ->
     fail "grant replay was reconciled as a schedule occurrence"
   | Error detail -> fail detail);
  check int "spent grant replay left the queue" 0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length)
;;

let test_unconsumed_grant_replay_stays_actionable () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let keeper_name = "live-grant-keeper" in
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
   | Ok Keeper_heartbeat_stimulus_intake.Spent_schedule_acknowledged ->
     fail "grant replay was reconciled as a schedule occurrence"
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
        ; test_case "keeper wake records dispatch without work success" `Quick
            test_keeper_wake_consumer_records_dispatch_without_work_success
        ; test_case "recurring wakes keep distinct occurrence ids" `Quick
            test_recurring_wakes_keep_distinct_occurrence_ids
        ; test_case "reclaim keeps occurrence owner after recurring request update"
            `Quick
            test_reclaim_uses_occurrence_keeper_after_recurring_request_update
        ; test_case "reclaim follows durable transfer state" `Quick
            test_reclaim_follows_transfer_durable_state
        ; test_case "reclaim follows current incarnation after transfer back"
            `Quick
            test_reclaim_resolves_current_incarnation_after_transfer_back
        ; test_case "reclaim revalidates cached transfer target absence"
            `Quick
            test_reclaim_revalidates_cached_transfer_target_absence
        ; test_case "reclaim keeps occurrence when queue snapshot is missing" `Quick
            test_reclaim_keeps_occurrence_when_queue_snapshot_is_missing
        ; test_case "keeper purge settles owned occurrence before queue deletion"
            `Quick
            test_keeper_purge_settles_owned_occurrence_before_queue_delete
        ; test_case "keeper purge cancels future schedule intent" `Quick
            test_keeper_purge_cancels_future_schedule_intent
        ; test_case "keeper purge rejects missing owned snapshot" `Quick
            test_keeper_purge_rejects_missing_owned_snapshot
        ; test_case "keeper purge preflights the whole batch" `Quick
            test_keeper_purge_preflights_whole_batch
        ; test_case "keeper purge rejects unsettled transfer redirects" `Quick
            test_keeper_purge_rejects_unsettled_transfer_redirect
        ; test_case "keeper purge follows terminal transfer redirects" `Quick
            test_keeper_purge_follows_terminal_transfer_redirect
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
        ; test_case "terminal reconciliation before retry recreates wake"
            `Quick
            test_terminal_reconciliation_before_retry_recreates_wake
        ; test_case "terminal retry repairs missing stimulus ledger"
            `Quick
            test_terminal_retry_repairs_missing_stimulus_ledger
        ; test_case "terminal retry requires acceptance commit" `Quick
            test_terminal_retry_requires_acceptance_commit
        ; test_case "retry before terminal reconciliation retains wake"
            `Quick
            test_retry_before_terminal_reconciliation_retains_wake
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
        ; test_case "unconsumed grant replay stays actionable" `Quick
            test_unconsumed_grant_replay_stays_actionable
        ] )
    ]
;;
