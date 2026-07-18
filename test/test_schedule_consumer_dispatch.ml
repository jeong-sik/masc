open Alcotest
open Masc

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

let reaction_ledger_path_exn ~base_path ~keeper_name =
  match Keeper_reaction_store.database_path ~base_path ~keeper_name with
  | Ok path -> path
  | Error error ->
    fail
      ("reaction ledger path resolution failed: "
       ^ Keeper_reaction_store.error_to_string error)
;;

let replace_reaction_ledger_with_directory ~base_path ~keeper_name =
  let path = reaction_ledger_path_exn ~base_path ~keeper_name in
  rm_rf path;
  mkdir_p path
;;

let require_reaction_ledger_write label = function
  | Ok _ -> ()
  | Error error ->
    fail (label ^ ": " ^ Keeper_reaction_ledger.ledger_error_to_string error)
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Unix.putenv "MASC_BASE_PATH" dir;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "test"));
  f config
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let keeper_meta_for_name keeper_name =
  match
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
        [ "name", `String keeper_name
        ; "agent_name", `String keeper_name
        ; "trace_id", `String ("trace-" ^ keeper_name)
        ; "last_model_used", `String "llama:auto"
        ])
  with
  | Ok meta -> meta
  | Error msg -> fail ("keeper meta parse failed: " ^ msg)
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

let test_keeper_wake_consumer_enqueues_typed_stimulus_and_succeeds_schedule () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
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
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing execution record"
   | Some execution ->
     check string "execution status" "succeeded"
       (Schedule_domain.execution_status_to_string execution.status);
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
          (detail |> member "keeper_name" |> to_string)
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
    let receipt = row |> member "dispatch_receipt" in
    check string "receipt recognized" "recognized"
      (receipt |> member "projection_status" |> to_string);
    check string "receipt kind" "masc.keeper_wake.enqueued"
      (receipt |> member "kind" |> to_string);
    check string "receipt occurrence awaits settlement" "awaiting_settlement"
      (receipt |> member "occurrence_status" |> to_string);
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
    check int "queue evidence inflight count" 0
      (queue_evidence |> member "inflight_count" |> to_int);
    check int "queue evidence read errors" 0
      (queue_evidence |> member "read_errors" |> to_list |> List.length)
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
  let queue_path = Filename.concat keeper_owner_path "event-queue-v4.json" in
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

let test_keeper_wake_retry_records_committed_arrival () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  let payload_digest = Schedule_domain.payload_digest request.payload in
  let occurrence_id =
    Schedule_occurrence_id.make
      ~schedule_id:request.schedule_id
      ~due_at:request.due_at
      ~payload_digest
  in
  let signal : Schedule_runner.wake_signal =
    { occurrence_id
    ; kind = Schedule_runner.Due_candidate
    ; schedule_id = request.schedule_id
    ; emitted_at = 201.0
    ; due_at = request.due_at
    ; payload_digest
    ; payload = Schedule_domain.payload_to_yojson request.payload
    }
  in
  let wake : Keeper_event_queue.scheduled_wake =
    { schedule_id = request.schedule_id
    ; due_at = request.due_at
    ; payload_digest
    ; title = Some "Scheduled lane wake"
    ; message = "Run the scheduled maintenance lane now."
    }
  in
  let original : Keeper_event_queue.stimulus =
    { post_id = Schedule_occurrence_id.to_string occurrence_id
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = 201.0
    ; payload = Keeper_event_queue.Schedule_due wake
    }
  in
  (match
     Keeper_registry_event_queue.enqueue_stimulus_durable_result
       ~base_path
       keeper_name
       original
   with
   | Keeper_registry_event_queue.Stimulus_enqueued committed ->
     check (float 0.0)
       "seed returns committed arrival"
       original.arrived_at
       committed.arrived_at
   | Keeper_registry_event_queue.Stimulus_already_present _ ->
     fail "fresh schedule occurrence was already present"
   | Keeper_registry_event_queue.Stimulus_storage_error detail -> fail detail);
  (match
     Server_schedule_consumers.consumer.dispatch
       config
       ~now:202.0
       signal
       request
   with
   | Ok _ -> ()
   | Error _ -> fail "schedule retry dispatch failed");
  let stimulus_id = Keeper_event_queue.stimulus_identity_id original in
  let events =
    match
      Keeper_reaction_store.events_for_stimuli
        ~base_path
        ~keeper_name
        ~stimulus_ids:[ stimulus_id ]
    with
    | Ok [ (returned_id, events) ] ->
      check string "reaction lookup preserves identity" stimulus_id returned_id;
      events
    | Ok _ -> fail "reaction lookup returned an unexpected identity set"
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
  in
  match
    List.find_opt
      (fun (event : Keeper_reaction_store.stored_event) ->
         match event.payload with
         | Keeper_reaction_store.Stored_stimulus _ -> true
         | Keeper_reaction_store.Stored_turn_started _
         | Keeper_reaction_store.Stored_transition_settlement _
         | Keeper_reaction_store.Stored_cursor_ack _ -> false)
      events
  with
  | Some { payload = Keeper_reaction_store.Stored_stimulus stimulus; _ } ->
    check (float 0.0)
      "ledger records the original durable arrival"
      original.arrived_at
      stimulus.arrived_at
  | Some _ -> fail "matched reaction event was not a stimulus"
  | None -> fail "schedule retry did not record its durable stimulus"
