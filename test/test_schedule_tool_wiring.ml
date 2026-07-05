open Alcotest
open Masc

let with_config f =
  let path = Filename.temp_dir "schedule_tool_wiring_test" "" in
  Fun.protect
    ~finally:(fun () ->
      let rec rm path =
        if Sys.file_exists path then
          if Sys.is_directory path then begin
            Sys.readdir path
            |> Array.iter (fun entry -> rm (Filename.concat path entry));
            Unix.rmdir path
          end else
            Sys.remove path
      in
      rm path)
    (fun () -> f (Workspace.default_config path))
;;

let payload =
  `Assoc
    [ "kind", `String "test.reminder"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "message", `String "wake me" ]
    ]
;;

let board_post_payload =
  `Assoc
    [ "kind", `String "masc.board_post"
    ; "schema_version", `Int 1
    ; "body", `Assoc [ "content", `String "scheduled board post" ]
    ]
;;

let keeper_wake_payload_body =
  `Assoc
    [ "keeper_name", `String "schedule-keeper"
    ; "title", `String "Scheduled lane wake"
    ; "message", `String "Run the scheduled maintenance lane now."
    ; "urgency", `String "normal"
    ]
;;

let create_fields =
  [ "due_at_unix", `Float 200.0
  ; "risk_class", `String "read_only"
  ; "payload", payload
  ; "requested_by_id", `String "operator"
  ; "scheduled_by_id", `String "scheduler-agent"
  ]
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let create_args = `Assoc create_fields

let schedule_definition action =
  match
    List.find_opt
      (fun (definition : Tool_schemas_schedule.definition) ->
        definition.action = action)
      Tool_schemas_schedule.definitions
  with
  | Some definition -> definition
  | None -> fail "schedule definition missing"
;;

let operator_schedule_definition action =
  match
    List.find_opt
      (fun (definition : Tool_schemas_schedule.definition) ->
        definition.action = action)
      Tool_schemas_schedule.operator_decision_definitions
  with
  | Some definition -> definition
  | None -> fail "operator schedule definition missing"
;;

let schedule_tool_name action =
  let schema : Masc_domain.tool_schema = (schedule_definition action).schema in
  schema.name
;;

let operator_schedule_tool_name action =
  let schema : Masc_domain.tool_schema =
    (operator_schedule_definition action).schema
  in
  schema.name
;;

let test_schema_and_descriptor_exposed () =
  let create_name = schedule_tool_name Tool_schemas_schedule.Create_request in
  let approve_name = operator_schedule_tool_name Tool_schemas_schedule.Approve_request in
  let reject_name = operator_schedule_tool_name Tool_schemas_schedule.Reject_request in
  let approve_schema =
    (operator_schedule_definition Tool_schemas_schedule.Approve_request).schema
  in
  let reject_schema =
    (operator_schedule_definition Tool_schemas_schedule.Reject_request).schema
  in
  let schema_names =
    Config.raw_all_tool_schemas
    |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)
  in
  check bool "raw schema has create" true (List.mem create_name schema_names);
  check bool "raw schema hides approve" false (List.mem approve_name schema_names);
  check bool "raw schema hides reject" false (List.mem reject_name schema_names);
  check string "approve describes due grants"
    "Record a separate human execution grant for a pending or due scheduled request. Recurring side-effecting requests need a fresh grant for each due occurrence."
    approve_schema.description;
  check string "reject describes due decisions"
    "Reject a pending or due scheduled request with a human decision."
    reject_schema.description;
  check bool "tag registered" true
      (Tool_dispatch.lookup_tag create_name = Some Tool_dispatch.Mod_schedule);
  let descriptor_names =
    Keeper_tool_descriptor.all_descriptors ()
    |> List.map (fun (d : Keeper_tool_descriptor.t) -> d.internal_name)
  in
  check bool "descriptor has create" true (List.mem create_name descriptor_names);
  check bool "descriptor hides approve" false (List.mem approve_name descriptor_names);
  check bool "descriptor hides reject" false (List.mem reject_name descriptor_names)
;;

let schedule_ctx config : Tool_schedule.context =
  { config; agent_name = "scheduler-agent" }
;;

