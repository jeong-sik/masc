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

let register_wake_target config keeper_name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
        ; "trace_id", `String ("trace-" ^ keeper_name)
        ])
  with
  | Error msg -> fail ("keeper meta parse failed: " ^ msg)
  | Ok meta ->
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error detail -> fail ("keeper meta write failed: " ^ detail))
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
  Workspace_metric_hooks.install ();
  Atomic.set Workspace_hooks.schedule_wake_target_registered_fn (fun config keeper_name ->
    match Keeper_meta_store.read_effective_meta config keeper_name with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error detail -> Error detail);
  register_wake_target config "schedule-keeper";
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

let schedule_ctx ?continuation_channel config : Tool_schedule.context =
  { config
  ; agent_name = "scheduler-agent"
  ; stamp_keeper_wake_result_delivery =
      (fun ~payload ->
         Schedule_payload_projection.set_keeper_wake_result_delivery
           ~payload
           ~channel:continuation_channel)
  ; admit_keeper_wake_creation = Keeper_schedule_creation_admission.run
  }
;;

let dispatch_exn ?continuation_channel config action args =
  let name = schedule_tool_name action in
  match
    Tool_schedule.dispatch
      (schedule_ctx ?continuation_channel config)
      ~name
      ~args
  with
  | Some result -> result
  | None -> fail ("schedule dispatch returned None: " ^ name)
;;

let create_args
      ?schedule_id
      ?(allow_unregistered_keeper = false)
      ?(message = "scheduled keeper wake")
      ()
  =
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
     if allow_unregistered_keeper
     then [ "allow_unregistered_keeper", `Bool true ]
     else []
     @
     match schedule_id with
     | None -> []
     | Some value -> [ "schedule_id", `String value ])
;;

let create_service_exn config ~schedule_id ~due_at ~payload ?recurrence () =
  match
    Schedule_service.create config ~schedule_id ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at ~payload ~source:Schedule_domain.Operator_request ?recurrence ()
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
  let keeper_schedule_tools =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
    |> List.filter (String.starts_with ~prefix:"masc_schedule_")
  in
  check (list string) "descriptor-projected keeper schedule surface" names
    keeper_schedule_tools;
  List.iter
    (fun name ->
       check bool ("tool_inventory includes: " ^ name) true
         (List.exists
            (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
            Config.raw_all_tool_schemas);
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
    (create_schema.input_schema |> member "required" |> to_list |> List.length);
  let get_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Get_request).schema
  in
  check (list string) "get requires the durable schedule pointer"
    [ "schedule_id" ]
    (get_schema.input_schema
     |> member "required"
     |> to_list
     |> List.map to_string)
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
  check string "no continuation stamps an explicit no-delivery policy" "none"
    (Tool_result.data create
     |> member "payload"
     |> member "body"
     |> member "result_delivery"
     |> member "policy"
     |> to_string);
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

let test_creation_boundary_owns_result_delivery_destination () =
  with_config
  @@ fun config ->
  let channel =
    match Keeper_continuation_channel.dashboard ~thread_id:"dashboard-thread-42" with
    | Ok channel -> channel
    | Error detail -> fail detail
  in
  let forged_channel =
    match Keeper_continuation_channel.dashboard ~thread_id:"forged-thread" with
    | Ok channel -> channel
    | Error detail -> fail detail
  in
  let payload =
    `Assoc
      [ "kind", `String Schedule_supported_kinds.keeper_wake
      ; "schema_version", `Int 1
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String "schedule-keeper"
            ; "message", `String "return the result to the invoking thread"
            ; ( "result_delivery"
              , `Assoc
                  [ "policy", `String "reply_to_origin"
                  ; "channel", Keeper_continuation_channel.to_yojson forged_channel
                  ] )
            ; "result_delivery", `Assoc [ "policy", `String "none" ]
            ] )
      ]
  in
  let result =
    dispatch_exn
      ~continuation_channel:channel
      config
      Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-owned-result-destination"
        ; "due_at_unix", `Float 200.0
        ; "payload", payload
        ])
  in
  check bool "routed schedule creation succeeds" true
    (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let stored_delivery =
    Tool_result.data result
    |> member "payload"
    |> member "body"
    |> member "result_delivery"
  in
  check string "creation boundary selects reply-to-origin" "reply_to_origin"
    (stored_delivery |> member "policy" |> to_string);
  check bool "exact invoking route is persisted" true
    (Yojson.Safe.equal
       (stored_delivery |> member "channel")
       (Keeper_continuation_channel.to_yojson channel));
  let stored_body_fields =
    Tool_result.data result
    |> member "payload"
    |> member "body"
    |> to_assoc
  in
  check int "forged duplicate delivery fields are replaced once" 1
    (List.fold_left
       (fun count (name, _) ->
          if String.equal name "result_delivery" then count + 1 else count)
       0
       stored_body_fields);
  let request =
    match
      Schedule_store.get_schedule
        config
        ~schedule_id:"sched-owned-result-destination"
    with
    | Some request -> request
    | None -> fail "routed schedule was not persisted"
  in
  (match Schedule_payload_projection.result_delivery request with
   | Ok (Some persisted) ->
     check bool "typed projection preserves exact route" true
       (Keeper_continuation_channel.same_route channel persisted)
   | Ok None -> fail "routed schedule lost its result destination"
   | Error detail -> fail detail)
;;

let test_get_recurring_schedule_after_accept_advance () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-recurring-get-after-accept" in
  let request : Schedule_domain.schedule_request =
    create_service_exn
      config
      ~schedule_id
      ~due_at:200.0
      ~payload:(keeper_wake_payload "run every minute")
      ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
      ()
  in
  (match Schedule_store.refresh_due config ~now:200.0 with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  (match Schedule_store.start_due_candidate config ~now:201.0 ~schedule_id with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  let advanced : Schedule_domain.schedule_request =
    match Schedule_store.accept_running config ~now:202.0 ~schedule_id () with
    | Ok stored -> stored
    | Error err -> fail (Schedule_store.store_error_to_string err)
  in
  check bool "recurring request advanced past the fired occurrence" true
    (advanced.due_at > request.due_at);
  let get_result =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String schedule_id ])
  in
  check bool "advanced recurring request remains readable" true
    (Tool_result.is_success get_result);
  let open Yojson.Safe.Util in
  check (float 0.001) "get returns the current next occurrence" advanced.due_at
    (Tool_result.data get_result |> member "due_at" |> to_float)
;;

let test_create_accepts_explicit_iso8601_offset () =
  with_config
  @@ fun config ->
  let create ~schedule_id ~due_at_iso =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "due_at_iso", `String due_at_iso
        ; "payload_kind", `String Schedule_supported_kinds.keeper_wake
        ; ( "payload_body"
          , `Assoc
              [ "keeper_name", `String "schedule-keeper"
              ; "message", `String "run at nine in Korea"
              ] )
        ])
  in
  let result =
    create
      ~schedule_id:"sched-kst-offset"
      ~due_at_iso:"2026-08-02T09:00:00+09:00"
  in
  check bool "explicit ISO-8601 offset accepted" true (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  check string "offset normalized to UTC" "2026-08-02T00:00:00Z"
    (Tool_result.data result |> member "due_at_iso" |> to_string);
  let west =
    create
      ~schedule_id:"sched-west-offset"
      ~due_at_iso:"2099-01-02T00:30:00-03:30"
  in
  check bool "negative ISO-8601 offset accepted" true (Tool_result.is_success west);
  check string "negative offset normalized to UTC" "2099-01-02T04:00:00Z"
    (Tool_result.data west |> member "due_at_iso" |> to_string);
  let fractional =
    create
      ~schedule_id:"sched-fractional-offset"
      ~due_at_iso:"2099-01-02T09:00:00.123456789+09:00"
  in
  check bool "fractional RFC 3339 accepted" true (Tool_result.is_success fractional);
  check string "fraction normalized to whole-second UTC" "2099-01-02T00:00:00Z"
    (Tool_result.data fractional |> member "due_at_iso" |> to_string);
  let near_boundary =
    create
      ~schedule_id:"sched-fraction-boundary"
      ~due_at_iso:"2099-01-02T09:00:00.999999999999+09:00"
  in
  check bool "near-boundary fraction accepted" true
    (Tool_result.is_success near_boundary);
  check string "fraction truncates before float conversion" "2099-01-02T00:00:00Z"
    (Tool_result.data near_boundary |> member "due_at_iso" |> to_string);
  let non_rfc3339 =
    create
      ~schedule_id:"sched-non-rfc3339-offset"
      ~due_at_iso:"2099-01-02T09:00:00+0900"
  in
  check bool "offset without colon rejected" false (Tool_result.is_success non_rfc3339);
  let invalid =
    create
      ~schedule_id:"sched-invalid-date"
      ~due_at_iso:"2099-02-29T09:00:00+09:00"
  in
  check bool "invalid civil date rejected" false (Tool_result.is_success invalid);
  check bool "invalid date error is explicit" true
    (String_util.contains_substring
       (Tool_result.message invalid)
       "due_at_iso must be")
;;

let test_removed_convenience_input_does_not_synthesize_payload () =
  with_config
  @@ fun config ->
  let result =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-removed-convenience"
        ; "due_at_unix", `Float 200.0
        ; "board_content", `String "must not become a scheduled product effect"
        ; "requested_by_id", `String "operator"
        ; "scheduled_by_id", `String "scheduler-agent"
        ])
  in
  check bool "removed convenience input rejected" false (Tool_result.is_success result);
  check bool "neutral payload contract names the missing field" true
    (String_util.contains_substring
       (Tool_result.message result)
       "payload_kind is required");
  check int "removed convenience input is not persisted" 0
    (List.length (Schedule_store.read_state config).schedules)
;;

let test_unregistered_wake_target_rejected () =
  with_config
  @@ fun config ->
  let ghost_args allow =
    `Assoc
      ([ "schedule_id", `String "sched-ghost-target"
       ; "due_at_unix", `Float 200.0
       ; "payload_kind", `String Schedule_supported_kinds.keeper_wake
       ; ( "payload_body"
         , `Assoc
             [ "keeper_name", `String "ghost-keeper"
             ; "message", `String "wake for a keeper that does not exist"
             ] )
       ; "requested_by_id", `String "operator"
       ; "scheduled_by_id", `String "scheduler-agent"
       ]
       @ if allow then [ "allow_unregistered_keeper", `Bool true ] else [])
  in
  let rejected = dispatch_exn config Tool_schemas_schedule.Create_request (ghost_args false) in
  check bool "unregistered wake target rejected" false (Tool_result.is_success rejected);
  check bool "rejection names the missing keeper metadata" true
    (String_util.contains_substring
       (Tool_result.message rejected)
       "has no durable metadata");
  check int "rejected schedule is not persisted" 0
    (List.length (Schedule_store.read_state config).schedules);
  let allowed = dispatch_exn config Tool_schemas_schedule.Create_request (ghost_args true) in
  check bool "explicit opt-in schedules the unregistered target" true
    (Tool_result.is_success allowed);
  check int "opted-in schedule persisted" 1
    (List.length (Schedule_store.read_state config).schedules)
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
      ~payload:(keeper_wake_payload "signal me") ()
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
  check string "signal schedule instance" request.schedule_instance_id
    signal.schedule_instance_id;
  let signal_json =
    match
      Dated_jsonl.read_recent
        (Dated_jsonl.create ~base_dir:(Schedule_runner.signals_dir config) ())
        1
    with
    | [ row ] -> row
    | rows -> failf "expected one persisted wake signal, got %d" (List.length rows)
  in
  check int "signal field count" 8
    (Yojson.Safe.Util.to_assoc signal_json |> List.length);
  (match Schedule_runner.wake_signal_of_yojson signal_json with
   | Ok persisted ->
     check string "persisted signal request" signal.schedule_id persisted.schedule_id
   | Error detail -> failf "persisted wake signal did not decode: %s" detail);
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
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
  Workspace_core.write_text
    config
    (Filename.concat (Workspace_utils.masc_dir config) "schedules.json")
    "{not-json";
  let result =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc [])
  in
  check bool "list fails" false (Tool_result.is_success result);
  check bool "store failure visible" true
    (String_util.contains_substring
       (Tool_result.message result)
       "schedule store read failed")
;;

let test_keeper_wake_target_validation_is_inside_creation_fence () =
  with_config
  @@ fun config ->
  let fence_active = ref false in
  let validation_saw_fence = ref false in
  let registered_target_check =
    Atomic.get Workspace_hooks.schedule_wake_target_registered_fn
  in
  Atomic.set Workspace_hooks.schedule_wake_target_registered_fn
    (fun config keeper_name ->
       if !fence_active then validation_saw_fence := true;
       registered_target_check config keeper_name);
  let admit_keeper_wake_creation config ~keeper_name create =
    Keeper_schedule_creation_admission.run config ~keeper_name (fun () ->
      fence_active := true;
      Fun.protect ~finally:(fun () -> fence_active := false) create)
  in
  let ctx : Tool_schedule.context =
    { config
    ; agent_name = "scheduler-agent"
    ; stamp_keeper_wake_result_delivery =
        (fun ~payload ->
           Schedule_payload_projection.set_keeper_wake_result_delivery
             ~payload
             ~channel:None)
    ; admit_keeper_wake_creation
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.schedule_wake_target_registered_fn
        registered_target_check)
    (fun () ->
       let result =
         match
           Tool_schedule.dispatch
             ctx
             ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
             ~args:(create_args ~schedule_id:"sched-fenced-validation" ())
         with
         | Some result -> result
         | None -> fail "schedule dispatch returned None"
       in
       check bool "fenced schedule creation succeeds" true
         (Tool_result.is_success result);
       check bool "target validation ran inside creation fence" true
         !validation_saw_fence)
;;

let test_keeper_wake_creation_respects_shutdown_fence () =
  with_config
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace.base_path in
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
       let result =
         dispatch_exn config Tool_schemas_schedule.Create_request
           (create_args
              ~schedule_id:"sched-shutdown-fenced"
              ~allow_unregistered_keeper:true
              ())
       in
       check bool "shutdown-fenced schedule creation fails" false
         (Tool_result.is_success result);
       check string "shutdown fence failure is explicit"
         (Printf.sprintf
            "schedule creation rejected by Keeper shutdown fence keeper=%s operation=%s"
            keeper_name
            (Keeper_shutdown_types.Operation_id.to_string operation_id))
         (Tool_result.message result);
       check int "shutdown-fenced schedule is not persisted" 0
         (List.length (Schedule_store.read_state config).schedules))
;;

(* A schedule-ledger read failure must reach the operator as "we could not
   read it", never as zero schedules. The projection reports it as a typed
   fact: status unknown, every count null, and the reason carried alongside. *)
let test_projection_reports_read_failure_as_unknown () =
  with_config
  @@ fun config ->
  Workspace_core.write_text
    config
    (Filename.concat (Workspace_utils.masc_dir config) "schedules.json")
    "{not-json";
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "status is unknown" "unknown"
    (dashboard |> member "status" |> to_string);
  check bool "store is not claimed as known" false
    (dashboard |> member "schedule_store_known" |> to_bool);
  check bool "read error is reported" true
    (String_util.contains_substring
       (dashboard |> member "schedule_store_read_error" |> to_string)
       "schedule store read failed");
  check bool "counts stay null rather than zero" true
    (dashboard |> member "counts" = `Null);
  check bool "request_count stays null rather than zero" true
    (dashboard |> member "request_count" = `Null);
  check bool "fsm active_count stays null rather than zero" true
    (dashboard |> member "fsm" |> member "active_count" = `Null)
;;

(* The projection used to ride along inside the tool inventory, so any surface
   that needed schedule state pulled the whole tool registry. It now has its
   own route and must not reappear as a nested field. *)
let test_tools_response_no_longer_carries_the_projection () =
  with_config
  @@ fun config ->
  let tools = Server_dashboard_http_runtime_info.dashboard_tools_http_json config in
  let fields =
    match tools with
    | `Assoc fields -> List.map fst fields
    | _ -> failf "tools projection is not an object"
  in
  check bool "scheduled_automation is not nested in tools" false
    (List.mem "scheduled_automation" fields)
;;

let test_tool_response_carries_structured_recurrence () =
  with_config
  @@ fun config ->
  (* The dashboard projection and the tool response describe the same
     `schedule_request`. Sending only `recurrence_kind` here made the client
     rebuild the structure from flattened strings, with an unknown-shape
     fallback at the end of that chain. *)
  let recurrence = Schedule_domain.Interval { interval_sec = 60 } in
  let _request =
    create_service_exn
      config
      ~schedule_id:"sched-structured-recurrence"
      ~due_at:200.0
      ~payload:(keeper_wake_payload "every minute")
      ~recurrence
      ()
  in
  let listed =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc [])
  in
  let open Yojson.Safe.Util in
  let entry =
    Tool_result.data listed
    |> member "schedules"
    |> to_list
    |> List.find (fun item ->
      match item |> member "schedule_id" with
      | `String id -> String.equal id "sched-structured-recurrence"
      | _ -> false)
  in
  check bool "recurrence is present" true (entry |> member "recurrence" <> `Null);
  check string "recurrence matches the domain serialiser"
    (Yojson.Safe.to_string (Schedule_domain.recurrence_to_yojson recurrence))
    (Yojson.Safe.to_string (entry |> member "recurrence"))
;;

let () =
  run "Schedule_tool_wiring"
    [ ( "wiring"
      , [ test_case "flat tool surface" `Quick test_flat_tool_surface
        ; test_case "create list get cancel" `Quick test_create_list_get_cancel
        ; test_case "creation boundary owns result delivery destination" `Quick
            test_creation_boundary_owns_result_delivery_destination
        ; test_case "get recurring schedule after accept advance" `Quick
            test_get_recurring_schedule_after_accept_advance
        ; test_case "create accepts explicit ISO-8601 offset" `Quick
            test_create_accepts_explicit_iso8601_offset
        ; test_case "removed convenience input does not synthesize payload" `Quick
            test_removed_convenience_input_does_not_synthesize_payload
        ; test_case "unregistered wake target rejected" `Quick
            test_unregistered_wake_target_rejected
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
        ; test_case "projection reports read failure as unknown" `Quick
            test_projection_reports_read_failure_as_unknown
        ; test_case "tools response no longer carries the projection" `Quick
            test_tools_response_no_longer_carries_the_projection
        ; test_case "Keeper wake target validation is fenced" `Quick
            test_keeper_wake_target_validation_is_inside_creation_fence
        ; test_case "Keeper wake creation respects shutdown fence" `Quick
            test_keeper_wake_creation_respects_shutdown_fence
        ; test_case "tool response carries structured recurrence" `Quick
            test_tool_response_carries_structured_recurrence
        ] )
    ]
;;