;;

let test_acked_occurrence_recovery_does_not_enqueue_or_wake_again () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let entry =
    Keeper_registry.register ~base_path keeper_name (keeper_meta_for_name keeper_name)
  in
  Fun.protect
    ~finally:(fun () -> Keeper_registry.unregister ~base_path keeper_name)
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
         Server_schedule_consumers.consumer.dispatch config ~now:202.0 signal running
       with
       | Ok _ -> ()
       | Error _ -> fail "initial schedule occurrence dispatch failed");
      check bool "initial dispatch wakes lane" true (Atomic.get entry.fiber_wakeup);
      let lease =
        match
          Keeper_registry_event_queue.claim_when_result
            ~base_path
            keeper_name
            ~claimed_at:202.5
            ~ready:(fun _ -> true)
        with
        | Ok (Some lease) -> lease
        | Ok None -> fail "scheduled occurrence was not queued"
        | Error detail -> fail detail
      in
      (match
         Keeper_registry_event_queue.settle_result
           ~base_path
           keeper_name
           ~settled_at:203.0
           ~lease
           ~settlement:Keeper_registry_event_queue.Ack
       with
       | Ok (Keeper_registry_event_queue.Settled _)
       | Ok (Keeper_registry_event_queue.Already_settled _) -> ()
       | Ok _ -> fail "scheduled occurrence settlement follow-up failed"
       | Error detail -> fail detail);
      (match Keeper_heartbeat_loop.project_transition_outbox ~base_path ~keeper_name with
       | Ok () -> ()
       | Error detail -> fail detail);
      (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
       | Some stored ->
         check string "crash window leaves schedule running" "running"
           (Schedule_domain.schedule_status_to_string stored.status)
       | None -> fail "running schedule disappeared before recovery");
      (match Schedule_store.recover_running_on_startup config ~now:204.0 with
       | Ok (_, 1) -> ()
       | Ok (_, recovered) -> failf "expected one recovered schedule, got %d" recovered
       | Error err -> fail (Schedule_store.store_error_to_string err));
      Atomic.set entry.fiber_wakeup false;
      let retried = tick_ok config ~now:205.0 in
      check bool "retry sends no second wake" false (Atomic.get entry.fiber_wakeup);
      (match List.hd retried.dispatches with
       | { detail = Some detail; _ } ->
         check string "retry observes terminal settlement" "already_settled"
           Yojson.Safe.Util.(detail |> member "occurrence_status" |> to_string)
       | _ -> fail "retry completion receipt missing");
      check int "retry enqueues no second occurrence" 0
        (Keeper_registry_event_queue.snapshot ~base_path keeper_name
         |> Keeper_event_queue.length))
