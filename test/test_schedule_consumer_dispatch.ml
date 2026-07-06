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
  match rm dir with
  | () -> ()
  | exception Sys_error msg -> fail ("rm_rf failed: " ^ msg)
  | exception Unix.Unix_error (err, fn, arg) ->
    fail
      (Printf.sprintf
         "rm_rf failed: %s %s %s"
         fn
         arg
         (Unix.error_message err))
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

let unsupported_payload =
  `Assoc
    [ "kind", `String "masc.unsupported_fixture"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "purpose", `String "unsupported-dispatch-test" ]
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

let metric_value name ~labels =
  Otel_metric_store.metric_value_or_zero name ~labels ()
;;

let unsupported_payload_metric_labels ~phase ~risk_class =
  [ "phase", phase
  ; "risk_class", Schedule_domain.risk_class_to_string risk_class
  ]
;;

let check_metric_delta label name ~labels ~before ~delta =
  let after = metric_value name ~labels in
  check (float 0.000001) label (before +. delta) after
;;

let attr_string key attrs =
  List.find_map
    (fun (name, value) ->
       if String.equal name key
       then
         match value with
         | `String value -> Some value
         | _ -> None
       else None)
    attrs
;;

let attr_batches_string key batches =
  List.find_map (attr_string key) batches
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
  let due_lag_labels =
    [ "kind", Schedule_runner.signal_kind_to_string Schedule_runner.Due_candidate
    ; "risk_class", Schedule_domain.risk_class_to_string Schedule_domain.Workspace_write
    ]
  in
  let dispatch_labels = [ "status", "succeeded" ] in
  let due_lag_count_before =
    metric_value
      (Otel_metric_store.metric_schedule_runner_due_lag_seconds ^ "_count")
      ~labels:due_lag_labels
  in
  let dispatch_duration_count_before =
    metric_value
      (Otel_metric_store.metric_schedule_runner_dispatch_duration_seconds ^ "_count")
      ~labels:dispatch_labels
  in
  let dispatch_total_before =
    metric_value
      Otel_metric_store.metric_schedule_runner_dispatch_total
      ~labels:dispatch_labels
  in
  Server_bootstrap_maintenance.For_testing.record_schedule_runner_due_lag_metrics
    result.emitted;
  Server_bootstrap_maintenance.For_testing.record_schedule_runner_dispatch_metrics
    result.dispatches;
  check_metric_delta "due lag metric count"
    (Otel_metric_store.metric_schedule_runner_due_lag_seconds ^ "_count")
    ~labels:due_lag_labels
    ~before:due_lag_count_before
    ~delta:1.0;
  check_metric_delta "dispatch duration metric count"
    (Otel_metric_store.metric_schedule_runner_dispatch_duration_seconds ^ "_count")
    ~labels:dispatch_labels
    ~before:dispatch_duration_count_before
    ~delta:1.0;
  check_metric_delta "dispatch total metric"
    Otel_metric_store.metric_schedule_runner_dispatch_total
    ~labels:dispatch_labels
    ~before:dispatch_total_before
    ~delta:1.0;
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
  let risk_class = Schedule_domain.Read_only in
  let labels = unsupported_payload_metric_labels ~phase:"dispatch" ~risk_class in
  let before =
    metric_value Otel_metric_store.metric_schedule_payload_unsupported_total ~labels
  in
  let request =
    match
      Schedule_service.create config ~schedule_id:"board-read-only"
        ~requested_at:100.0 ~requested_by:(human "operator")
        ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
        ~payload:board_post_payload ~risk_class
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
  check int "no post" 0 (List.length (Board_dispatch.list_posts ~limit:10 ()));
  check_metric_delta "invalid supported dispatch is not unsupported metric"
    Otel_metric_store.metric_schedule_payload_unsupported_total
    ~labels
    ~before
    ~delta:0.0
;;

let test_unknown_payload_dispatch_increments_unsupported_metric () =
  with_workspace
  @@ fun config ->
  let risk_class = Schedule_domain.Workspace_write in
  let labels = unsupported_payload_metric_labels ~phase:"dispatch" ~risk_class in
  let before =
    metric_value Otel_metric_store.metric_schedule_payload_unsupported_total ~labels
  in
  let request =
    match
      Schedule_service.create config ~schedule_id:"unsupported-kind"
        ~requested_at:100.0 ~requested_by:(human "operator")
        ~scheduled_by:(automated "scheduler-agent") ~due_at:200.0
        ~payload:unsupported_payload ~risk_class
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
  (match
     Schedule_store.last_execution_for_schedule (Schedule_store.read_state config)
       ~schedule_id:request.schedule_id
   with
   | None -> fail "missing unsupported execution"
   | Some execution ->
     check (option string) "execution error"
       (Some "unsupported schedule payload kind: masc.unsupported_fixture")
       execution.error);
  check_metric_delta "unsupported dispatch metric increments"
    Otel_metric_store.metric_schedule_payload_unsupported_total
    ~labels
    ~before
    ~delta:1.0
