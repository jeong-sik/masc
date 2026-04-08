open Masc_mcp
open Test_tool_team_session_support

let test_start_status_report_stop () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());

  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in

  let start_json =
    start_session_exn ctx
      ~goal:"Run coordinated team session and capture report"
  in
  Alcotest.(check string) "start status ok" "ok"
    (Yojson.Safe.Util.member "status" start_json |> Yojson.Safe.Util.to_string);
  let session_id = get_session_id start_json in

  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let status_json = parse_json_exn status_body in
  let status_result = result_field status_json in
  Alcotest.(check string) "status wrapper" "ok"
    (Yojson.Safe.Util.member "status" status_json |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "fresh session health is not critical" "healthy"
    (status_result |> Yojson.Safe.Util.member "team_health"
     |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "fresh session has visible active participants" true
    ((status_result |> Yojson.Safe.Util.member "summary"
      |> Yojson.Safe.Util.member "active_agents_count" |> Yojson.Safe.Util.to_int) > 0);
  Alcotest.(check bool) "fresh session has visible seen participants" true
    ((status_result |> Yojson.Safe.Util.member "summary"
      |> Yojson.Safe.Util.member "seen_agents_count" |> Yojson.Safe.Util.to_int) > 0);
  Alcotest.(check bool) "team_health present" true
    (Yojson.Safe.Util.member "team_health" status_result <> `Null);
  Alcotest.(check bool) "communication_metrics present" true
    (Yojson.Safe.Util.member "communication_metrics" status_result <> `Null);
  Alcotest.(check bool) "orchestration_state present" true
    (Yojson.Safe.Util.member "orchestration_state" status_result <> `Null);
  Alcotest.(check bool) "cascade_metrics present" true
    (Yojson.Safe.Util.member "cascade_metrics" status_result <> `Null);
  let report_ok, report_body =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [ ("session_id", `String session_id); ("force_regenerate", `Bool true) ])
  in
  Alcotest.(check bool) "report ok" true report_ok;
  let report_json = parse_json_exn report_body in
  let report_result = result_field report_json in
  let md_path =
    report_result |> Yojson.Safe.Util.member "markdown_path"
    |> Yojson.Safe.Util.to_string
  in
  let json_path =
    report_result |> Yojson.Safe.Util.member "json_path"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "markdown exists" true
    (Room_utils.path_exists config md_path);
  Alcotest.(check bool) "json report exists" true
    (Room_utils.path_exists config json_path);
  let report_doc = Room_utils.read_json config json_path in
  let report_schema_version =
    report_doc |> Yojson.Safe.Util.member "schema_version"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "report schema version" "1.0.0"
    report_schema_version;
  let stop_ok, stop_body =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "test_complete");
            ("generate_report", `Bool true);
          ])
  in
  Alcotest.(check bool) "stop accepted" true stop_ok;
  let stop_json = parse_json_exn stop_body in
  Alcotest.(check string) "stop wrapper" "ok"
    (Yojson.Safe.Util.member "status" stop_json |> Yojson.Safe.Util.to_string);
  let final_status = wait_until_terminal ctx session_id in
  Alcotest.(check bool) "terminal status" true
    (final_status = "interrupted" || final_status = "completed"
   || final_status = "failed");

  cleanup_dir base_dir

let test_start_attached_operation_session () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  ignore (Room.join config ~agent_name:"ally1" ~capabilities:[] ());
  ignore (Room.join config ~agent_name:"ally2" ~capabilities:[] ());
  unit_update_exn config ~actor:"tester"
    (`Assoc
      [
        ("unit_id", `String "company-main");
        ("kind", `String "company");
        ("label", `String "Main Company");
        ("leader_id", `String "tester");
        ("roster", `List [ `String "tester"; `String "ally1"; `String "ally2" ]);
      ]);
  unit_update_exn config ~actor:"tester"
    (`Assoc
      [
        ("unit_id", `String "platoon-main");
        ("kind", `String "platoon");
        ("label", `String "Main Platoon");
        ("parent_unit_id", `String "company-main");
        ("leader_id", `String "ally1");
        ("roster", `List [ `String "ally1"; `String "ally2" ]);
      ]);
  unit_update_exn config ~actor:"tester"
    (`Assoc
      [
        ("unit_id", `String "squad-main");
        ("kind", `String "squad");
        ("label", `String "Main Squad");
        ("parent_unit_id", `String "platoon-main");
        ("leader_id", `String "tester");
        ("roster", `List [ `String "tester" ]);
      ]);
  let operation : Command_plane_v2.operation_record =
    {
      operation_id = "op-attached-session";
      objective = "Run attached coding team";
      intent_id = None;
      assigned_unit_id = "squad-main";
      policy_class = "guarded";
      budget_class = "standard";
      workload_template = Some "coding_team";
      workload_profile = "coding_task";
      stage = Some "decompose";
      artifact_scope = [];
      depends_on_operation_ids = [];
      search_strategy = "best_first_v1";
      detachment_session_id = None;
      trace_id = "trace-attached-session";
      checkpoint_ref = None;
      active_goal_ids = [];
      note = None;
      created_by = "tester";
      source = "managed";
      status = Command_plane_v2.Active;
      created_at = Types.now_iso ();
      updated_at = Types.now_iso ();
    }
  in
  Command_plane_v2.write_operations config [ operation ];
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let start_json =
    start_session_custom_exn ctx ~goal:"Attach managed session" ~min_agents:1
      ~agents:[ "tester" ] ~operation_id:(Some operation.operation_id)
  in
  let session_id = get_session_id start_json in
  let start_result = result_field start_json in
  Alcotest.(check string) "attached operation id in start result"
    operation.operation_id
    (start_result |> Yojson.Safe.Util.member "operation_id"
    |> Yojson.Safe.Util.to_string);
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let status_json = parse_json_exn status_body |> result_field in
  Alcotest.(check string) "attached operation id in status"
    operation.operation_id
    (status_json |> Yojson.Safe.Util.member "command_plane"
    |> Yojson.Safe.Util.member "operation_id"
    |> Yojson.Safe.Util.to_string);
  let operation_rows =
    Command_plane_v2.list_operations_json ~operation_id:operation.operation_id
      config
    |> Yojson.Safe.Util.member "operations"
    |> Yojson.Safe.Util.to_list
  in
  let attached_session_id =
    match operation_rows with
    | row :: _ ->
        row |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "detachment_session_id"
        |> Yojson.Safe.Util.to_string_option
    | [] -> None
  in
  Alcotest.(check (option string)) "operation linked to session"
    (Some session_id) attached_session_id;
  let second_ok, second_body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String "Duplicate attach should fail");
            ("duration_seconds", `Int 90);
            ("checkpoint_interval_sec", `Int 10);
            ("min_agents", `Int 1);
            ("operation_id", `String operation.operation_id);
          ])
  in
  Alcotest.(check bool) "second attach rejected" false second_ok;
  let second_json = parse_json_exn second_body in
  Alcotest.(check bool) "second attach error mentions existing session" true
    (match Yojson.Safe.Util.member "message" second_json with
    | `String message -> String.starts_with ~prefix:"operation already attached to team session" message
    | _ -> false);
  let finalize_ok, finalize_body =
    dispatch_exn ctx ~name:"masc_team_session_finalize"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "complete attached session");
            ("generate_report", `Bool false);
            ("generate_proof", `Bool false);
            ("wait_timeout_sec", `Int 5);
          ])
  in
  Alcotest.(check bool) "finalize ok" true finalize_ok;
  let finalized_status =
    finalize_body |> parse_json_exn |> result_field
    |> Yojson.Safe.Util.member "terminal_status"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "terminal status after finalize" true
    (finalized_status = "completed" || finalized_status = "interrupted");
  let operation_rows_after_finalize =
    Command_plane_v2.list_operations_json ~operation_id:operation.operation_id
      config
    |> Yojson.Safe.Util.member "operations"
    |> Yojson.Safe.Util.to_list
  in
  let detached_session_id =
    match operation_rows_after_finalize with
    | row :: _ ->
        row |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "detachment_session_id"
        |> Yojson.Safe.Util.to_string_option
    | [] -> None
  in
  Alcotest.(check (option string)) "operation detached after finalize" None
    detached_session_id;
  let detachment_json =
    match
      Command_plane_v2.detachment_status_json config
        (`Assoc [ ("operation_id", `String operation.operation_id) ])
    with
    | Ok json -> json |> result_field
    | Error err -> Alcotest.failf "detachment status failed: %s" err
  in
  Alcotest.(check (option string)) "detachment session cleared after finalize"
    None
    (detachment_json |> Yojson.Safe.Util.member "detachment"
    |> Yojson.Safe.Util.member "session_id"
    |> Yojson.Safe.Util.to_string_option);
  Alcotest.(check string) "detachment runtime kind falls back to managed"
    "managed"
    (detachment_json |> Yojson.Safe.Util.member "detachment"
    |> Yojson.Safe.Util.member "runtime_kind"
    |> Yojson.Safe.Util.to_string);
  let reattach_ok, reattach_body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String "Reattach after finalize");
            ("duration_seconds", `Int 90);
            ("checkpoint_interval_sec", `Int 10);
            ("min_agents", `Int 1);
            ("operation_id", `String operation.operation_id);
          ])
  in
  Alcotest.(check bool) "reattach succeeds after finalize" true reattach_ok;
  let reattach_session_id = reattach_body |> parse_json_exn |> get_session_id in
  Alcotest.(check bool) "reattach gives new session id" true
    (not (String.equal reattach_session_id session_id));
  cleanup_dir base_dir

let test_duration_reached_path () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let start_json =
    start_session_exn ctx ~goal:"exercise duration_reached branch"
  in
  let session_id = get_session_id start_json in
  ignore
    (unwrap_ok
       (Team_session_store.update_session config session_id (fun s ->
            {
              s with
              planned_end_at = Time_compat.now () -. 0.2;
              updated_at_iso = Types.now_iso ();
            })));
  let status = wait_until_terminal ctx session_id in
  Alcotest.(check string) "completed by duration" "completed" status;
  cleanup_dir base_dir

let test_recover_elapsed_session () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let session_id = Team_session_store.make_session_id () in
  Team_session_store.ensure_session_dirs config session_id;
  let now = Time_compat.now () in
  let session : Team_session_types.session =
    {
      session_id;
      goal = "recover elapsed session";
      created_by = "tester";
      origin_kind = Team_session_types.Origin_human;
      room_id = "default";
      operation_id = None;
      status = Team_session_types.Running;
      duration_seconds = 60;
      execution_scope = Team_session_types.Observe_only;
      checkpoint_interval_sec = 10;
      min_agents = 1;
      orchestration_mode = Team_session_types.Assist;
      communication_mode = Team_session_types.Comm_broadcast;
      scale_profile = Team_session_types.Scale_standard;
      control_profile = Team_session_types.Control_flat;
      model_cascade = [ "glm:auto" ];
      fallback_policy = Team_session_types.Fallback_cascade_then_task;
      instruction_profile = Team_session_types.Profile_standard;
      alert_channel = Team_session_types.Alert_both;
      auto_resume = true;
      report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
      turn_count = 0;
      agent_names = [ "tester" ];
      planned_workers = [];
      broadcast_count = 0;
      portal_count = 0;
      cascade_attempted = 0;
      cascade_success = 0;
      cascade_failed = 0;
      fallback_task_created = 0;
      min_agents_violation_streak = 0;
      policy_violations = [];
      baseline_done_counts = [];
      final_done_delta_total = None;
      final_done_delta_by_agent = None;
      started_at = now -. 120.0;
      planned_end_at = now -. 5.0;
      stopped_at = None;
      last_checkpoint_at = Some (now -. 30.0);
      last_event_at = Some (now -. 30.0);
      last_turn_at = None;
      stop_reason = None;
      generated_report = false;
      delivery_contract = None;
      latest_delivery_verdict = None;
      artifacts_dir = Team_session_store.session_dir config session_id;
      created_at_iso = Types.now_iso ();
      updated_at_iso = Types.now_iso ();
    }
  in
  Team_session_store.save_session config session;
  Team_session_engine_eio.recover_running_sessions ~sw
    ~env ~config;
  let rec wait_loaded attempts =
    if attempts <= 0 then
      failwith "missing session after recover"
    else
      match Team_session_store.load_session config session_id with
      | Some s -> s
      | None ->
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
          wait_loaded (attempts - 1)
  in
  let reloaded = wait_loaded 100 in
  Alcotest.(check string) "recovered status" "completed"
    (Team_session_types.status_to_string reloaded.status);
  Alcotest.(check bool) "report json exists" true
    (Room_utils.path_exists config
       (Team_session_store.report_json_path config session_id));
  cleanup_dir base_dir
