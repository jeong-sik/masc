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

let write_empty_file path =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> ())
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
        ; "tool_access", `List []
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

let keeper_wake_payload =
  `Assoc
    [ "kind", `String "masc.keeper_wake"
    ; "schema_version", `Int 1
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String "schedule-keeper"
          ; "title", `String "Scheduled lane wake"
          ; "message", `String "Run the scheduled maintenance lane now."
          ; "urgency", `String "immediate"
          ] )
    ]
;;

let unsupported_payload =
  `Assoc
    [ "kind", `String "legacy.unsupported_scheduler_payload"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "message", `String "This payload is not in the schedule consumer catalog." ]
    ]
;;

let create_pending_board_schedule config =
  match
    Schedule_service.create config ~schedule_id:"board-sched-1"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:board_post_payload ~risk_class:Schedule_domain.Workspace_write
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_pending_keeper_wake_schedule config =
  match
    Schedule_service.create config ~schedule_id:"keeper-wake-sched-1"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:keeper_wake_payload ~risk_class:Schedule_domain.Workspace_write
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_pending_unsupported_schedule config =
  match
    Schedule_service.create config ~schedule_id:"unsupported-live-sched"
      ~requested_at:100.0 ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
      ~payload:unsupported_payload ~risk_class:Schedule_domain.Read_only
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let create_pending_invalid_keeper_wake_schedule config =
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
      ~payload ~risk_class:Schedule_domain.Workspace_write
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("create failed: " ^ Schedule_service.service_error_to_string err)
;;

let approve_schedule config (request : Schedule_domain.schedule_request) =
  match
    Schedule_service.approve config ~schedule_id:request.Schedule_domain.schedule_id
      ~approved_by:(human "approver") ()
  with
  | Ok request -> request
  | Error err ->
    fail ("approve failed: " ^ Schedule_service.service_error_to_string err)
;;

let tick_ok config ~now =
  match
    Schedule_runner.tick ~consumer:Server_schedule_consumers.consumer config ~now
  with
  | Ok result -> result
  | Error err -> fail (Schedule_runner.runner_error_to_string err)
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

let test_board_post_consumer_creates_post_and_succeeds_schedule () =
  with_workspace
  @@ fun config ->
  let request = create_pending_board_schedule config in
  check string "initial status" "pending_approval"
    (Schedule_domain.schedule_status_to_string request.status);
  ignore (approve_schedule config request : Schedule_domain.schedule_request);
  let result = tick_ok config ~now:201.0 in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch status" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule succeeded" "succeeded"
       (Schedule_domain.schedule_status_to_string stored.status));
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
        check string "execution detail kind" "masc.board_post.created"
          (detail |> member "kind" |> to_string)
      | None -> fail "execution detail missing"));
  match Board_dispatch.list_posts ~hearth:"ops" ~limit:10 () with
  | [ post ] ->
    check string "title" "Scheduled check-in" post.Board.title;
    check string "content" "Daily schedule fired" post.content;
    check string "author" "schedule-bot" (Board.Agent_id.to_string post.author);
    (match post.meta_json with
     | Some meta ->
       let open Yojson.Safe.Util in
       check string "meta source" "scheduled_automation"
         (meta |> member "source" |> to_string);
       check string "meta schedule" request.schedule_id
         (meta |> member "schedule_id" |> to_string);
       check string "payload meta" "test"
         (meta |> member "payload_meta" |> member "purpose" |> to_string)
     | None -> fail "expected schedule meta")
  | posts -> failf "expected one board post, got %d" (List.length posts)
;;

let test_board_post_consumer_rejects_read_only_risk () =
  with_workspace
  @@ fun config ->
  let request =
    match
      Schedule_service.create config ~schedule_id:"board-read-only"
        ~requested_at:100.0 ~requested_by:(human "operator")
        ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
        ~payload:board_post_payload ~risk_class:Schedule_domain.Read_only
        ~source:Schedule_domain.Operator_request ()
    with
    | Ok request -> request
    | Error err ->
      fail ("create failed: " ^ Schedule_service.service_error_to_string err)
  in
  let result = tick_ok config ~now:201.0 in
  check int "one unsupported decision" 1 (List.length result.dispatches);
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
       (Some "masc.board_post requires a side-effecting risk_class")
       execution.error);
  check int "no post" 0 (List.length (Board_dispatch.list_posts ~limit:10 ()))
