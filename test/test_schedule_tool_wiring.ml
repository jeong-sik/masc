open Alcotest
open Masc

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_dir "schedule_tool_wiring_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "schedule-test"));
  f config
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let keeper_wake_payload message =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; "schema_version", `Int 1
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String "schedule-keeper"
          ; "message", `String message
          ] )
    ]
;;

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

let schedule_ctx config : Tool_schedule.context =
  { config; agent_name = "scheduler-agent" }
;;

let dispatch_exn config action args =
  let name = schedule_tool_name action in
  match Tool_schedule.dispatch (schedule_ctx config) ~name ~args with
  | Some result -> result
  | None -> fail ("schedule dispatch returned None: " ^ name)
;;

let create_args ?schedule_id ?(message = "scheduled keeper wake") () =
  `Assoc
    ([ "due_at_unix", `Float 200.0
     ; "payload_kind", `String Schedule_supported_kinds.keeper_wake
     ; ( "payload_body"
       , `Assoc
           [ "keeper_name", `String "schedule-keeper"
           ; "message", `String message
           ] )
     ; "requested_by_id", `String "operator"
     ; "scheduled_by_id", `String "scheduler-agent"
     ]
     @
     match schedule_id with
     | None -> []
     | Some value -> [ "schedule_id", `String value ])
;;

let create_service_exn config ~schedule_id ~due_at ~payload =
  match
    Schedule_service.create config ~schedule_id ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at ~payload ~source:Schedule_domain.Operator_request ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

let test_flat_tool_surface () =
  let names =
    Tool_schemas_schedule.definitions
    |> List.map (fun (definition : Tool_schemas_schedule.definition) ->
      let schema : Masc_domain.tool_schema = definition.schema in
      schema.name)
  in
  check (list string) "schedule tools"
    [ "masc_schedule_create"
    ; "masc_schedule_list"
    ; "masc_schedule_get"
    ; "masc_schedule_cancel"
    ]
    names;
  check (list string) "public schedule surface" names
    Tool_catalog_surfaces.public_schedule_surface_tools;
  check (list string) "keeper schedule surface" names
    Tool_catalog_surfaces.keeper_schedule_surface_tools;
  List.iter
    (fun name ->
       check bool ("schema registered: " ^ name) true
         (List.exists
            (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
            Config.raw_all_tool_schemas);
       check bool ("tag registered: " ^ name) true
         (Tool_dispatch.lookup_tag name = Some Tool_dispatch.Mod_schedule))
    names;
  let create_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Create_request).schema
  in
  let open Yojson.Safe.Util in
  check bool "create schema is closed" false
    (create_schema.input_schema |> member "additionalProperties" |> to_bool);
  check int "create schema has no mandatory policy field" 0
    (create_schema.input_schema |> member "required" |> to_list |> List.length)
;;

let test_create_list_get_cancel () =
  with_config
  @@ fun config ->
  let create =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id:"sched-tools" ())
  in
  check bool "create succeeds" true (Tool_result.is_success create);
  let open Yojson.Safe.Util in
  check string "created status" "scheduled"
    (Tool_result.data create |> member "status" |> to_string);
  check string "created payload support" "supported"
    (Tool_result.data create |> member "payload_support" |> to_string);
  let list_result =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "limit", `Int 10 ])
  in
  check bool "list succeeds" true (Tool_result.is_success list_result);
  check int "one schedule listed" 1
    (Tool_result.data list_result |> member "schedules" |> to_list |> List.length);
  let get_result =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String "sched-tools" ])
  in
  check bool "get succeeds" true (Tool_result.is_success get_result);
  check string "get id" "sched-tools"
    (Tool_result.data get_result |> member "schedule_id" |> to_string);
  let cancel_result =
    dispatch_exn config Tool_schemas_schedule.Cancel_request
      (`Assoc
        [ "schedule_id", `String "sched-tools"
        ; "cancelled_by_id", `String "operator"
        ; "reason", `String "superseded"
        ])
  in
  check bool "cancel succeeds" true (Tool_result.is_success cancel_result);
  check string "cancelled status" "cancelled"
    (Tool_result.data cancel_result
     |> member "schedule"
     |> member "status"
     |> to_string)
;;