;;

let run_terminal_ack_projection_race ~config ~base_path ~keeper_name =
  let request = create_keeper_wake_schedule config in
  let initial = tick_ok config ~now:201.0 in
  let signal =
    match initial.emitted with
    | [ signal ] -> signal
    | signals -> failf "expected one emitted signal, got %d" (List.length signals)
  in
  let lease =
    match
      Keeper_registry_event_queue.claim_when_result
        ~base_path
        keeper_name
        ~claimed_at:202.0
        ~ready:(fun _ -> true)
    with
    | Ok (Some lease) -> lease
    | Ok None -> fail "scheduled occurrence was not queued"
    | Error detail -> fail detail
  in
  let stimulus =
    match Keeper_registry_event_queue.lease_stimuli lease with
    | [ stimulus ] -> stimulus
    | stimuli -> failf "expected one leased stimulus, got %d" (List.length stimuli)
  in
  (match
     Keeper_registry_event_queue.settle_result
       ~base_path
       keeper_name
       ~settled_at:203.0
       ~lease
       ~settlement:Keeper_registry_event_queue.Ack
   with
   | Ok (Keeper_registry_event_queue.Settled _)
   | Ok (Keeper_registry_event_queue.Already_settled _) -> ()
   | Ok _ -> fail "scheduled occurrence settlement follow-up failed"
   | Error detail -> fail detail);
  (match
     Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name
   with
   | Ok [ _ ] -> ()
   | Ok entries -> failf "expected one transition outbox entry, got %d" (List.length entries)
   | Error detail -> fail detail);
  Eio.Switch.run
  @@ fun sw ->
  let retry_read_complete, resolve_retry_read_complete = Eio.Promise.create () in
  let release_retry, resolve_release_retry = Eio.Promise.create () in
  let projection_lock_attempted, resolve_projection_lock_attempted =
    Eio.Promise.create ()
  in
  Server_schedule_consumers.For_testing.with_after_keeper_wake_reaction_read_hook
    (fun () ->
       Eio.Promise.resolve resolve_retry_read_complete ();
       Eio.Promise.await release_retry)
    (fun () ->
       let retry_result =
         Eio.Fiber.fork_promise ~sw (fun () ->
           Server_schedule_consumers.consumer.dispatch
             config
             ~now:204.0
             signal
             request)
       in
       Eio.Promise.await retry_read_complete;
       Keeper_event_queue_persistence.For_testing
       .with_before_reaction_coordination_lock_hook
         (fun () -> Eio.Promise.resolve resolve_projection_lock_attempted ())
         (fun () ->
            let projection_result =
              Eio.Fiber.fork_promise ~sw (fun () ->
                Keeper_reaction_ledger.project_event_queue_transition_outbox_result
                  ~base_path
                  ~keeper_name)
            in
            Eio.Promise.await projection_lock_attempted;
            Eio.Promise.resolve resolve_release_retry ();
            (match Eio.Promise.await retry_result with
             | Ok (Ok _) -> ()
             | Ok
                 (Error
                 (Schedule_runner.Retryable_dispatch_failure detail
                 | Schedule_runner.Terminal_dispatch_rejection detail)) ->
               fail ("concurrent schedule retry failed: " ^ detail)
             | Error exn -> raise exn);
            (match Eio.Promise.await projection_result with
             | Ok (Ok ()) -> ()
             | Ok (Error error) ->
               fail
                 ("concurrent transition projection failed: "
                  ^ Keeper_reaction_ledger.ledger_error_to_string error)
             | Error exn -> raise exn)));
  check int
    "terminal ACK is not resurrected as pending"
    0
    (Keeper_registry_event_queue.snapshot ~base_path keeper_name
     |> Keeper_event_queue.length);
  (match
     Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name
   with
   | Ok [] -> ()
   | Ok entries -> failf "projected outbox retained %d entries" (List.length entries)
   | Error detail -> fail detail);
  let stimulus_id = Keeper_event_queue.stimulus_identity_id stimulus in
  (match
     Keeper_reaction_ledger.event_queue_reaction_evidence_result
       ~base_path
       ~keeper_name
       ~stimulus_id
   with
   | Ok { latest_reaction = Some (Keeper_reaction_ledger.Latest_event_queue_ack _); _ }
     -> ()
   | Ok _ -> fail "terminal ACK was not the causally latest reaction"
   | Error error ->
     fail
       (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error))
