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
      (receipt |> member "post_id" |> to_string)
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
       (Some "keeper_name must match [A-Za-z0-9._-]+")
       execution.error);
  check int "invalid keeper wake does not enqueue" 0
    (Keeper_event_queue.length
       (Keeper_registry_event_queue.snapshot
          ~base_path:config.Workspace_utils.base_path
          "../bad"))
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
        ; test_case "keeper wake rejects invalid keeper name" `Quick
            test_keeper_wake_consumer_rejects_invalid_keeper_name
        ; test_case "dashboard resolve uses authenticated operator" `Quick
            test_dashboard_schedule_resolve_uses_authenticated_operator
        ] )
    ]
;;