let test_unknown_payload_is_rejected_before_persistence () =
  with_config
  @@ fun config ->
  let labels = [ "phase", "creation" ] in
  let before =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_schedule_payload_unsupported_total
      ~labels ()
  in
  let result =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-unknown"
        ; "due_at_unix", `Float 200.0
        ; "payload_kind", `String "unknown.payload"
        ; "payload_body", `Assoc []
        ; "requested_by_id", `String "operator"
        ; "scheduled_by_id", `String "scheduler-agent"
        ])
  in
  check bool "unknown payload rejected" false (Tool_result.is_success result);
  check bool "typed error names unsupported kind" true
    (String_util.contains_substring
       (Tool_result.message result)
       "unsupported schedule payload kind: unknown.payload");
  check int "nothing persisted" 0
    (List.length (Schedule_store.read_state config).schedules);
  let after =
    Otel_metric_store.metric_value_or_zero
      Otel_metric_store.metric_schedule_payload_unsupported_total
      ~labels ()
  in
  check (float 0.001) "unsupported metric increments" (before +. 1.0) after
;;

let test_payload_contracts_are_schema_only () =
  let contracts =
    Schedule_payload_projection.supported_contracts_to_yojson ()
    |> Yojson.Safe.Util.to_list
  in
  check int "one supported contract" 1 (List.length contracts);
  List.iter
    (fun contract ->
       let open Yojson.Safe.Util in
       check int "contract field count" 5
         (contract |> to_assoc |> List.length);
       check string "creation contract" "per_kind_validator_required"
         (contract |> member "creation_contract" |> to_string);
       check string "dispatch contract" "consumer_supported"
         (contract |> member "dispatch_contract" |> to_string))
    contracts
;;

let test_keeper_wake_schema_validation () =
  with_config
  @@ fun config ->
  let valid =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-wake"
        ; "due_at_unix", `Float 200.0
        ; "payload_kind", `String Schedule_supported_kinds.keeper_wake
        ; "payload_body"
          , `Assoc
              [ "keeper_name", `String "schedule-keeper"
              ; "message", `String "run maintenance"
              ; "urgency", `String "normal"
              ]
        ])
  in
  check bool "valid wake accepted" true (Tool_result.is_success valid);
  let invalid =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-wake-invalid"
        ; "due_at_unix", `Float 200.0
        ; "payload_kind", `String Schedule_supported_kinds.keeper_wake
        ; "payload_body"
          , `Assoc
              [ "keeper_name", `String "schedule-keeper"
              ; "message", `String "run maintenance"
              ; "urgency", `String "urgent-ish"
              ]
        ])
  in
  check bool "invalid urgency rejected" false (Tool_result.is_success invalid);
  check bool "invalid urgency visible" true
    (String_util.contains_substring
       (Tool_result.message invalid)
       "unknown urgency: urgent-ish")
;;

let test_due_signal_and_dashboard_projection () =
  with_config
  @@ fun config ->
  let request =
    create_service_exn config ~schedule_id:"sched-signal" ~due_at:200.0
      ~payload:(keeper_wake_payload "signal me")
  in
  let tick =
    match Schedule_runner.tick config ~now:201.0 with
    | Ok result -> result
    | Error err -> fail (Schedule_runner.runner_error_to_string err)
  in
  check int "one signal" 1 (List.length tick.emitted);
  let signal = List.hd tick.emitted in
  check string "signal kind" "schedule.due_candidate"
    (Schedule_runner.signal_kind_to_string signal.kind);
  check string "signal request" request.schedule_id signal.schedule_id;
  let signal_json = Schedule_runner.wake_signal_to_yojson signal in
  check int "signal field count" 7
    (Yojson.Safe.Util.to_assoc signal_json |> List.length);
  let dashboard =
    Server_dashboard_http_runtime_info.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "dashboard status" "ok" (dashboard |> member "status" |> to_string);
  check string "dashboard fsm" "due"
    (dashboard |> member "fsm" |> member "state" |> to_string);
  let row =
    match dashboard |> member "requests" |> to_list with
    | [ row ] -> row
    | rows -> failf "expected one dashboard row, got %d" (List.length rows)
  in
  check string "stored status is the dashboard SSOT" "due"
    (row |> member "status" |> to_string);
  check string "payload support" "supported"
    (row |> member "payload_support" |> to_string)
;;

let test_schedule_store_error_is_explicit () =
  with_config
  @@ fun config ->
  Workspace_core.write_text config (Schedule_store.schedules_path config) "{not-json";
  let result =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc [])
  in
  check bool "list fails" false (Tool_result.is_success result);
  check bool "store failure visible" true
    (String_util.contains_substring
       (Tool_result.message result)
       "schedule store read failed")
;;

let () =
  run "Schedule_tool_wiring"
    [ ( "wiring"
      , [ test_case "flat tool surface" `Quick test_flat_tool_surface
        ; test_case "create list get cancel" `Quick test_create_list_get_cancel
        ; test_case "unknown payload rejected before persistence" `Quick
            test_unknown_payload_is_rejected_before_persistence
        ; test_case "payload contracts are schema only" `Quick
            test_payload_contracts_are_schema_only
        ; test_case "keeper wake schema validation" `Quick
            test_keeper_wake_schema_validation
        ; test_case "due signal and dashboard projection" `Quick
            test_due_signal_and_dashboard_projection
        ; test_case "schedule store error is explicit" `Quick
            test_schedule_store_error_is_explicit
        ] )
    ]
;;
