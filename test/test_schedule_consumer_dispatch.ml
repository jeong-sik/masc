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
  (match Keeper_meta_store.write_meta config meta with
   | Ok () -> ()
   | Error detail -> fail ("keeper meta write failed: " ^ detail));
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

let test_keeper_wake_durable_enqueue_failure_retries_same_occurrence () =
  with_workspace
  @@ fun config ->
  let keeper_owner_path =
    Filename.concat
      (Common.keepers_runtime_dir_of_base
         ~base_path:config.Workspace_utils.base_path)
      "schedule-keeper"
  in
  mkdir_p keeper_owner_path;
  let queue_path = Filename.concat keeper_owner_path "event-queue-v14.json" in
  mkdir_p queue_path;
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  let occurrence_id = single_occurrence_id result in
  (match List.hd result.dispatches with
   | { status = Schedule_runner.Dispatch_failed; error = Some message; _ } ->
     check bool "storage failure is explicit" true
       (String_util.contains_substring
          message
          "scheduled keeper wake durable enqueue failed")
   | _ -> fail "durable enqueue failure must not report dispatch success");
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
      (match Server_schedule_consumers.consumer.dispatch config ~now:202.0 signal running with
       | Ok _ -> ()
       | Error _ -> fail "initial schedule occurrence dispatch failed");
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
          "event-queue-transitions-v4.jsonl"
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
   | None -> fail "ledger failure detail missing")
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
        ; test_case "keeper wake durable enqueue retries same occurrence" `Quick
            test_keeper_wake_durable_enqueue_failure_retries_same_occurrence
        ; test_case "cancelled occurrence recovery does not enqueue again"
            `Quick
            test_cancelled_occurrence_recovery_does_not_enqueue_again
        ; test_case "terminal reconciliation before retry recreates wake"
            `Quick
            test_terminal_reconciliation_before_retry_recreates_wake
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