;;

let test_terminal_ack_projection_cannot_resurrect_pending_retry () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  ignore
    (Keeper_registry.register ~base_path keeper_name (keeper_meta_for_name keeper_name));
  Fun.protect
    ~finally:(fun () -> Keeper_registry.unregister ~base_path keeper_name)
    (fun () -> run_terminal_ack_projection_race ~config ~base_path ~keeper_name)
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
      (queue_evidence |> member "pending_count" |> to_int);
    check int "queue evidence inflight count" 0
      (queue_evidence |> member "inflight_count" |> to_int)
;;

let test_dashboard_live_supported_non_terminal_evidence_matches_supported_request () =
  with_workspace
  @@ fun config ->
  let request = create_keeper_wake_schedule config in
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let request_projection = dashboard |> member "request_projection" in
  check int "one returned schedule row" 1
    (request_projection |> member "returned_count" |> to_int);
  check int "one exact schedule row" 1
    (request_projection |> member "total_count" |> to_int);
  check int "request projection limit is backend-authored" 20
    (request_projection |> member "limit" |> to_int);
  check bool "request projection is complete" false
    (request_projection |> member "truncated" |> to_bool);
  check bool "removed request_count field is absent" true
    (dashboard |> member "request_count" = `Null);
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

let test_keeper_wake_dashboard_tracks_runtime_inflight_lease () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let meta = keeper_meta_for_name keeper_name in
  let (_entry : Keeper_registry.registry_entry) =
    Keeper_registry.register ~base_path:config.Workspace_utils.base_path keeper_name meta
  in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.unregister ~base_path:config.Workspace_utils.base_path keeper_name)
    (fun () ->
      let request = create_keeper_wake_schedule config in
      let result = tick_ok config ~now:201.0 in
      let occurrence_id = single_occurrence_id result in
      check int "one dispatch" 1 (List.length result.dispatches);
      check string "dispatch status" "succeeded"
        (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
      let pending_row =
        Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
        |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
      in
      let open Yojson.Safe.Util in
      let pending_evidence = pending_row |> member "keeper_queue_evidence" in
      check string "pending evidence matched" "matched_pending"
        (pending_evidence |> member "projection_status" |> to_string);
      check string "pending matched bucket" "pending"
        (pending_evidence |> member "matched_bucket" |> to_string);
      check int "pending count before lease" 1
        (pending_evidence |> member "pending_count" |> to_int);
      check int "inflight count before lease" 0
        (pending_evidence |> member "inflight_count" |> to_int);
      let pending_receipt = pending_row |> member "dispatch_receipt" in
      let stimulus_id = pending_receipt |> member "stimulus_id" |> to_string in
      let pending_reaction_evidence =
        pending_row |> member "keeper_reaction_evidence"
      in
      check string "reaction evidence sees queued stimulus" "matched_stimulus"
        (pending_reaction_evidence |> member "projection_status" |> to_string);
      check string "reaction evidence source" "keeper_reaction_ledger"
        (pending_reaction_evidence |> member "source" |> to_string);
      check string "reaction evidence stimulus id" stimulus_id
        (pending_reaction_evidence |> member "stimulus_id" |> to_string);
      check bool "reaction evidence stimulus seen" true
        (pending_reaction_evidence |> member "stimulus_seen" |> to_bool);
      check bool "reaction evidence turn not started yet" false
        (pending_reaction_evidence |> member "turn_started_seen" |> to_bool);
      check bool "queued stimulus has no fabricated latest reaction" true
        (pending_reaction_evidence |> member "latest_reaction" = `Null);
      check int "one matched ledger row before turn" 1
        (pending_reaction_evidence |> member "matched_record_count" |> to_int);
      let lease, leased =
        match
          Keeper_registry_event_queue.claim_when_result
            ~base_path:config.Workspace_utils.base_path
            keeper_name
            ~claimed_at:(Time_compat.now ())
            ~ready:(fun _ -> true)
        with
        | Error error -> fail ("scheduled wake claim failed: " ^ error)
        | Ok None -> fail "registered keeper should lease the scheduled wake"
        | Ok (Some lease) ->
          (match Keeper_registry_event_queue.lease_stimuli lease with
           | [ stimulus ] -> lease, stimulus
           | [] | _ :: _ :: _ -> fail "scheduled wake lease cardinality drifted")
      in
      check string "leased occurrence id" occurrence_id leased.post_id;
      check string "receipt uses canonical queue identity"
        (Keeper_event_queue.stimulus_identity_id leased)
        stimulus_id;
      (match leased.payload with
       | Keeper_event_queue.Schedule_due wake ->
         check string "leased schedule id" request.schedule_id wake.schedule_id
       | _ -> fail "registered keeper leased a non-schedule payload");
      let inflight_row =
        Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
        |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
      in
      let inflight_evidence = inflight_row |> member "keeper_queue_evidence" in
      check string "inflight evidence matched" "matched_inflight"
        (inflight_evidence |> member "projection_status" |> to_string);
      check string "inflight source" "durable_event_queue_snapshot"
        (inflight_evidence |> member "source" |> to_string);
      check string "inflight matched bucket" "inflight"
        (inflight_evidence |> member "matched_bucket" |> to_string);
      check string "inflight matched payload" "schedule_due"
        (inflight_evidence |> member "matched_payload_kind" |> to_string);
      check string "inflight matched schedule" request.schedule_id
        (inflight_evidence |> member "matched_schedule_id" |> to_string);
      check int "pending count after lease" 0
        (inflight_evidence |> member "pending_count" |> to_int);
      check int "inflight count after lease" 1
        (inflight_evidence |> member "inflight_count" |> to_int);
      Keeper_reaction_ledger.record_event_queue_turn_started_result
        ~base_path:config.Workspace_utils.base_path
        ~keeper_name
        ~lease_sequence:(Keeper_registry_event_queue.lease_sequence lease)
        leased
      |> require_reaction_ledger_write "record scheduled wake turn start";
      let reacted_row =
        Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
        |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
      in
      let reaction_evidence = reacted_row |> member "keeper_reaction_evidence" in
      check string "reaction evidence matched turn" "matched_turn_started"
        (reaction_evidence |> member "projection_status" |> to_string);
      check bool "reaction evidence turn started" true
        (reaction_evidence |> member "turn_started_seen" |> to_bool);
      check string "reaction evidence kind comes from turn evidence" "turn_started"
        (reaction_evidence |> member "latest_reaction" |> member "kind" |> to_string);
      check int "two matched ledger rows after turn" 2
        (reaction_evidence |> member "matched_record_count" |> to_int);
      (match
         Keeper_registry_event_queue.settle_result
           ~base_path:config.Workspace_utils.base_path
           keeper_name
           ~settled_at:(Time_compat.now ())
           ~lease
           ~settlement:Keeper_registry_event_queue.Ack
       with
       | Error error -> fail ("scheduled wake settlement failed: " ^ error)
       | Ok (Keeper_registry_event_queue.Settled _)
       | Ok (Keeper_registry_event_queue.Already_settled _) -> ()
       | Ok _ -> fail "scheduled wake settlement follow-up failed");
      Keeper_reaction_ledger.project_event_queue_transition_outbox_result
        ~base_path:config.Workspace_utils.base_path
        ~keeper_name
      |> require_reaction_ledger_write "project scheduled wake transition";
      let acked_row =
        Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
        |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
      in
      let acked_queue_evidence = acked_row |> member "keeper_queue_evidence" in
      check string "acked queue evidence drained" "not_found"
        (acked_queue_evidence |> member "projection_status" |> to_string);
      check int "pending count after ack" 0
        (acked_queue_evidence |> member "pending_count" |> to_int);
      check int "inflight count after ack" 0
        (acked_queue_evidence |> member "inflight_count" |> to_int);
      let acked_reaction_evidence = acked_row |> member "keeper_reaction_evidence" in
      check string "reaction evidence matched ack" "matched_consumed_ack"
        (acked_reaction_evidence |> member "projection_status" |> to_string);
      check bool "reaction evidence event queue acked" true
        (acked_reaction_evidence |> member "event_queue_ack_seen" |> to_bool);
      check string "reaction evidence kind prefers consumed ack" "event_queue_ack"
        (acked_reaction_evidence |> member "latest_reaction" |> member "kind" |> to_string);
      check int "three matched ledger rows after ack" 3
        (acked_reaction_evidence |> member "matched_record_count" |> to_int))
