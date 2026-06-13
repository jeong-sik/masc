open Alcotest
open Masc

let with_config f =
  let path = Filename.temp_file "schedule_tool_wiring_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
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

let schedule_tool_name action =
  let schema : Masc_domain.tool_schema = (schedule_definition action).schema in
  schema.name
;;

let test_schema_and_descriptor_exposed () =
  let create_name = schedule_tool_name Tool_schemas_schedule.Create_request in
  let schema_names =
    Config.raw_all_tool_schemas
    |> List.map (fun (s : Masc_domain.tool_schema) -> s.name)
  in
  check bool "raw schema has create" true (List.mem create_name schema_names);
  check bool "tag registered" true
    (Tool_dispatch.lookup_tag create_name = Some Tool_dispatch.Mod_schedule);
  let descriptor_names =
    Keeper_tool_descriptor.all_descriptors ()
    |> List.map (fun (d : Keeper_tool_descriptor.t) -> d.internal_name)
  in
  check bool "descriptor has create" true (List.mem create_name descriptor_names)
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
  ~schedule_id
  ~due_at
  ~risk_class
  ~requested_by
  ~scheduled_by
  =
  match
    Schedule_service.create config ~schedule_id ~requested_at:100.0
      ~requested_by ~scheduled_by ~due_at ~payload ~risk_class
      ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err ->
    fail ("schedule create failed: " ^ Schedule_service.service_error_to_string err)
;;

let test_dashboard_projection_surfaces_schedule_fsm () =
  with_config
  @@ fun config ->
  ignore
    (create_schedule_exn config ~schedule_id:"sched-due" ~due_at:1.0
       ~risk_class:Schedule_domain.Read_only ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
      : Schedule_domain.schedule_request);
  ignore
    (create_schedule_exn config ~schedule_id:"sched-approval" ~due_at:300.0
       ~risk_class:Schedule_domain.Workspace_write ~requested_by:(human "operator")
       ~scheduled_by:(automated "scheduler-agent")
      : Schedule_domain.schedule_request);
  let json =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "schema" "masc.dashboard.scheduled_automation.v1"
    (json |> member "schema" |> to_string);
  check int "request count" 2 (json |> member "request_count" |> to_int);
  check string "fsm state" "pending_approval"
    (json |> member "fsm" |> member "state" |> to_string);
  check int "pending count" 1
    (json |> member "counts" |> member "pending_approval" |> to_int);
  check int "scheduled count" 1
    (json |> member "counts" |> member "scheduled" |> to_int);
  check int "due effective count" 1
    (json |> member "derived_counts" |> member "due_effective" |> to_int)
;;

let () =
  run "Schedule_tool_wiring"
    [ ( "wiring"
      , [ test_case "schema and descriptor exposed" `Quick
            test_schema_and_descriptor_exposed
        ; test_case "dispatch create persists schedule" `Quick
            test_dispatch_create_persists_schedule
        ; test_case "dispatch cancel persists status" `Quick
            test_dispatch_cancel_persists_status
        ; test_case "dashboard projection surfaces schedule FSM" `Quick
            test_dashboard_projection_surfaces_schedule_fsm
        ] )
    ]
;;