;;

let test_keeper_wake_consumer_enqueues_typed_stimulus_and_succeeds_schedule () =
  with_workspace
  @@ fun config ->
  let request = create_pending_keeper_wake_schedule config in
  ignore (approve_schedule config request : Schedule_domain.schedule_request);
  let result = tick_ok config ~now:201.0 in
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
     check string "post id" "schedule-due:keeper-wake-sched-1" stimulus.post_id;
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
    check string "receipt post id" "schedule-due:keeper-wake-sched-1"
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

let test_keeper_wake_queue_evidence_rejects_stale_occurrence () =
  with_workspace
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace_utils.base_path in
  let request = create_pending_keeper_wake_schedule config in
  ignore (approve_schedule config request : Schedule_domain.schedule_request);
  ignore (tick_ok config ~now:201.0 : Schedule_runner.tick_result);
  let expected_wake : Keeper_event_queue.scheduled_wake =
    { schedule_id = request.schedule_id
    ; due_at = request.due_at
    ; payload_digest = Schedule_domain.payload_digest request.payload
    ; title = Some "Scheduled lane wake"
    ; message = "Run the scheduled maintenance lane now."
    }
  in
  let post_id = Keeper_event_queue.schedule_due_post_id expected_wake in
  (match Keeper_registry_event_queue.drop_by_post_id ~base_path keeper_name ~post_id with
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
    { post_id = Keeper_event_queue.schedule_due_post_id stale_wake
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
  let request = create_pending_keeper_wake_schedule config in
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
  ignore (create_pending_unsupported_schedule config : Schedule_domain.schedule_request);
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
      let request = create_pending_keeper_wake_schedule config in
      ignore (approve_schedule config request : Schedule_domain.schedule_request);
      let result = tick_ok config ~now:201.0 in
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
      check bool "dispatch receipt includes stimulus id" true
        (String.starts_with ~prefix:"stimulus:" stimulus_id);
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
      check int "one matched ledger row before turn" 1
        (pending_reaction_evidence |> member "matched_record_count" |> to_int);
      let leased =
        match
          Keeper_registry_event_queue.dequeue
            ~base_path:config.Workspace_utils.base_path
            keeper_name
        with
        | Some stimulus -> stimulus
        | None -> fail "registered keeper should lease the scheduled wake"
      in
      check string "leased post id" "schedule-due:keeper-wake-sched-1" leased.post_id;
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
      Keeper_reaction_ledger.record_event_queue_reaction
        ~base_path:config.Workspace_utils.base_path
        ~keeper_name
        ~reaction_kind:Keeper_reaction_ledger.Turn_started
        leased;
      let reacted_row =
        Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
        |> dashboard_schedule_row_exn ~schedule_id:request.schedule_id
      in
      let reaction_evidence = reacted_row |> member "keeper_reaction_evidence" in
      check string "reaction evidence matched turn" "matched_turn_started"
        (reaction_evidence |> member "projection_status" |> to_string);
      check bool "reaction evidence turn started" true
        (reaction_evidence |> member "turn_started_seen" |> to_bool);
      check int "two matched ledger rows after turn" 2
        (reaction_evidence |> member "matched_record_count" |> to_int);
      (match
         Keeper_registry_event_queue.ack_consumed_result
           ~base_path:config.Workspace_utils.base_path
           keeper_name
           [ leased ]
       with
       | Ok () -> ()
       | Error msg -> fail ("scheduled wake ack failed: " ^ msg));
      Keeper_reaction_ledger.record_event_queue_reaction
        ~base_path:config.Workspace_utils.base_path
        ~keeper_name
        ~reaction_kind:Keeper_reaction_ledger.Event_queue_ack
        leased;
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
      check int "three matched ledger rows after ack" 3
        (acked_reaction_evidence |> member "matched_record_count" |> to_int))
;;

let test_keeper_wake_ledger_failure_keeps_dispatch_success_visible () =
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
  write_empty_file (Filename.concat keeper_dir "reaction-ledger");
  let request = create_pending_keeper_wake_schedule config in
  ignore (approve_schedule config request : Schedule_domain.schedule_request);
  let result = tick_ok config ~now:201.0 in
  check int "one dispatch" 1 (List.length result.dispatches);
  check string "dispatch status stays succeeded" "succeeded"
    (Schedule_runner.dispatch_status_to_string (List.hd result.dispatches).status);
  let runner_status = runner_status_json_after_dispatches result in
  let runner_counts =
    Yojson.Safe.Util.(runner_status |> member "last_counts")
  in
  check string "ledger failure degrades runner health" "degraded"
    Yojson.Safe.Util.(runner_status |> member "status" |> to_string);
  check int "ledger failure still counts wake enqueue" 1
    Yojson.Safe.Util.(runner_counts |> member "wake_enqueued" |> to_int);
  check int "ledger failure increments wake failure" 1
    Yojson.Safe.Util.(runner_counts |> member "wake_failed" |> to_int);
  (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
   | None -> fail "schedule missing"
   | Some stored ->
     check string "schedule succeeded" "succeeded"
       (Schedule_domain.schedule_status_to_string stored.status));
  check int "wake remains durably queued" 1
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot ~base_path keeper_name));
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row = dashboard_schedule_row_exn dashboard ~schedule_id:request.schedule_id in
  let receipt = row |> member "dispatch_receipt" in
  check string "receipt recognized" "recognized"
    (receipt |> member "projection_status" |> to_string);
  check string "ledger failure visible" "record_failed"
    (receipt |> member "reaction_ledger_status" |> to_string);
  check bool "ledger failure reason visible" true
    (String.length (receipt |> member "reaction_ledger_error" |> to_string) > 0);
  let queue_evidence = row |> member "keeper_queue_evidence" in
  check string "queue evidence still matched" "matched_pending"
    (queue_evidence |> member "projection_status" |> to_string);
  let reaction_evidence = row |> member "keeper_reaction_evidence" in
  check string "reaction ledger miss visible" "not_found"
    (reaction_evidence |> member "projection_status" |> to_string)