;;

let test_keeper_wake_ledger_failure_is_retryable () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  replace_reaction_ledger_with_directory ~base_path ~keeper_name;
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

let test_invalid_sqlite_store_is_keeper_local_and_retryable () =
  with_workspace
  @@ fun config ->
  let base_path = config.Workspace_utils.base_path in
  let blocked_keeper = "invalid-sqlite-keeper" in
  let healthy_keeper = "healthy-sqlite-keeper" in
  replace_reaction_ledger_with_directory ~base_path ~keeper_name:blocked_keeper;
  let blocked =
    create_named_keeper_wake_schedule
      config
      ~schedule_id:"invalid-sqlite-schedule"
      ~keeper_name:blocked_keeper
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
  let blocked_dispatch = dispatch blocked.schedule_id in
  let healthy_dispatch = dispatch healthy.schedule_id in
  check string
    "invalid SQLite occurrence remains retryable"
    "failed"
    (Schedule_runner.dispatch_status_to_string blocked_dispatch.status);
  (match blocked_dispatch.error with
   | Some detail ->
     check bool
       "typed SQLite write failure is explicit"
       true
       (String.trim detail <> "")
   | None -> fail "invalid SQLite occurrence error missing");
  check string
    "other keeper lane continues"
    "succeeded"
    (Schedule_runner.dispatch_status_to_string healthy_dispatch.status);
  (match Schedule_store.get_schedule config ~schedule_id:blocked.schedule_id with
   | Some stored ->
     check string
       "blocked occurrence stays due"
       "due"
       (Schedule_domain.schedule_status_to_string stored.status)
   | None -> fail "blocked schedule missing");
  check int
    "blocked occurrence was not enqueued"
    0
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot ~base_path blocked_keeper));
  check int
    "healthy keeper received its own occurrence"
    1
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot ~base_path healthy_keeper))
;;