let test_dispatch_create_persists_schedule () =
  with_config
  @@ fun config ->
  match
    Tool_schedule.dispatch (schedule_ctx config)
      ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
      ~args:create_args
  with
  | None -> fail "dispatch returned None"
  | Some result ->
    check bool "create succeeds" true (Tool_result.is_success result);
    let state = Schedule_store.read_state config in
    check int "one schedule persisted" 1 (List.length state.schedules);
    let request = List.hd state.schedules in
    check string "status" "scheduled"
      (Schedule_domain.schedule_status_to_string request.status)
;;

let test_dispatch_operator_decisions_are_dashboard_only () =
  with_config
  @@ fun config ->
  let ctx = schedule_ctx config in
  let approve_name = operator_schedule_tool_name Tool_schemas_schedule.Approve_request in
  let reject_name = operator_schedule_tool_name Tool_schemas_schedule.Reject_request in
  (match Tool_schedule.dispatch ctx ~name:approve_name
           ~args:(`Assoc [ "schedule_id", `String "sched-1"; "approved_by_id", `String "operator" ])
   with
   | None -> ()
   | Some _ -> fail "approve should not dispatch through public schedule tool surface");
  (match Tool_schedule.dispatch ctx ~name:reject_name
           ~args:(`Assoc
                    [ "schedule_id", `String "sched-1"
                    ; "approved_by_id", `String "operator"
                    ; "reason", `String "no"
                    ])
   with
   | None -> ()
   | Some _ -> fail "reject should not dispatch through public schedule tool surface")
;;

let test_dispatch_create_persists_recurrence () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      ([ "schedule_id", `String "sched-loop"
       ; "recurrence_kind", `String "interval"
       ; "recurrence_interval_sec", `Int 900
       ]
       @ create_fields)
  in
  match
    Tool_schedule.dispatch (schedule_ctx config)
      ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
      ~args
  with
  | None -> fail "dispatch returned None"
  | Some result ->
    check bool "create succeeds" true (Tool_result.is_success result);
    (match Schedule_store.get_schedule config ~schedule_id:"sched-loop" with
     | None -> fail "schedule missing"
     | Some request ->
       check string "recurrence" "interval"
         (Schedule_domain.recurrence_kind_to_string request.recurrence))
;;

let test_dispatch_create_derives_due_at_for_cron_recurrence () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-cron"
      ; "requested_at_unix", `Float 32400.0
      ; "risk_class", `String "read_only"
      ; "payload", payload
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ; "recurrence_kind", `String "cron"
      ; "recurrence_cron", `String "0 9 * * 1-5"
      ; "recurrence_timezone", `String "UTC"
      ]
  in
  match
    Tool_schedule.dispatch (schedule_ctx config)
      ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
      ~args
  with
  | None -> fail "dispatch returned None"
  | Some result ->
    check bool "create succeeds" true (Tool_result.is_success result);
    let data = Tool_result.data result in
    let open Yojson.Safe.Util in
    check string "result recurrence kind" "cron"
      (data |> member "recurrence_kind" |> to_string);
    check string "result recurrence summary" "cron 0 9 * * 1-5 UTC"
      (data |> member "recurrence_summary" |> to_string);
    check (float 0.001) "result next due_at" 118800.0
      (data |> member "next_due_at" |> to_float);
    check string "result next due_at iso" "1970-01-02T09:00:00Z"
      (data |> member "next_due_at_iso" |> to_string);
    check bool "result separate grant" false
      (data |> member "requires_separate_human_grant" |> to_bool);
    check string "result approval policy" "no_separate_grant_required"
      (data |> member "approval_policy" |> to_string);
    (match Schedule_store.get_schedule config ~schedule_id:"sched-cron" with
     | None -> fail "schedule missing"
     | Some request ->
       check string "recurrence" "cron"
         (Schedule_domain.recurrence_kind_to_string request.recurrence);
       check (float 0.001) "derived due_at" 118800.0 request.due_at)
;;

let test_dispatch_create_board_post_convenience_payload () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-board-post"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "board_title", `String "Scheduled check-in"
      ; "board_content", `String "Daily schedule fired"
      ; "board_hearth", `String "ops"
      ; "board_author", `String "schedule-bot"
      ; "board_ttl_hours", `Int 2
      ; "board_meta", `Assoc [ "purpose", `String "operator-request" ]
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create succeeds" true (Tool_result.is_success result);
     let data = Tool_result.data result in
     let open Yojson.Safe.Util in
     check string "result payload kind" "masc.board_post"
       (data |> member "payload_kind" |> to_string);
     check string "result payload target" "hearth:ops"
       (data |> member "payload_target" |> to_string);
     check string "result payload summary" "Scheduled check-in"
       (data |> member "payload_summary" |> to_string);
     check bool "result separate grant" true
       (data |> member "requires_separate_human_grant" |> to_bool));
  (match Schedule_store.get_schedule config ~schedule_id:"sched-board-post" with
   | None -> fail "schedule missing"
   | Some request ->
     check string "status" "pending_approval"
       (Schedule_domain.schedule_status_to_string request.status);
     let payload = Schedule_domain.payload_to_yojson request.payload in
     let open Yojson.Safe.Util in
     check string "stored payload kind" "masc.board_post"
       (payload |> member "kind" |> to_string);
     check string "stored title" "Scheduled check-in"
       (payload |> member "body" |> member "title" |> to_string);
     check string "stored content" "Daily schedule fired"
       (payload |> member "body" |> member "content" |> to_string);
     check string "stored hearth" "ops"
       (payload |> member "body" |> member "hearth" |> to_string);
     check int "stored ttl" 2
       (payload |> member "body" |> member "ttl_hours" |> to_int));
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row =
    dashboard
    |> member "requests"
    |> to_list
    |> function
    | [ row ] -> row
    | rows -> failf "expected one dashboard row, got %d" (List.length rows)
  in
  check string "dashboard payload kind" "masc.board_post"
    (row |> member "payload_kind" |> to_string);
  check string "dashboard payload target" "hearth:ops"
    (row |> member "payload_target" |> to_string);
  check string "dashboard payload summary" "Scheduled check-in"
    (row |> member "payload_summary" |> to_string)