;;

let test_keeper_wake_consumer_rejects_invalid_keeper_name () =
  with_workspace
  @@ fun config ->
  let request = create_pending_invalid_keeper_wake_schedule config in
  ignore (approve_schedule config request : Schedule_domain.schedule_request);
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

let test_dashboard_schedule_resolve_uses_authenticated_operator () =
  with_workspace
  @@ fun config ->
  let request = create_pending_board_schedule config in
  let args =
    `Assoc
      [ "schedule_id", `String request.schedule_id
      ; "decision", `String "approve"
      ; "approved_by_id", `String "attacker"
      ]
    in
    match
      Server_dashboard_http.dashboard_schedule_resolve_http_json
        ~config ~operator_name:"dashboard-admin" ~args
    with
  | Error message -> fail message
  | Ok json ->
    let open Yojson.Safe.Util in
    let approved_by_id = json |> member "approved_by" |> member "id" |> to_string in
    check string "response approver is token-bound actor" "dashboard-admin"
      approved_by_id;
    check bool "body spoofed approver ignored" true
      (not (String.equal approved_by_id "attacker"));
    (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
     | None -> fail "schedule missing"
     | Some stored ->
       check string "schedule moved to scheduled" "scheduled"
         (Schedule_domain.schedule_status_to_string stored.status))
;;

let () =
  run "Schedule_consumer_dispatch"
    [ ( "board_post"
      , [ test_case "creates board post and succeeds schedule" `Quick
            test_board_post_consumer_creates_post_and_succeeds_schedule
        ; test_case "rejects read-only risk" `Quick
            test_board_post_consumer_rejects_read_only_risk
        ; test_case "keeper wake enqueues typed stimulus" `Quick
            test_keeper_wake_consumer_enqueues_typed_stimulus_and_succeeds_schedule
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
        ; test_case "keeper wake ledger failure keeps dispatch success visible" `Quick
            test_keeper_wake_ledger_failure_keeps_dispatch_success_visible
        ; test_case "keeper wake rejects invalid keeper name" `Quick
            test_keeper_wake_consumer_rejects_invalid_keeper_name
        ; test_case "dashboard resolve uses authenticated operator" `Quick
            test_dashboard_schedule_resolve_uses_authenticated_operator
        ] )
    ]
;;