let test_missing_sqlite_store_is_exact_empty_evidence () =
  with_workspace
  @@ fun config ->
  let keeper_name = "empty-sqlite-keeper" in
  let stimulus_id = "missing-sqlite-stimulus" in
  let evidence =
    match
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path:config.Workspace_utils.base_path
        ~keeper_name
        ~stimulus_id
    with
    | Ok evidence -> evidence
    | Error error ->
      fail
        ("absent reaction store read failed: "
         ^ Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string
             error)
  in
  check string "evidence preserves keeper identity" keeper_name evidence.keeper_name;
  check string "evidence preserves stimulus identity" stimulus_id evidence.stimulus_id;
  check bool "absent store has no stimulus evidence" false evidence.stimulus_seen;
  check bool "absent store has no turn evidence" false evidence.turn_started_seen;
  check bool "absent store has no ack evidence" false evidence.event_queue_ack_seen;
  check int "absent store has no matched records" 0 evidence.matched_record_count;
  let database_path =
    reaction_ledger_path_exn
      ~base_path:config.Workspace_utils.base_path
      ~keeper_name
  in
  check bool "read does not create the absent SQLite database" false
    (Sys.file_exists database_path)
;;

let test_dashboard_distinguishes_missing_and_unreadable_sqlite_evidence () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_keeper_wake_schedule config in
  let result = tick_ok config ~now:201.0 in
  let _stimulus_id = single_occurrence_id result in
  let evidence () =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
    |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
    |> Yojson.Safe.Util.member "keeper_reaction_evidence"
  in
  let open Yojson.Safe.Util in
  let matched = evidence () in
  check string
    "initial typed SQLite evidence matches stimulus"
    "matched_stimulus"
    (matched |> member "projection_status" |> to_string);
  let database_path = reaction_ledger_path_exn ~base_path ~keeper_name in
  rm_rf database_path;
  let missing = evidence () in
  check string
    "missing SQLite database is exact empty evidence"
    "not_found"
    (missing |> member "projection_status" |> to_string);
  check int "missing SQLite database has no matched rows" 0
    (missing |> member "matched_record_count" |> to_int);
  check bool "missing evidence has no latest reaction" true
    (missing |> member "latest_reaction" = `Null);
  mkdir_p database_path;
  let unreadable = evidence () in
  check string
    "storage failure is not projected as empty evidence"
    "read_error"
    (unreadable |> member "projection_status" |> to_string);
  check bool
    "storage failure reason is explicit"
    true
    (unreadable |> member "reason" |> to_string |> String.length > 0);
  check bool "typed read failure has no latest reaction" true
    (unreadable |> member "latest_reaction" = `Null)
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