;;

let test_dispatch_create_keeper_wake_payload () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-keeper-wake"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload_kind", `String "masc.keeper_wake"
      ; "payload_body", keeper_wake_payload_body
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create succeeds" true (Tool_result.is_success result);
     let data = Tool_result.data result in
     let open Yojson.Safe.Util in
     check string "result payload kind" "masc.keeper_wake"
       (data |> member "payload_kind" |> to_string);
     check string "result payload target" "keeper:schedule-keeper"
       (data |> member "payload_target" |> to_string);
     check string "result payload summary" "Scheduled lane wake"
       (data |> member "payload_summary" |> to_string);
     check bool "result separate grant" true
       (data |> member "requires_separate_human_grant" |> to_bool));
  (match Schedule_store.get_schedule config ~schedule_id:"sched-keeper-wake" with
   | None -> fail "schedule missing"
   | Some request ->
     check string "status" "pending_approval"
       (Schedule_domain.schedule_status_to_string request.status);
     let payload = Schedule_domain.payload_to_yojson request.payload in
     let open Yojson.Safe.Util in
     check string "stored payload kind" "masc.keeper_wake"
       (payload |> member "kind" |> to_string);
     check string "stored keeper" "schedule-keeper"
       (payload |> member "body" |> member "keeper_name" |> to_string);
     check string "stored message" "Run the scheduled maintenance lane now."
       (payload |> member "body" |> member "message" |> to_string));
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  let row =
    dashboard
    |> member "requests"
    |> to_list
    |> function
    | [ row ] -> row
    | rows -> failf "expected one dashboard row, got %d" (List.length rows)
  in
  check string "dashboard payload kind" "masc.keeper_wake"
    (row |> member "payload_kind" |> to_string);
  check string "dashboard payload target" "keeper:schedule-keeper"
    (row |> member "payload_target" |> to_string);
  check string "dashboard payload summary" "Scheduled lane wake"
    (row |> member "payload_summary" |> to_string)
;;

let test_dispatch_create_rejects_keeper_wake_invalid_urgency () =
  with_config
  @@ fun config ->
  let invalid_body =
    `Assoc
      [ "keeper_name", `String "schedule-keeper"
      ; "message", `String "Run the scheduled maintenance lane now."
      ; "urgency", `String "urgent-ish"
      ]
  in
  let args =
    `Assoc
      [ "schedule_id", `String "sched-keeper-wake-invalid-urgency"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload_kind", `String "masc.keeper_wake"
      ; "payload_body", invalid_body
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects invalid keeper wake urgency" false
       (Tool_result.is_success result);
     check (option string) "failure class" (Some "workflow_rejection")
       (Option.map Tool_result.tool_failure_class_to_string
          (Tool_result.failure_class result));
     check string "message" "unknown urgency: urgent-ish"
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

let test_dispatch_create_rejects_keeper_wake_invalid_target_name () =
  with_config
  @@ fun config ->
  let invalid_body =
    `Assoc
      [ "keeper_name", `String "../bad"
      ; "message", `String "Run the scheduled maintenance lane now."
      ]
  in
  let args =
    `Assoc
      [ "schedule_id", `String "sched-keeper-wake-invalid-name"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload_kind", `String "masc.keeper_wake"
      ; "payload_body", invalid_body
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects invalid keeper wake target name" false
       (Tool_result.is_success result);
     check (option string) "failure class" (Some "workflow_rejection")
       (Option.map Tool_result.tool_failure_class_to_string
          (Tool_result.failure_class result));
     check string "message"
       (Schedule_supported_kinds.keeper_wake_target_name_error
          ~field:"masc.keeper_wake payload body.keeper_name")
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

let test_dispatch_create_rejects_negative_board_ttl () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-negative-ttl"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "board_content", `String "Daily schedule fired"
      ; "board_ttl_hours", `Int (-1)
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects negative ttl" false (Tool_result.is_success result);
     check (option string) "failure class" (Some "workflow_rejection")
       (Option.map Tool_result.tool_failure_class_to_string
          (Tool_result.failure_class result));
     check string "message" "board_ttl_hours must be non-negative"
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

let test_dispatch_create_rejects_payload_mixed_with_board_fields () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-payload-board-mixed"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload", payload
      ; "board_content", `String "Daily schedule fired"
      ; "board_hearth", `String "ops"
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects payload and board fields" false
       (Tool_result.is_success result);
     check (option string) "failure class" (Some "workflow_rejection")
       (Option.map Tool_result.tool_failure_class_to_string
          (Tool_result.failure_class result));
     check string "message" "use either payload or board_* convenience fields, not both"
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

let test_dispatch_create_rejects_board_payload_without_content () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-board-empty"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload_kind", `String "masc.board_post"
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects missing board content" false
       (Tool_result.is_success result);
     check string "message"
       "masc.board_post payload requires non-empty body.content; use board_content for board schedules"
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

(* A side-effecting payload kind the consumer cannot dispatch must be rejected
   at creation. The supported set is the SSOT in schedule_supported_kinds.ml;
   read-only/reminder kinds stay opaque (allowed), only side-effecting work is
   gated. *)
let test_dispatch_create_rejects_unsupported_side_effecting_kind () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-unsupported-kind"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "workspace_write"
      ; "payload_kind", `String "orphan_auto_release"
      ; "payload_body", `Assoc [ "action", `String "orphan_auto_release" ]
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects unsupported side-effecting kind" false
       (Tool_result.is_success result);
     check (option string) "failure class" (Some "workflow_rejection")
       (Option.map Tool_result.tool_failure_class_to_string
          (Tool_result.failure_class result)));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted for unsupported kind" 0
    (List.length state.schedules)
;;

let test_dispatch_create_rejects_read_only_board_payload () =
  with_config
  @@ fun config ->
  let args =
    `Assoc
      [ "schedule_id", `String "sched-board-readonly"
      ; "due_at_unix", `Float 200.0
      ; "risk_class", `String "read_only"
      ; "board_content", `String "Daily schedule fired"
      ; "requested_by_id", `String "operator"
      ; "scheduled_by_id", `String "scheduler-agent"
      ]
  in
  (match
     Tool_schedule.dispatch (schedule_ctx config)
       ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
       ~args
   with
   | None -> fail "dispatch returned None"
   | Some result ->
     check bool "create rejects read-only board payload" false
       (Tool_result.is_success result);
     check string "message"
       "masc.board_post requires a side-effecting risk_class such as workspace_write"
       (Tool_result.message result));
  let state = Schedule_store.read_state config in
  check int "no schedule persisted" 0 (List.length state.schedules)
;;

let test_dispatch_cancel_persists_status () =
  with_config
  @@ fun config ->
  let create_result =
    Tool_schedule.dispatch (schedule_ctx config)
      ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
      ~args:(`Assoc (("schedule_id", `String "sched-cancel") :: create_fields))
  in
  (match create_result with
   | Some result when Tool_result.is_success result -> ()
   | Some result -> fail ("create failed: " ^ Tool_result.message result)
   | None -> fail "create dispatch returned None");
  let cancel_args =
    `Assoc
      [ "schedule_id", `String "sched-cancel"
      ; "cancelled_by_id", `String "operator"
      ; "reason", `String "test cleanup"
      ]
  in
  match
    Tool_schedule.dispatch (schedule_ctx config)
      ~name:(schedule_tool_name Tool_schemas_schedule.Cancel_request)
      ~args:cancel_args
  with
  | None -> fail "cancel dispatch returned None"
  | Some result ->
    check bool "cancel succeeds" true (Tool_result.is_success result);
    match Schedule_store.get_schedule config ~schedule_id:"sched-cancel" with
    | None -> fail "schedule missing"
    | Some request ->
      check string "status" "cancelled"
        (Schedule_domain.schedule_status_to_string request.status)
;;

let create_schedule_exn
  config
  ?expires_at
  ?(payload = payload)
  ?recurrence
  ~schedule_id
  ~due_at
  ~risk_class
  ~requested_by
  ~scheduled_by
  ()
  =
  match
    Schedule_service.create config ~schedule_id ~requested_at:100.0
      ~requested_by ~scheduled_by ~due_at ~payload ~risk_class
      ~source:Schedule_domain.Operator_request ?expires_at ?recurrence ()
  with
  | Ok request -> request
  | Error err ->
    fail ("schedule create failed: " ^ Schedule_service.service_error_to_string err)
;;

let test_dashboard_projection_surfaces_schedule_fsm () =
  with_config
  @@ fun config ->
  let now = Time_compat.now () in
  let past_due = now -. 10.0 in
  let future_due = now +. 3600.0 in
  ignore
    (create_schedule_exn config ~schedule_id:"sched-exec" ~due_at:50.0
       ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  (match Schedule_store.refresh_due config ~now:51.0 with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  (match Schedule_store.start_due_candidate config ~now:52.0 ~schedule_id:"sched-exec" with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  (match
     Schedule_store.complete_running config ~now:53.0 ~schedule_id:"sched-exec"
       ~detail:(`Assoc [ "kind", `String "test.exec" ])
       ()
  with
  | Ok _ -> ()
  | Error err -> fail (Schedule_store.store_error_to_string err));
  ignore
    (create_schedule_exn config ~schedule_id:"sched-due" ~due_at:past_due
       ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ~recurrence:
         (Schedule_domain.Daily
            { hour = 9; minute = 0; second = 0; timezone = "Asia/Seoul" })
       ()
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-approval" ~due_at:future_due
       ~payload:board_post_payload ~risk_class:Schedule_domain.Workspace_write
       ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-blocked" ~due_at:past_due
       ~risk_class:Schedule_domain.Workspace_write ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-expired-effective"
       ~due_at:past_due ~expires_at:(now -. 1.0) ~risk_class:Schedule_domain.Read_only
       ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  let json =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "schema" "masc.dashboard.scheduled_automation.v1"
    (json |> member "schema" |> to_string);
  check int "request count" 5 (json |> member "request_count" |> to_int);
  check string "fsm state" "blocked_approval"
    (json |> member "fsm" |> member "state" |> to_string);
  check int "effective active count" 3
    (json |> member "fsm" |> member "active_count" |> to_int);
  check int "effective terminal count" 2
    (json |> member "fsm" |> member "terminal_count" |> to_int);
  check int "pending count" 2
    (json |> member "counts" |> member "pending_approval" |> to_int);
  check int "scheduled count" 2
    (json |> member "counts" |> member "scheduled" |> to_int);
  check int "due effective count" 1
    (json |> member "derived_counts" |> member "due_effective" |> to_int);
  check int "blocked approval count" 1
    (json |> member "derived_counts" |> member "blocked_approval" |> to_int);
  check int "due execution ready count" 0
    (json |> member "derived_counts" |> member "due_execution_ready" |> to_int);
  check int "expired effective count" 1
    (json |> member "derived_counts" |> member "expired_effective" |> to_int);
  check int "unsupported payload count" 4
    (json |> member "derived_counts" |> member "unsupported_payload_kind" |> to_int);
  check int "unknown payload count" 0
    (json |> member "derived_counts" |> member "unknown_payload_kind" |> to_int);
  check int "payload support unsupported count" 4
    (json |> member "payload_support" |> member "unsupported_request_count" |> to_int);
  check int "payload support unknown count" 0
    (json |> member "payload_support" |> member "unknown_request_count" |> to_int);
  check string "supported payload kind" "masc.board_post"
    (json |> member "payload_support" |> member "supported_kinds" |> to_list
     |> List.hd |> to_string);
  (match json |> member "payload_support" |> member "unsupported_kinds" |> to_list with
   | unsupported :: _ ->
     check string "unsupported payload kind" "test.reminder"
       (unsupported |> member "kind" |> to_string);
     check int "unsupported payload kind count" 4
       (unsupported |> member "count" |> to_int)
   | [] -> fail "expected unsupported payload kind summary");
  let requests = json |> member "requests" |> to_list in
  let find_request schedule_id =
    match
      List.find_opt
        (fun row -> String.equal (row |> member "schedule_id" |> to_string) schedule_id)
        requests
    with
    | Some row -> row
    | None -> fail ("schedule missing from dashboard projection: " ^ schedule_id)
  in
  let due_row = find_request "sched-due" in
  check string "due payload unsupported" "unsupported"
    (due_row |> member "payload_support" |> to_string);
  check string "due recurrence kind" "daily"
    (due_row |> member "recurrence_kind" |> to_string);
  check string "due recurrence object kind" "daily"
    (due_row |> member "recurrence" |> member "kind" |> to_string);
  check string "due recurrence summary" "daily 09:00:00 Asia/Seoul"
    (due_row |> member "recurrence_summary" |> to_string);
  check string "due next due iso"
    (due_row |> member "due_at_iso" |> to_string)
    (due_row |> member "next_due_at_iso" |> to_string);
  check bool "due separate grant" false
    (due_row |> member "requires_separate_human_grant" |> to_bool);
  check string "due approval policy" "no_separate_grant_required"
    (due_row |> member "approval_policy" |> to_string);
  check string "due effective status" "due"
    (due_row |> member "effective_status" |> to_string);
  check string "due readiness" "due_pending_refresh"
    (due_row |> member "execution_readiness" |> to_string);
  check string "due action" "wait_for_runner_tick"
    (due_row |> member "operator_action" |> to_string);
  check string "due keeper next tool" "masc_schedule_get"
    (due_row |> member "keeper_next_tool" |> to_string);
  let due_tool_status = due_row |> member "keeper_next_tool_status" in
  check string "due keeper next tool status name" "masc_schedule_get"
    (due_tool_status |> member "name" |> to_string);
  check bool "due keeper next tool schema registered" true
    (due_tool_status |> member "registered_schema" |> to_bool);
  check bool "due keeper next tool dispatch registered" true
    (due_tool_status |> member "dispatch_registered" |> to_bool);
  check bool "due keeper next tool direct callable" true
    (due_tool_status |> member "direct_call_allowed" |> to_bool);
  check string "due keeper next tool default visibility" "default"
    (due_tool_status |> member "visibility" |> to_string);
  check int "due keeper next tool has no surface projection" 0
    (due_tool_status |> member "surface_count" |> to_int);
  check string "due keeper next tool read-only domain" "read_only"
    (due_tool_status |> member "effect_domain" |> to_string);
  check bool "due keeper action mentions runner tick" true
    (String_util.contains_substring
       (due_row |> member "keeper_next_action" |> to_string)
       "runner tick");
  let blocked_row = find_request "sched-blocked" in
  check string "blocked payload unsupported" "unsupported"
    (blocked_row |> member "payload_support" |> to_string);
  check bool "blocked separate grant" true
    (blocked_row |> member "requires_separate_human_grant" |> to_bool);
  check string "blocked approval policy" "separate_human_grant_required"
    (blocked_row |> member "approval_policy" |> to_string);
  check string "blocked effective status" "blocked_approval"
    (blocked_row |> member "effective_status" |> to_string);
  check string "blocked readiness" "blocked_approval"
    (blocked_row |> member "execution_readiness" |> to_string);
  check string "blocked action" "approve_or_reject"
    (blocked_row |> member "operator_action" |> to_string);
  check string "blocked keeper next tool" "masc_schedule_get"
    (blocked_row |> member "keeper_next_tool" |> to_string);
  check bool "blocked keeper action mentions dashboard action" true
    (String_util.contains_substring
       (blocked_row |> member "keeper_next_action" |> to_string)
       "dashboard operator approval or rejection");
  let expired_row = find_request "sched-expired-effective" in
  check string "expired payload unsupported" "unsupported"
    (expired_row |> member "payload_support" |> to_string);
  check string "expired effective status" "expired"
    (expired_row |> member "effective_status" |> to_string);
  check string "expired readiness" "expired"
    (expired_row |> member "execution_readiness" |> to_string);
  check string "expired action" "inspect_or_recreate"
    (expired_row |> member "operator_action" |> to_string);
  check string "expired keeper next tool" "masc_schedule_get"
    (expired_row |> member "keeper_next_tool" |> to_string);
  check bool "expired keeper action mentions recreate" true
    (String_util.contains_substring
       (expired_row |> member "keeper_next_action" |> to_string)
       "masc_schedule_create");
  let exec_row =
    List.find_opt
      (fun row -> String.equal (row |> member "schedule_id" |> to_string) "sched-exec")
      requests
  in
  let supported_row = find_request "sched-approval" in
  check string "supported board payload" "supported"
    (supported_row |> member "payload_support" |> to_string);
  match exec_row with
  | None -> fail "sched-exec missing from dashboard projection"
  | Some row ->
    check string "terminal effective status" "succeeded"
      (row |> member "effective_status" |> to_string);
    check string "terminal readiness" "terminal"
      (row |> member "execution_readiness" |> to_string);
    check string "last execution status" "succeeded"
      (row |> member "last_execution" |> member "status" |> to_string);
    check string "last execution detail" "test.exec"
      (row |> member "last_execution" |> member "detail" |> member "kind" |> to_string)
;;

let test_dashboard_projection_surfaces_schedule_runner_signals () =
  with_config
  @@ fun config ->
  let request =
    create_schedule_exn config ~schedule_id:"sched-signal" ~due_at:200.0
      ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ()
  in
  let tick_result =
    match Schedule_runner.tick config ~now:201.0 with
    | Ok result -> result
    | Error err -> fail (Schedule_runner.runner_error_to_string err)
  in
  check int "one durable signal emitted" 1 (List.length tick_result.emitted);
  let emitted = List.hd tick_result.emitted in
  let json =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "signal source" "schedule_runner_signals"
    (json |> member "signal_source" |> to_string);
  check int "signal count" 1 (json |> member "signal_count" |> to_int);
  check int "signal limit" 20 (json |> member "signal_limit" |> to_int);
  let signal =
    match json |> member "signals" |> to_list with
    | [ signal ] -> signal
    | signals -> failf "expected one dashboard signal, got %d" (List.length signals)
  in
  check string "signal id" emitted.signal_id
    (signal |> member "signal_id" |> to_string);
  check string "signal kind" "schedule.due_candidate"
    (signal |> member "kind" |> to_string);
  check string "signal event type" "schedule.due_candidate"
    (signal |> member "event_type" |> to_string);
  check string "signal schedule" request.schedule_id
    (signal |> member "schedule_id" |> to_string);
  check string "signal emitted iso" "1970-01-01T00:03:21Z"
    (signal |> member "emitted_at_iso" |> to_string);
  check string "signal due iso" "1970-01-01T00:03:20Z"
    (signal |> member "due_at_iso" |> to_string);
  check string "signal risk" "read_only"
    (signal |> member "risk_class" |> to_string);
  check string "signal payload kind" "test.reminder"
    (signal |> member "payload_kind" |> to_string);
  check string "signal payload digest" emitted.payload_digest
    (signal |> member "payload_digest" |> to_string)
;;

let test_keeper_observation_surfaces_schedule_attention () =
  with_config
  @@ fun config ->
  let now = 1_000.0 in
  ignore
    (create_schedule_exn config ~schedule_id:"sched-ready" ~due_at:(now -. 10.0)
       ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-blocked" ~due_at:(now -. 20.0)
       ~risk_class:Schedule_domain.Workspace_write ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-future" ~due_at:(now +. 3600.0)
       ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
       ()
      : Schedule_domain.schedule_request);
  (match Schedule_store.refresh_due config ~now with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  let observation =
    Keeper_world_observation.read_scheduled_automation_observation ~config ~now
  in
  check int "active count" 3 observation.active_count;
  check int "due ready count" 1 observation.due_ready_count;
  check int "blocked approval count" 1 observation.blocked_approval_count;
  check (option (float 0.001)) "next due" (Some (now -. 20.0))
    observation.next_due_at;
  check int "attention items" 2 (List.length observation.items);
  (match observation.items with
   | blocked :: ready :: [] ->
     check string "blocked schedule first" "sched-blocked" blocked.schedule_id;
     check string "blocked action" "approve_or_reject" blocked.action;
     check (option string) "blocked next tool" (Some "masc_schedule_get")
       blocked.keeper_next_tool;
     check bool "blocked next action mentions dashboard action" true
       (String_util.contains_substring blocked.keeper_next_action
          "dashboard operator approval or rejection");
     check string "ready schedule second" "sched-ready" ready.schedule_id;
     check string "ready action" "dispatch_ready" ready.action;
     check (option string) "ready next tool" (Some "masc_schedule_get")
       ready.keeper_next_tool;
     check bool "ready next action avoids duplicates" true
       (String_util.contains_substring ready.keeper_next_action
          "do not create a duplicate schedule")
   | _ -> fail "expected blocked and ready attention rows")
;;

let () =
  run "Schedule_tool_wiring"
    [ ( "wiring"
      , [ test_case "schema and descriptor exposed" `Quick
            test_schema_and_descriptor_exposed
        ; test_case "dispatch create persists schedule" `Quick
            test_dispatch_create_persists_schedule
        ; test_case "operator decisions are dashboard-only" `Quick
            test_dispatch_operator_decisions_are_dashboard_only
        ; test_case "dispatch create persists recurrence" `Quick
            test_dispatch_create_persists_recurrence
        ; test_case "dispatch create derives due_at for cron recurrence" `Quick
            test_dispatch_create_derives_due_at_for_cron_recurrence
        ; test_case "dispatch create accepts board-post convenience payload" `Quick
            test_dispatch_create_board_post_convenience_payload
        ; test_case "dispatch create accepts keeper wake payload" `Quick
            test_dispatch_create_keeper_wake_payload
        ; test_case "dispatch create rejects invalid keeper wake urgency" `Quick
            test_dispatch_create_rejects_keeper_wake_invalid_urgency
        ; test_case "dispatch create rejects invalid keeper wake target name" `Quick
            test_dispatch_create_rejects_keeper_wake_invalid_target_name
        ; test_case "dispatch create rejects negative board ttl" `Quick
            test_dispatch_create_rejects_negative_board_ttl
        ; test_case "dispatch create rejects payload mixed with board fields" `Quick
            test_dispatch_create_rejects_payload_mixed_with_board_fields
        ; test_case "dispatch create rejects board payload without content" `Quick
            test_dispatch_create_rejects_board_payload_without_content
        ; test_case "dispatch create rejects read-only board payload" `Quick
            test_dispatch_create_rejects_read_only_board_payload
        ; test_case "dispatch create rejects unsupported side-effecting kind" `Quick
            test_dispatch_create_rejects_unsupported_side_effecting_kind
        ; test_case "dispatch cancel persists status" `Quick
            test_dispatch_cancel_persists_status
        ; test_case "dashboard projection surfaces schedule FSM" `Quick
            test_dashboard_projection_surfaces_schedule_fsm
        ; test_case "dashboard projection surfaces schedule runner signals" `Quick
            test_dashboard_projection_surfaces_schedule_runner_signals
        ; test_case "keeper observation surfaces schedule attention" `Quick
            test_keeper_observation_surfaces_schedule_attention
        ] )
    ]
;;