;;

let test_schedule_dispatch_span_wrapper_records_error () =
  with_workspace
  @@ fun config ->
  let request = create_pending_board_schedule config in
  let events = ref [] in
  let attr_batches = ref [] in
  let result =
    Otel_spans.with_test_event_emitter
      ~enabled:true
      ~emit_event:(fun ~name ~attrs -> events := (name, attrs) :: !events)
      ~emit_attrs:(fun ~attrs -> attr_batches := attrs :: !attr_batches)
      (fun () ->
         Server_bootstrap_maintenance.For_testing.schedule_dispatch_wrapper
           request
           (fun () ->
              { Schedule_runner.schedule_id = request.schedule_id
              ; status = Schedule_runner.Dispatch_failed
              ; detail = None
              ; error = Some "dispatch boom"
              ; duration_sec = 0.0
              }))
  in
  check string "wrapped schedule id" request.schedule_id result.schedule_id;
  check string "wrapped dispatch status" "failed"
    (Schedule_runner.dispatch_status_to_string result.status);
  check (option string) "span result status attr" (Some "failed")
    (attr_batches_string "schedule.dispatch.status" !attr_batches);
  check (option string) "span error type attr"
    (Some "schedule_dispatch.failed")
    (attr_batches_string "error.type" !attr_batches);
  match !events with
  | [ event_name, attrs ] ->
    check string "exception event name" "gen_ai.client.operation.exception" event_name;
    check (option string) "exception message" (Some "dispatch boom")
      (attr_string "exception.message" attrs);
    check (option string) "exception type" (Some "schedule_dispatch.failed")
      (attr_string "exception.type" attrs)
  | events ->
    failf "expected one schedule dispatch error event, got %d" (List.length events)
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

let test_dashboard_schedule_cancel_uses_authenticated_operator_and_reason () =
  with_workspace
  @@ fun config ->
  let request = create_pending_board_schedule config in
  let args =
    `Assoc
      [ "schedule_id", `String request.schedule_id
      ; "decision", `String "cancel"
      ; "cancelled_by_id", `String "attacker"
      ; "reason", `String "operator requested cancellation"
      ]
  in
  match
    Server_dashboard_http.dashboard_schedule_resolve_http_json
      ~config ~operator_name:"dashboard-admin" ~args
  with
  | Error message -> fail message
  | Ok json ->
    let open Yojson.Safe.Util in
    let cancelled_by_id = json |> member "cancelled_by" |> member "id" |> to_string in
    check string "response canceller is token-bound actor" "dashboard-admin"
      cancelled_by_id;
    check bool "body spoofed canceller ignored" true
      (not (String.equal cancelled_by_id "attacker"));
    check string "decision" "cancel" (json |> member "decision" |> to_string);
    check string "reason echoed" "operator requested cancellation"
      (json |> member "reason" |> to_string);
    (match Schedule_store.get_schedule config ~schedule_id:request.schedule_id with
     | None -> fail "schedule missing"
     | Some stored ->
       check string "schedule moved to cancelled" "cancelled"
         (Schedule_domain.schedule_status_to_string stored.status));
    (match
       Schedule_audit_log.read_recent_for_schedule
         config
         ~schedule_id:request.schedule_id
         ~limit:1
     with
     | Error message -> fail message
     | Ok [ event ] ->
       check string "cancel audit action" "request_cancelled"
         (Schedule_audit_log.action_to_string event.action);
       check string "cancel audit actor is token-bound" "dashboard-admin"
         (match event.actor with
          | Some actor -> actor.id
          | None -> "");
       (match event.detail with
        | Some (`Assoc fields) ->
          (match List.assoc_opt "reason" fields with
           | Some (`String reason) ->
             check string "cancel audit reason" "operator requested cancellation" reason
           | _ -> fail "cancel audit reason missing")
        | _ -> fail "cancel audit detail missing")
     | Ok events -> failf "expected one cancel audit event, got %d" (List.length events))
;;

let () =
  run "Schedule_consumer_dispatch"
    [ ( "board_post"
      , [ test_case "creates board post and succeeds schedule" `Quick
            test_board_post_consumer_creates_post_and_succeeds_schedule
        ; test_case "rejects read-only risk" `Quick
            test_board_post_consumer_rejects_read_only_risk
        ; test_case "unknown payload dispatch increments unsupported metric" `Quick
            test_unknown_payload_dispatch_increments_unsupported_metric
        ; test_case "schedule dispatch span wrapper records error" `Quick
            test_schedule_dispatch_span_wrapper_records_error
        ; test_case "dashboard resolve uses authenticated operator" `Quick
            test_dashboard_schedule_resolve_uses_authenticated_operator
        ; test_case "dashboard cancel uses authenticated operator and reason" `Quick
            test_dashboard_schedule_cancel_uses_authenticated_operator_and_reason
        ] )
    ]
;;