let () =
  run "Schedule_consumer_dispatch"
    [ ( "keeper_wake"
      , [ test_case "board post schedule is rejected without mutation" `Quick
            test_board_post_schedule_is_rejected_without_mutation
        ; test_case "keeper wake enqueues typed stimulus" `Quick
            test_keeper_wake_consumer_enqueues_typed_stimulus_and_succeeds_schedule
        ; test_case "recurring wakes keep distinct occurrence ids" `Quick
            test_recurring_wakes_keep_distinct_occurrence_ids
        ; test_case "keeper wake durable enqueue retries same occurrence" `Quick
            test_keeper_wake_durable_enqueue_failure_retries_same_occurrence
        ; test_case "keeper wake retry records committed arrival" `Quick
            test_keeper_wake_retry_records_committed_arrival
        ; test_case "acked occurrence recovery does not enqueue or wake again" `Quick
            test_acked_occurrence_recovery_does_not_enqueue_or_wake_again
        ; test_case "terminal ACK projection cannot resurrect pending retry" `Quick
            test_terminal_ack_projection_cannot_resurrect_pending_retry
        ; test_case "keeper wake queue evidence rejects stale occurrence" `Quick
            test_keeper_wake_queue_evidence_rejects_stale_occurrence
        ; test_case "dashboard live supported non-terminal evidence matches supported request"
            `Quick
            test_dashboard_live_supported_non_terminal_evidence_matches_supported_request
        ; test_case "dashboard live supported non-terminal evidence reports absent supported payloads"
            `Quick
            test_dashboard_live_supported_non_terminal_evidence_reports_absent_supported_payloads
        ; test_case "keeper wake dashboard tracks runtime inflight lease" `Quick
            test_keeper_wake_dashboard_tracks_runtime_inflight_lease
        ; test_case "keeper wake ledger failure is retryable" `Quick
            test_keeper_wake_ledger_failure_is_retryable
        ; test_case "invalid SQLite store is keeper-local and retryable" `Quick
            test_invalid_sqlite_store_is_keeper_local_and_retryable
        ; test_case "missing SQLite store is exact empty evidence" `Quick
            test_missing_sqlite_store_is_exact_empty_evidence
        ; test_case "dashboard distinguishes missing and unreadable SQLite evidence"
            `Quick
            test_dashboard_distinguishes_missing_and_unreadable_sqlite_evidence
        ; test_case "keeper wake rejects invalid keeper name" `Quick
            test_keeper_wake_consumer_rejects_invalid_keeper_name
        ] )
    ]
;;
