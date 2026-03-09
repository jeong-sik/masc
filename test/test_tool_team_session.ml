open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_tool_team_session_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let dispatch_exn ctx ~name ~args =
  match Tool_team_session.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let result_field json = Yojson.Safe.Util.member "result" json

let unwrap_ok = function
  | Ok v -> v
  | Error e -> failwith e

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
  | Some v -> Unix.putenv name v
  | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let get_session_id response_json =
  response_json |> result_field |> Yojson.Safe.Util.member "session_id"
  |> Yojson.Safe.Util.to_string

let session_status_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "session" |> Yojson.Safe.Util.member "status"
  |> Yojson.Safe.Util.to_string

let done_delta_total_of_status_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "summary"
  |> Yojson.Safe.Util.member "done_delta_total"
  |> Yojson.Safe.Util.to_int

let events_count_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int

let events_list_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "events" |> Yojson.Safe.Util.to_list

let add_task_id config ~title =
  ignore (Room.add_task config ~title ~priority:1 ~description:"");
  let backlog = Room.read_backlog config in
  match List.rev backlog.tasks with
  | t :: _ -> t.id
  | [] -> failwith "failed to create task"

let transition_task_ok config ~agent_name ~task_id ~action =
  match Room.transition_task_r config ~agent_name ~task_id ~action () with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e)

let wait_until_terminal ctx session_id =
  let rec loop attempts =
    if attempts <= 0 then
      failwith "team session did not reach terminal state in time"
    else
      let ok, body =
        dispatch_exn ctx ~name:"masc_team_session_status"
          ~args:(`Assoc [ ("session_id", `String session_id) ])
      in
      if not ok then
        failwith "status check failed while waiting for terminal state"
      else
        match session_status_of_body body with
        | "running" ->
            Eio.Time.sleep ctx.clock 0.1;
            loop (attempts - 1)
        | status -> status
  in
  loop 200

let rec start_session_exn ctx ~goal =
  start_session_custom_exn ctx ~goal ~min_agents:1 ~agents:[]

and start_session_custom_exn ctx ~goal ~min_agents ~agents =
  let agent_json = `List (List.map (fun a -> `String a) agents) in
  let start_ok, start_body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String goal);
            ("duration_seconds", `Int 90);
            ("checkpoint_interval_sec", `Int 10);
            ("min_agents", `Int min_agents);
            ("orchestration_mode", `String "assist");
            ("communication_mode", `String "hybrid");
            ("model_cascade", `List [ `String "glm:glm-5" ]);
            ("fallback_policy", `String "cascade_then_task");
            ("instruction_profile", `String "strict");
            ("alert_channel", `String "both");
            ("report_formats", `List [ `String "markdown"; `String "json" ]);
            ("agents", agent_json);
          ])
  in
  Alcotest.(check bool) "start ok" true start_ok;
  parse_json_exn start_body

let make_manual_session config ~goal ~created_by ~agent_names ~min_agents
    ~checkpoint_interval_sec ~started_at ~planned_end_at ~fallback_policy
    ~model_cascade =
  let session_id = Team_session_store.make_session_id () in
  Team_session_store.ensure_session_dirs config session_id;
  let session : Team_session_types.session =
    {
      session_id;
      goal;
      created_by;
      room_id = "default";
      status = Team_session_types.Running;
      duration_seconds = int_of_float (max 60.0 (planned_end_at -. started_at));
      execution_scope = Team_session_types.Limited_code_change;
      checkpoint_interval_sec;
      min_agents;
      orchestration_mode = Team_session_types.Assist;
      communication_mode = Team_session_types.Comm_broadcast;
      scale_profile = Team_session_types.Scale_standard;
      control_profile = Team_session_types.Control_flat;
      model_cascade;
      fallback_policy;
      instruction_profile = Team_session_types.Profile_strict;
      alert_channel = Team_session_types.Alert_both;
      auto_resume = true;
      report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
      turn_count = 0;
      agent_names;
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
      started_at;
      planned_end_at;
      stopped_at = None;
      last_checkpoint_at = Some started_at;
      last_event_at = Some started_at;
      last_turn_at = None;
      stop_reason = None;
      generated_report = false;
      artifacts_dir = Team_session_store.session_dir config session_id;
      created_at_iso = Types.now_iso ();
      updated_at_iso = Types.now_iso ();
    }
  in
  Team_session_store.save_session config session;
  session

let test_start_status_report_stop () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());

  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
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
  Alcotest.(check bool) "team_health present" true
    (Yojson.Safe.Util.member "team_health" status_result <> `Null);
  Alcotest.(check bool) "communication_metrics present" true
    (Yojson.Safe.Util.member "communication_metrics" status_result <> `Null);
  Alcotest.(check bool) "orchestration_state present" true
    (Yojson.Safe.Util.member "orchestration_state" status_result <> `Null);
  Alcotest.(check bool) "cascade_metrics present" true
    (Yojson.Safe.Util.member "cascade_metrics" status_result <> `Null);
  Alcotest.(check bool) "llm_cache_metrics present" true
    (Yojson.Safe.Util.member "llm_cache_metrics" status_result <> `Null);

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
  Alcotest.(check bool) "markdown exists" true (Sys.file_exists md_path);
  Alcotest.(check bool) "json report exists" true
    (Room_utils.path_exists config json_path);
  let report_doc = Room_utils.read_json config json_path in
  let report_schema_version =
    report_doc |> Yojson.Safe.Util.member "schema_version"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "report schema version" "1.0.0"
    report_schema_version;
  Alcotest.(check bool) "report llm_cache_metrics present" true
    (Yojson.Safe.Util.member "llm_cache_metrics" report_doc <> `Null);

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

let test_duration_reached_path () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
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
  Eio_main.run @@ fun env ->
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
      room_id = "default";
      status = Team_session_types.Running;
      duration_seconds = 60;
      execution_scope = Team_session_types.Observe_only;
      checkpoint_interval_sec = 10;
      min_agents = 1;
      orchestration_mode = Team_session_types.Assist;
      communication_mode = Team_session_types.Comm_broadcast;
      scale_profile = Team_session_types.Scale_standard;
      control_profile = Team_session_types.Control_flat;
      model_cascade = [ "glm:glm-5" ];
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
      artifacts_dir = Team_session_store.session_dir config session_id;
      created_at_iso = Types.now_iso ();
      updated_at_iso = Types.now_iso ();
    }
  in
  Team_session_store.save_session config session;
  Team_session_engine_eio.recover_running_sessions ~sw
    ~clock:(Eio.Stdenv.clock env) ~config;
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

let test_read_events_limit () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let session_id = Team_session_store.make_session_id () in
  Team_session_store.ensure_session_dirs config session_id;
  for i = 1 to 20 do
    Team_session_store.append_event config session_id ~event_type:"unit_test_event"
      ~detail:(`Assoc [ ("seq", `Int i) ])
  done;
  let events = Team_session_store.read_events ~max_events:5 config session_id in
  Alcotest.(check int) "limited events length" 5 (List.length events);
  let seqs =
    events
    |> List.map (fun json ->
           match
             Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "seq"
           with
           | `Int n -> n
           | _ -> -1)
  in
  Alcotest.(check (list int)) "tail events kept" [ 16; 17; 18; 19; 20 ] seqs;
  cleanup_dir base_dir

let test_list_and_compare () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in

  let s1 = start_session_exn ctx ~goal:"compare-session-base" |> get_session_id in
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String s1);
             ("reason", `String "base_stop");
             ("generate_report", `Bool false);
           ]));
  ignore (wait_until_terminal ctx s1);

  let s2 = start_session_exn ctx ~goal:"compare-session-target" |> get_session_id in

  let list_ok, list_body =
    dispatch_exn ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("limit", `Int 10) ])
  in
  Alcotest.(check bool) "list ok" true list_ok;
  let list_json = parse_json_exn list_body in
  let sessions =
    list_json |> result_field |> Yojson.Safe.Util.member "sessions"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check bool) "list has sessions" true (List.length sessions >= 2);

  let cmp_ok, cmp_body =
    dispatch_exn ctx ~name:"masc_team_session_compare"
      ~args:
        (`Assoc
          [
            ("base_session_id", `String s1);
            ("target_session_id", `String s2);
          ])
  in
  Alcotest.(check bool) "compare ok" true cmp_ok;
  let cmp_json = parse_json_exn cmp_body |> result_field in
  Alcotest.(check string) "compare base" s1
    (Yojson.Safe.Util.member "base_session_id" cmp_json
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "compare target" s2
    (Yojson.Safe.Util.member "target_session_id" cmp_json
    |> Yojson.Safe.Util.to_string);

  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String s2);
             ("reason", `String "target_stop");
             ("generate_report", `Bool false);
           ]));
  cleanup_dir base_dir

let test_turn_events_and_prove () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"turn-events-prove" |> get_session_id in

  let invalid_turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "invalid-kind");
          ])
  in
  Alcotest.(check bool) "invalid turn kind rejected" false invalid_turn_ok;
  let empty_note_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
          ])
  in
  Alcotest.(check bool) "empty note rejected" false empty_note_ok;

  let engine_intruder_result =
    Team_session_engine_eio.record_turn ~config ~session_id ~actor:"intruder"
      ~turn_kind:Team_session_types.Turn_note ~message:(Some "unauthorized")
      ~target_agent:None ~task_title:None ~task_description:None
      ~task_priority:3
  in
  Alcotest.(check bool) "engine actor guard"
    true
    (match engine_intruder_result with Error _ -> true | Ok _ -> false);

  let check_turn turn_kind extra =
    let ok, _ =
      dispatch_exn ctx ~name:"masc_team_session_turn"
        ~args:
          (`Assoc
            ([
               ("session_id", `String session_id);
               ("turn_kind", `String turn_kind);
             ]
            @ extra))
    in
    Alcotest.(check bool) ("turn ok: " ^ turn_kind) true ok
  in
  check_turn "note" [ ("message", `String "manual note") ];
  check_turn "broadcast" [ ("message", `String "broadcast turn message") ];
  check_turn "portal"
    [
      ("target_agent", `String "peer");
      ("message", `String "portal task payload");
    ];
  check_turn "task"
    [
      ("task_title", `String "turn-created-task");
      ("task_description", `String "from turn tool");
      ("task_priority", `Int 2);
    ];
  check_turn "checkpoint" [];

  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_turn" ]);
            ("limit", `Int 20);
          ])
  in
  Alcotest.(check bool) "events ok" true events_ok;
  Alcotest.(check int) "team_turn count" 5 (events_count_of_body events_body);

  let stop_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "prove_ready");
            ("generate_report", `Bool true);
          ])
  in
  Alcotest.(check bool) "stop accepted" true stop_ok;
  ignore (wait_until_terminal ctx session_id);

  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("generate_report_if_missing", `Bool true);
          ])
  in
  Alcotest.(check bool) "prove ok" true prove_ok;
  let prove_result = parse_json_exn prove_body |> result_field in
  let proof_json_path =
    prove_result |> Yojson.Safe.Util.member "proof_json_path"
    |> Yojson.Safe.Util.to_string
  in
  let proof_md_path =
    prove_result |> Yojson.Safe.Util.member "proof_md_path"
    |> Yojson.Safe.Util.to_string
  in
  let verdict =
    prove_result |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "verdict"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "proof json exists" true
    (Room_utils.path_exists config proof_json_path);
  Alcotest.(check bool) "proof md exists" true (Sys.file_exists proof_md_path);
  Alcotest.(check string) "verdict proved" "proved" verdict;
  let proof_doc = Room_utils.read_json config proof_json_path in
  let proof_schema_version =
    proof_doc |> Yojson.Safe.Util.member "schema_version"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "proof schema version" "1.0.0"
    proof_schema_version;
  cleanup_dir base_dir

let test_step_plain_turn_matches_legacy_turn () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let legacy_session_id =
    start_session_exn ctx ~goal:"legacy-turn-parity" |> get_session_id
  in
  let legacy_ok, legacy_body =
    dispatch_exn ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String legacy_session_id);
            ("turn_kind", `String "note");
            ("message", `String "legacy note");
          ])
  in
  Alcotest.(check bool) "legacy turn ok" true legacy_ok;
  let legacy_turn = parse_json_exn legacy_body |> result_field in
  Alcotest.(check string) "legacy kind" "note"
    Yojson.Safe.Util.(legacy_turn |> member "kind" |> to_string);

  let step_session_id =
    start_session_exn ctx ~goal:"step-turn-parity" |> get_session_id
  in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String step_session_id);
            ("turn_kind", `String "note");
            ("message", `String "step note");
          ])
  in
  Alcotest.(check bool) "step turn ok" true step_ok;
  let step_turn =
    parse_json_exn step_body |> result_field |> Yojson.Safe.Util.member "turn"
  in
  Alcotest.(check string) "step kind" "note"
    Yojson.Safe.Util.(step_turn |> member "kind" |> to_string);
  Alcotest.(check bool) "step spawn null" true
    (parse_json_exn step_body |> result_field |> Yojson.Safe.Util.member "spawn"
    = `Null);

  let team_turn_detail_exn session_id =
    match
      List.find_opt
        (fun json ->
          Yojson.Safe.Util.(json |> member "event_type" |> to_string = "team_turn"))
        (Team_session_store.read_events ~max_events:20 config session_id)
    with
    | Some event -> Yojson.Safe.Util.member "detail" event
    | None -> Alcotest.fail "expected team_turn event"
  in
  let legacy_detail = team_turn_detail_exn legacy_session_id in
  let step_detail = team_turn_detail_exn step_session_id in
  Alcotest.(check string) "legacy detail kind" "note"
    Yojson.Safe.Util.(legacy_detail |> member "kind" |> to_string);
  Alcotest.(check string) "step detail kind" "note"
    Yojson.Safe.Util.(step_detail |> member "kind" |> to_string);
  Alcotest.(check string) "legacy actor" "tester"
    Yojson.Safe.Util.(legacy_detail |> member "actor" |> to_string);
  Alcotest.(check string) "step actor" "tester"
    Yojson.Safe.Util.(step_detail |> member "actor" |> to_string);
  Alcotest.(check string) "legacy message" "legacy note"
    Yojson.Safe.Util.(legacy_detail |> member "message" |> to_string);
  Alcotest.(check string) "step message" "step note"
    Yojson.Safe.Util.(step_detail |> member "message" |> to_string);
  cleanup_dir base_dir

let test_proof_exposes_spawn_selection_rationale () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let start_json =
    start_session_exn ctx ~goal:"prove selection rationale visibility"
  in
  let session_id = get_session_id start_json in
  let spawn_model = "qwen3.5-35b-a3b-ud-q8-xl" in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "tester");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "llama-local-proof");
          ("spawn_role", `String "planner");
          ("spawn_model", `String spawn_model);
          ("spawn_selection_note", `String selection_note);
          ("success", `Bool true);
          ("exit_code", `Int 0);
          ("elapsed_ms", `Int 10);
          ("output_preview", `String "worker turn recorded");
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (Team_session_store.update_session config session_id (fun s ->
         {
           s with
           planned_workers =
             Team_session_types.dedup_planned_workers
               [
                 {
                   Team_session_types.spawn_agent = "llama";
                   runtime_actor = Some "llama-local-proof";
                   spawn_role = Some "planner";
                   spawn_model = Some spawn_model;
                   worker_class = None;
                   parent_actor = None;
                   capsule_mode = None;
                   runtime_pool = None;
                   lane_id = None;
                   controller_level = None;
                   control_domain = None;
                   supervisor_actor = None;
                   model_tier = Some Team_session_types.Tier_35b;
                   task_profile = Some Team_session_types.Profile_decide;
                   risk_level = Some Team_session_types.Risk_high;
                   routing_confidence = Some 0.97;
                   routing_reason = Some "explicit:lead";
                   routing_escalated = false;
                 };
               ];
           updated_at_iso = Types.now_iso ();
         }));
  let turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "tester turn for proof");
          ])
  in
  Alcotest.(check bool) "turn recorded" true turn_ok;
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "selection_note_done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("generate_report_if_missing", `Bool true);
          ])
  in
  Alcotest.(check bool) "prove ok" true prove_ok;
  let prove_result = parse_json_exn prove_body |> result_field in
  let proof_doc =
    prove_result |> Yojson.Safe.Util.member "proof"
  in
  let evidence =
    proof_doc |> Yojson.Safe.Util.member "evidence"
  in
  let recorded_note =
    evidence |> Yojson.Safe.Util.member "spawn_selection_note_summary"
    |> Yojson.Safe.Util.to_string
  in
  let planned_worker_count =
    evidence |> Yojson.Safe.Util.member "planned_worker_count"
    |> Yojson.Safe.Util.to_int
  in
  let runtime_actor_count =
    evidence |> Yojson.Safe.Util.member "unique_spawn_runtime_actors_count"
    |> Yojson.Safe.Util.to_int
  in
  let tier_35b_count =
    evidence |> Yojson.Safe.Util.member "tier_counts" |> Yojson.Safe.Util.member "35b"
    |> Yojson.Safe.Util.to_int
  in
  let decide_count =
    evidence |> Yojson.Safe.Util.member "task_profile_counts"
    |> Yojson.Safe.Util.member "decide" |> Yojson.Safe.Util.to_int
  in
  let recorded_models =
    evidence |> Yojson.Safe.Util.member "spawn_models"
    |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "selection note summary" selection_note recorded_note;
  Alcotest.(check int) "planned worker count" 1 planned_worker_count;
  Alcotest.(check int) "runtime actor count" 1 runtime_actor_count;
  Alcotest.(check int) "proof tier count" 1 tier_35b_count;
  Alcotest.(check int) "proof decide count" 1 decide_count;
  Alcotest.(check bool) "spawn model included" true
    (List.mem spawn_model recorded_models);
  let proof_md_path =
    prove_result |> Yojson.Safe.Util.member "proof_md_path"
    |> Yojson.Safe.Util.to_string
  in
  let ic = open_in proof_md_path in
  let proof_md =
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        really_input_string ic (in_channel_length ic))
  in
  Alcotest.(check bool) "markdown includes model" true
    (try
       let _ = Str.search_forward (Str.regexp_string spawn_model) proof_md 0 in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes rationale" true
    (try
       let _ = Str.search_forward (Str.regexp_string selection_note) proof_md 0 in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_bootstrap_grace_suppresses_min_agents_violation () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"bootstrap-grace"
      ~created_by:"owner" ~agent_names:[ "owner" ] ~min_agents:4
      ~checkpoint_interval_sec:10 ~started_at:(now -. 5.0)
      ~planned_end_at:(now +. 120.0)
      ~fallback_policy:Team_session_types.Fallback_task_only ~model_cascade:[]
  in
  let updated = Team_session_engine_eio.apply_runtime_policy ~config session in
  Alcotest.(check int) "violation streak suppressed" 0
    updated.min_agents_violation_streak;
  Alcotest.(check int) "fallback suppressed" 0 updated.fallback_task_created;
  let events = Team_session_store.read_events config session.session_id in
  let violation_events =
    List.filter
      (fun json ->
        Yojson.Safe.Util.member "event_type" json = `String "min_agents_violation")
      events
  in
  Alcotest.(check int) "no violation events during bootstrap" 0
    (List.length violation_events);
  cleanup_dir base_dir

let test_min_agents_violation_after_bootstrap_grace () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"post-bootstrap-violation"
      ~created_by:"owner" ~agent_names:[ "owner" ] ~min_agents:4
      ~checkpoint_interval_sec:10 ~started_at:(now -. 120.0)
      ~planned_end_at:(now +. 120.0)
      ~fallback_policy:Team_session_types.Fallback_task_only ~model_cascade:[]
  in
  let session = { session with min_agents_violation_streak = 1 } in
  let updated = Team_session_engine_eio.apply_runtime_policy ~config session in
  Alcotest.(check int) "violation streak increments after grace" 2
    updated.min_agents_violation_streak;
  Alcotest.(check int) "fallback not emitted on non-alert tick" 0
    updated.fallback_task_created;
  let events = Team_session_store.read_events config session.session_id in
  let violation_events =
    List.filter
      (fun json ->
        Yojson.Safe.Util.member "event_type" json = `String "min_agents_violation")
      events
  in
  Alcotest.(check int) "violation event recorded after grace" 1
    (List.length violation_events);
  cleanup_dir base_dir

let test_report_uses_participant_and_turn_metrics () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"report-participants-turns"
      ~created_by:"owner" ~agent_names:[ "owner"; "ally1"; "ally2" ]
      ~min_agents:3 ~checkpoint_interval_sec:10 ~started_at:(now -. 30.0)
      ~planned_end_at:(now +. 90.0)
      ~fallback_policy:Team_session_types.Fallback_none
      ~model_cascade:[ "llama:qwen3.5-35b-a3b-ud-q8-xl" ]
  in
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"owner" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "owner turn") ~target_agent:None ~task_title:None
          ~task_description:None ~task_priority:3));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"ally1" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "ally1 turn") ~target_agent:None ~task_title:None
          ~task_description:None ~task_priority:3));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"ally2" ~turn_kind:Team_session_types.Turn_task ~message:None
          ~target_agent:None ~task_title:(Some "task from ally2")
          ~task_description:(Some "noop task") ~task_priority:2));
  let reloaded =
    Team_session_store.load_session config session.session_id
    |> Option.get
  in
  let report_json, markdown =
    unwrap_ok (Team_session_report.generate config reloaded)
  in
  let active_agents_count =
    report_json |> Yojson.Safe.Util.member "team_health"
    |> Yojson.Safe.Util.member "active_agents_count"
    |> Yojson.Safe.Util.to_int
  in
  let room_active_agents =
    report_json |> Yojson.Safe.Util.member "summary"
    |> Yojson.Safe.Util.member "room_active_agents"
    |> Yojson.Safe.Util.to_list
  in
  let turn_metrics =
    report_json |> Yojson.Safe.Util.member "agent_turn_metrics"
    |> Team_session_types.assoc_int_of_json
  in
  Alcotest.(check int) "participant count drives team health" 3 active_agents_count;
  Alcotest.(check bool) "participant count exceeds room active count" true
    (active_agents_count > List.length room_active_agents);
  Alcotest.(check int) "owner turn metric" 1
    (List.assoc "owner" turn_metrics);
  Alcotest.(check int) "ally1 turn metric" 1
    (List.assoc "ally1" turn_metrics);
  Alcotest.(check int) "ally2 turn metric" 1
    (List.assoc "ally2" turn_metrics);
  Alcotest.(check bool) "markdown shows turn-based contribution" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "- ally2: turns=1, done_delta=0")
           markdown 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_prove_requires_multi_actor_turn_coverage () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let participants = [ "tester"; "ally1"; "ally2" ] in

  (* Case 1: single-actor turns should be insufficient when min_agents=3 *)
  let session_single =
    start_session_custom_exn ctx ~goal:"prove-single-actor-insufficient"
      ~min_agents:3 ~agents:participants
    |> get_session_id
  in
  let single_turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_single);
            ("turn_kind", `String "note");
            ("message", `String "only tester turn");
          ])
  in
  Alcotest.(check bool) "single actor turn recorded" true single_turn_ok;
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_single);
             ("reason", `String "single_actor_done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_single);
  let prove_single_ok, prove_single_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_single);
            ("generate_report_if_missing", `Bool true);
          ])
  in
  Alcotest.(check bool) "single actor prove ok" true prove_single_ok;
  let prove_single = parse_json_exn prove_single_body |> result_field in
  let verdict_single =
    prove_single |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "verdict"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "single actor verdict" "insufficient_evidence"
    verdict_single;

  (* Case 2: multi-actor turns satisfy min_agents coverage *)
  let session_multi =
    start_session_custom_exn ctx ~goal:"prove-multi-actor-pass" ~min_agents:3
      ~agents:participants
    |> get_session_id
  in
  let record_ok actor msg =
    match
      Team_session_engine_eio.record_turn ~config ~session_id:session_multi
        ~actor ~turn_kind:Team_session_types.Turn_note ~message:(Some msg)
        ~target_agent:None ~task_title:None ~task_description:None
        ~task_priority:3
    with
    | Ok _ -> true
    | Error _ -> false
  in
  Alcotest.(check bool) "tester note" true (record_ok "tester" "tester turn");
  Alcotest.(check bool) "ally1 note" true (record_ok "ally1" "ally1 turn");
  Alcotest.(check bool) "ally2 note" true (record_ok "ally2" "ally2 turn");
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_multi);
             ("reason", `String "multi_actor_done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_multi);
  let prove_multi_ok, prove_multi_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_multi);
            ("generate_report_if_missing", `Bool true);
          ])
  in
  Alcotest.(check bool) "multi actor prove ok" true prove_multi_ok;
  let prove_multi = parse_json_exn prove_multi_body |> result_field in
  let verdict_multi =
    prove_multi |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "verdict"
    |> Yojson.Safe.Util.to_string
  in
  let evidence_multi =
    prove_multi |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "evidence"
  in
  let required_turn_actors =
    evidence_multi |> Yojson.Safe.Util.member "required_turn_actors"
    |> Yojson.Safe.Util.to_int
  in
  let unique_turn_actors =
    evidence_multi |> Yojson.Safe.Util.member "unique_turn_actors_count"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check string) "multi actor verdict" "proved" verdict_multi;
  Alcotest.(check int) "required turn actors = min_agents" 3
    required_turn_actors;
  Alcotest.(check bool) "unique turn actors >= required" true
    (unique_turn_actors >= required_turn_actors);
  cleanup_dir base_dir

let test_missing_required_args () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let ok1, _ = dispatch_exn ctx ~name:"masc_team_session_start" ~args:(`Assoc []) in
  let ok2, _ = dispatch_exn ctx ~name:"masc_team_session_status" ~args:(`Assoc []) in
  let ok3, _ = dispatch_exn ctx ~name:"masc_team_session_stop" ~args:(`Assoc []) in
  let ok4, _ = dispatch_exn ctx ~name:"masc_team_session_report" ~args:(`Assoc []) in
  let ok5, _ =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String "../escape") ])
  in
  let ok6, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:(`Assoc [ ("session_id", `String "../../etc/passwd") ])
  in
  let ok7, _ =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:(`Assoc [ ("session_id", `String "bad-id") ])
  in
  let ok8, _ =
    dispatch_exn ctx ~name:"masc_team_session_compare"
      ~args:(`Assoc [ ("base_session_id", `String "bad-id") ])
  in
  let ok9, _ =
    dispatch_exn ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("status", `String "not-a-status") ])
  in
  let ok10, _ =
    dispatch_exn ctx ~name:"masc_team_session_turn" ~args:(`Assoc [])
  in
  let ok11, _ =
    dispatch_exn ctx ~name:"masc_team_session_events" ~args:(`Assoc [])
  in
  let ok12, _ =
    dispatch_exn ctx ~name:"masc_team_session_prove" ~args:(`Assoc [])
  in
  let ok13, _ =
    dispatch_exn ctx ~name:"masc_team_session_step" ~args:(`Assoc [])
  in
  let ok14, _ =
    dispatch_exn ctx ~name:"masc_team_session_finalize" ~args:(`Assoc [])
  in
  Alcotest.(check bool) "start invalid" false ok1;
  Alcotest.(check bool) "status invalid" false ok2;
  Alcotest.(check bool) "stop invalid" false ok3;
  Alcotest.(check bool) "report invalid" false ok4;
  Alcotest.(check bool) "status traversal invalid" false ok5;
  Alcotest.(check bool) "stop traversal invalid" false ok6;
  Alcotest.(check bool) "report format invalid" false ok7;
  Alcotest.(check bool) "compare invalid" false ok8;
  Alcotest.(check bool) "list invalid status" false ok9;
  Alcotest.(check bool) "turn invalid" false ok10;
  Alcotest.(check bool) "events invalid" false ok11;
  Alcotest.(check bool) "prove invalid" false ok12;
  Alcotest.(check bool) "step invalid" false ok13;
  Alcotest.(check bool) "finalize invalid" false ok14;
  cleanup_dir base_dir

let test_step_spawn_requires_proc_mgr () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-proc-manager-check" |> get_session_id in
  let step_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_agent", `String "glm");
            ("spawn_prompt", `String "hello");
          ])
  in
  Alcotest.(check bool) "step should fail without proc_mgr for spawn" false step_ok;
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn failure event recorded" 1 (List.length events);
  let first = List.hd events in
  let detail = Yojson.Safe.Util.member "detail" first in
  let success = detail |> Yojson.Safe.Util.member "success" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "spawn failure success=false" false success;
  let error_msg =
    detail |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string_option
    |> Option.value ~default:""
  in
  Alcotest.(check bool) "spawn failure has error" true (String.trim error_msg <> "");
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "cleanup");
             ("generate_report", `Bool false);
           ]));
  ignore (wait_until_terminal ctx session_id);
  cleanup_dir base_dir

let test_step_spawn_llama_requires_spawn_model () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-llama-model-check" |> get_session_id in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("spawn_agent", `String "llama");
            ("spawn_prompt", `String "inspect and report");
            ("spawn_role", `String "planner");
            ("spawn_selection_note", `String selection_note);
          ])
  in
  Alcotest.(check bool) "step should fail without spawn_model for llama" false step_ok;
  let body = parse_json_exn step_body in
  let message =
    body |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "error mentions spawn_model" true
    (try
       let _ = Str.search_forward (Str.regexp_string "spawn_model") message 0 in
       true
     with Not_found -> false);
  let events_ok, events_body =
    dispatch_exn ctx ~name:"masc_team_session_events"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("event_types", `List [ `String "team_step_spawn" ]);
          ])
  in
  Alcotest.(check bool) "events query ok" true events_ok;
  let events = events_list_of_body events_body in
  Alcotest.(check int) "spawn failure event recorded" 1 (List.length events);
  let detail = Yojson.Safe.Util.member "detail" (List.hd events) in
  let spawn_model =
    detail |> Yojson.Safe.Util.member "spawn_model"
  in
  Alcotest.(check bool) "spawn_model absent in failure event" true (spawn_model = `Null);
  let attached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_attached")
  in
  Alcotest.(check int) "no phantom attachment on validation failure" 0
    (List.length attached_events);
  let recorded_selection_note =
    detail |> Yojson.Safe.Util.member "spawn_selection_note"
    |> Yojson.Safe.Util.to_string_option
  in
  let recorded_selection_note =
    match recorded_selection_note with
    | Some value -> value
    | None -> Alcotest.fail "selection note missing in failure event"
  in
  Alcotest.(check bool) "selection note preserved in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string selection_note)
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "routing summary appended in failure event" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "[routing]")
           recorded_selection_note 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_step_spawn_batch_records_planned_workers () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"step-spawn-batch-planned-workers" |> get_session_id in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  let step_ok, step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ( "spawn_batch",
              `List
                [
                  `Assoc
                    [
                      ("spawn_agent", `String "llama");
                      ("spawn_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
                      ("spawn_role", `String "planner");
                      ("spawn_selection_note", `String selection_note);
                      ("spawn_prompt", `String "planner prompt");
                    ];
                  `Assoc
                    [
                      ("spawn_agent", `String "llama");
                      ("spawn_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
                      ("spawn_role", `String "implementer-a");
                      ("spawn_selection_note", `String selection_note);
                      ("spawn_prompt", `String "implementer prompt");
                    ];
                ] );
          ])
  in
  Alcotest.(check bool) "batch step fails without proc manager" false step_ok;
  let body = parse_json_exn step_body in
  let message = body |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "proc manager error surfaced" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "process manager unavailable")
           message 0
       in
       true
     with Not_found -> false);
  let session =
    Team_session_store.load_session config session_id |> Option.get
  in
  Alcotest.(check int) "planned workers recorded" 2
    (List.length session.planned_workers);
  let attached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_attached")
  in
  Alcotest.(check int) "no attachment when proc manager missing" 0
    (List.length attached_events);
  let planned_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_planned_workers_updated")
  in
  Alcotest.(check int) "planned worker event recorded" 1
    (List.length planned_events);
  cleanup_dir base_dir

let test_step_spawn_batch_applies_hybrid_routing () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let ctx : _ Tool_team_session.context =
        {
          config;
          agent_name = "owner";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = None;
        }
      in
      with_env "MASC_TEAM_SESSION_MODEL_35B" (Some "qwen35-lead") @@ fun () ->
      with_env "MASC_TEAM_SESSION_MODEL_9B" (Some "qwen9-worker") @@ fun () ->
      with_env "MASC_TEAM_SESSION_ROUTER_JUDGE" (Some "false") @@ fun () ->
      let session_id =
        start_session_exn ctx ~goal:"hybrid-router-step" |> get_session_id
      in
      let step_ok, step_body =
        dispatch_exn ctx ~name:"masc_team_session_step"
          ~args:
            (`Assoc
              [
                ("session_id", `String session_id);
                ( "spawn_batch",
                  `List
                    [
                      `Assoc
                        [
                          ("spawn_agent", `String "llama");
                          ("spawn_role", `String "normalizer");
                          ("spawn_prompt", `String "normalize evidence into strict JSON schema");
                        ];
                      `Assoc
                        [
                          ("spawn_agent", `String "llama");
                          ("spawn_role", `String "final-writer");
                          ("spawn_prompt", `String "final architecture decision and synthesize the proposal");
                        ];
                    ] );
              ])
      in
      Alcotest.(check bool) "batch step fails without proc manager" false step_ok;
      let message =
        parse_json_exn step_body |> Yojson.Safe.Util.member "message"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check bool) "proc manager error surfaced" true
        (try
           let _ =
             Str.search_forward
               (Str.regexp_string "process manager unavailable")
               message 0
           in
           true
         with Not_found -> false);
      let session =
        Team_session_store.load_session config session_id |> Option.get
      in
      Alcotest.(check int) "planned workers recorded" 2
        (List.length session.planned_workers);
      let normalizer =
        List.find
          (fun worker -> worker.Team_session_types.spawn_role = Some "normalizer")
          session.planned_workers
      in
      Alcotest.(check (option string)) "normalizer model" (Some "qwen9-worker")
        normalizer.spawn_model;
      Alcotest.(check (option string)) "normalizer tier" (Some "9b")
        (Option.map Team_session_types.model_tier_to_string normalizer.model_tier);
      Alcotest.(check (option string)) "normalizer profile" (Some "normalize")
        (Option.map Team_session_types.task_profile_to_string
           normalizer.task_profile);
      Alcotest.(check (option string)) "normalizer risk" (Some "low")
        (Option.map Team_session_types.risk_level_to_string normalizer.risk_level);
      let final_writer =
        List.find
          (fun worker -> worker.Team_session_types.spawn_role = Some "final-writer")
          session.planned_workers
      in
      Alcotest.(check (option string)) "final writer model" (Some "qwen35-lead")
        final_writer.spawn_model;
      Alcotest.(check (option string)) "final writer tier" (Some "35b")
        (Option.map Team_session_types.model_tier_to_string
           final_writer.model_tier);
      Alcotest.(check (option string)) "final writer profile" (Some "synthesize")
        (Option.map Team_session_types.task_profile_to_string
           final_writer.task_profile);
      Alcotest.(check (option string)) "final writer risk" (Some "high")
        (Option.map Team_session_types.risk_level_to_string
           final_writer.risk_level);
      let status_ok, status_body =
        dispatch_exn ctx ~name:"masc_team_session_status"
          ~args:(`Assoc [ ("session_id", `String session_id) ])
      in
      Alcotest.(check bool) "status ok" true status_ok;
      let summary =
        parse_json_exn status_body |> result_field |> Yojson.Safe.Util.member "summary"
      in
      Alcotest.(check int) "summary 35b count" 1
        Yojson.Safe.Util.(summary |> member "tier_counts" |> member "35b" |> to_int);
      Alcotest.(check int) "summary 9b count" 1
        Yojson.Safe.Util.(summary |> member "tier_counts" |> member "9b" |> to_int);
      Alcotest.(check int) "summary normalize count" 1
        Yojson.Safe.Util.(summary |> member "task_profile_counts" |> member "normalize" |> to_int);
      Alcotest.(check int) "summary synthesize count" 1
        Yojson.Safe.Util.(summary |> member "task_profile_counts" |> member "synthesize" |> to_int))

let test_parse_step_spawn_specs_applies_top_level_batch_timeout () =
  let args =
    `Assoc
      [
        ("spawn_timeout_seconds", `Int 1500);
        ( "spawn_batch",
          `List
            [
              `Assoc
                [
                  ("spawn_agent", `String "llama");
                  ("spawn_prompt", `String "first prompt");
                ];
              `Assoc
                [
                  ("spawn_agent", `String "llama");
                  ("spawn_prompt", `String "second prompt");
                  ("spawn_timeout_seconds", `Int 45);
                ];
            ] );
      ]
  in
  let specs = unwrap_ok (Tool_team_session.parse_step_spawn_specs args) in
  match specs with
  | [ first; second ] ->
      Alcotest.(check int) "top-level timeout applied to first batch item" 1500
        first.spawn_timeout_seconds;
      Alcotest.(check int) "item timeout still overrides default" 45
        second.spawn_timeout_seconds
  | _ -> Alcotest.fail "expected exactly two parsed spawn specs"

let test_reconcile_failed_spawn_actor_detaches_without_turn () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"detach-failed-spawn"
      ~created_by:"owner" ~agent_names:[ "owner" ] ~min_agents:2
      ~checkpoint_interval_sec:10 ~started_at:(now -. 10.0)
      ~planned_end_at:(now +. 120.0)
      ~fallback_policy:Team_session_types.Fallback_none ~model_cascade:[]
  in
  ignore (unwrap_ok (Tool_team_session.ensure_session_actor config session.session_id "llama-local-failed"));
  let outcome =
    unwrap_ok
      (Tool_team_session.reconcile_failed_spawn_actor config session.session_id
         "llama-local-failed")
  in
  Alcotest.(check string) "failed spawn actor detached" "detached"
    (match outcome with `Detached -> "detached" | `Retained -> "retained");
  let reloaded = Team_session_store.load_session config session.session_id |> Option.get in
  Alcotest.(check bool) "actor removed from participants" false
    (List.mem "llama-local-failed" reloaded.agent_names);
  let detached_events =
    Team_session_store.read_events config session.session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_detached")
  in
  Alcotest.(check int) "detached event recorded" 1 (List.length detached_events);
  cleanup_dir base_dir

let test_reconcile_failed_spawn_actor_retains_after_turn () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"retain-failed-spawn-after-turn" |> get_session_id in
  ignore
    (unwrap_ok
       (Tool_team_session.ensure_session_actor config session_id
          "llama-local-turned"));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id
          ~actor:"llama-local-turned" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "worker left one turn before failing")
          ~target_agent:None ~task_title:None ~task_description:None
          ~task_priority:3));
  let outcome =
    unwrap_ok
      (Tool_team_session.reconcile_failed_spawn_actor config session_id
         "llama-local-turned")
  in
  Alcotest.(check string) "actor retained after emitting a turn" "retained"
    (match outcome with `Detached -> "detached" | `Retained -> "retained");
  let reloaded = Team_session_store.load_session config session_id |> Option.get in
  Alcotest.(check bool) "actor still authorized" true
    (List.mem "llama-local-turned" reloaded.agent_names);
  let detached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_detached")
  in
  Alcotest.(check int) "no detach event recorded" 0 (List.length detached_events);
  cleanup_dir base_dir

let test_proof_exposes_failed_spawn_and_detach_counts () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let start_json =
    start_session_exn ctx ~goal:"prove failed spawn and detach visibility"
  in
  let session_id = get_session_id start_json in
  Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "tester");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "llama-local-failed");
          ("spawn_role", `String "implementer-a");
          ("spawn_model", `String "qwen3.5-35b-a3b-ud-q8-xl");
          ("success", `Bool false);
          ("exit_code", `Int 1);
          ("elapsed_ms", `Int 25);
          ("error", `String "worker exited early");
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  Team_session_store.append_event config session_id
    ~event_type:"session_agent_detached"
    ~detail:
      (`Assoc
        [
          ("actor", `String "llama-local-failed");
          ("reason", `String "spawn_failed_without_turn");
          ("agent_count", `Int 1);
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_turn"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("turn_kind", `String "note");
             ("message", `String "tester turn for failure proof");
           ]));
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "failed_spawn_done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("generate_report_if_missing", `Bool true);
          ])
  in
  Alcotest.(check bool) "prove ok" true prove_ok;
  let prove_result = parse_json_exn prove_body |> result_field in
  let evidence = prove_result |> Yojson.Safe.Util.member "proof" |> Yojson.Safe.Util.member "evidence" in
  let spawn_failure_count =
    evidence |> Yojson.Safe.Util.member "spawn_failure_count"
    |> Yojson.Safe.Util.to_int
  in
  let detached_agent_count =
    evidence |> Yojson.Safe.Util.member "detached_agent_count"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "spawn failure count recorded" 1 spawn_failure_count;
  Alcotest.(check int) "detached agent count recorded" 1 detached_agent_count;
  let failed_spawn_roster =
    evidence |> Yojson.Safe.Util.member "failed_spawn_roster"
    |> Yojson.Safe.Util.to_list
  in
  let detached_actor_roster =
    evidence |> Yojson.Safe.Util.member "detached_actor_roster"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "proof failed spawn roster length" 1
    (List.length failed_spawn_roster);
  Alcotest.(check int) "proof detached actor roster length" 1
    (List.length detached_actor_roster);
  let failed_runtime_actor =
    List.hd failed_spawn_roster |> Yojson.Safe.Util.member "runtime_actor"
    |> Yojson.Safe.Util.to_string
  in
  let failed_role =
    List.hd failed_spawn_roster |> Yojson.Safe.Util.member "spawn_role"
    |> Yojson.Safe.Util.to_string
  in
  let detached_reason =
    List.hd detached_actor_roster |> Yojson.Safe.Util.member "reason"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "proof failed runtime actor recorded" "llama-local-failed"
    failed_runtime_actor;
  Alcotest.(check string) "proof failed spawn role recorded" "implementer-a"
    failed_role;
  Alcotest.(check string) "proof detached reason recorded"
    "spawn_failed_without_turn" detached_reason;
  let empty_note_turn_count =
    evidence |> Yojson.Safe.Util.member "empty_note_turn_count"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "proof empty note count stays zero" 0 empty_note_turn_count;
  let report_json_path = Team_session_store.report_json_path config session_id in
  let report_doc = Room_utils.read_json config report_json_path in
  let report_failed_roster =
    report_doc |> Yojson.Safe.Util.member "incidents"
    |> Yojson.Safe.Util.member "failed_spawn_roster"
    |> Yojson.Safe.Util.to_list
  in
  let report_detached_roster =
    report_doc |> Yojson.Safe.Util.member "incidents"
    |> Yojson.Safe.Util.member "detached_actor_roster"
    |> Yojson.Safe.Util.to_list
  in
  let report_empty_note_count =
    report_doc |> Yojson.Safe.Util.member "incidents"
    |> Yojson.Safe.Util.member "empty_note_turn_count"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "report failed spawn roster length" 1
    (List.length report_failed_roster);
  Alcotest.(check int) "report detached actor roster length" 1
    (List.length report_detached_roster);
  Alcotest.(check int) "report empty note count stays zero" 0
    report_empty_note_count;
  let proof_md_path =
    prove_result |> Yojson.Safe.Util.member "proof_md_path"
    |> Yojson.Safe.Util.to_string
  in
  let proof_md = Stdlib.In_channel.with_open_bin proof_md_path Stdlib.In_channel.input_all in
  Alcotest.(check bool) "markdown includes failed spawn count" true
    (try
       let _ = Str.search_forward (Str.regexp_string "Failed spawn events: 1") proof_md 0 in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes detached actor count" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "Detached failed actors: 1") proof_md 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes failed actor roster" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "llama-local-failed | agent=llama | role=implementer-a")
           proof_md 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes detached reason" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "llama-local-failed | reason=spawn_failed_without_turn")
           proof_md 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_report_and_proof_expose_empty_note_turn_evidence () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"empty-note-evidence" |> get_session_id in
  Team_session_store.append_event config session_id ~event_type:"team_turn"
    ~detail:
      (`Assoc
        [
          ("turn_no", `Int 1);
          ("kind", `String "note");
          ("actor", `String "llama-local-empty");
          ("message", `Null);
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_turn"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("turn_kind", `String "note");
             ("message", `String "supervisor note");
           ]));
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "empty_note_evidence_done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "prove ok for empty note evidence" true prove_ok;
  let prove_result = parse_json_exn prove_body |> result_field in
  let evidence =
    prove_result |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "evidence"
  in
  let empty_note_turn_count =
    evidence |> Yojson.Safe.Util.member "empty_note_turn_count"
    |> Yojson.Safe.Util.to_int
  in
  let empty_note_turn_actors =
    evidence |> Yojson.Safe.Util.member "empty_note_turn_actors"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "proof empty note count" 1 empty_note_turn_count;
  Alcotest.(check int) "proof empty note actors length" 1
    (List.length empty_note_turn_actors);
  Alcotest.(check string) "proof empty note actor recorded"
    "llama-local-empty"
    (List.hd empty_note_turn_actors |> Yojson.Safe.Util.to_string);
  let report_json_path = Team_session_store.report_json_path config session_id in
  let report_doc = Room_utils.read_json config report_json_path in
  let report_empty_note_count =
    report_doc |> Yojson.Safe.Util.member "incidents"
    |> Yojson.Safe.Util.member "empty_note_turn_count"
    |> Yojson.Safe.Util.to_int
  in
  let report_empty_note_actors =
    report_doc |> Yojson.Safe.Util.member "incidents"
    |> Yojson.Safe.Util.member "empty_note_turn_actors"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "report empty note count" 1 report_empty_note_count;
  Alcotest.(check int) "report empty note actors length" 1
    (List.length report_empty_note_actors);
  let proof_md_path =
    prove_result |> Yojson.Safe.Util.member "proof_md_path"
    |> Yojson.Safe.Util.to_string
  in
  let proof_md = Stdlib.In_channel.with_open_bin proof_md_path Stdlib.In_channel.input_all in
  Alcotest.(check bool) "proof markdown includes empty note evidence" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "Empty note turns: 1") proof_md 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "proof markdown includes empty actor" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "- llama-local-empty") proof_md 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_prove_strong_requires_additional_evidence () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"prove-strong-check" |> get_session_id in
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_turn"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("turn_kind", `String "note");
             ("message", `String "single-turn");
           ]));
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "proof-check");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("proof_level", `String "strong");
          ])
  in
  Alcotest.(check bool) "prove strong call succeeds" true prove_ok;
  let verdict =
    prove_body |> parse_json_exn |> result_field |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "verdict" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "strong proof needs stronger evidence"
    "insufficient_evidence_strong" verdict;
  cleanup_dir base_dir

let test_dispatch_unknown () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  Alcotest.(check bool) "dispatch none" true
    (Tool_team_session.dispatch ctx ~name:"masc_team_session_unknown"
       ~args:(`Assoc [])
    = None);
  cleanup_dir base_dir

let test_unauthorized_session_access () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let owner_ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let intruder_ctx : _ Tool_team_session.context =
    { config; agent_name = "intruder"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn owner_ctx ~goal:"authz-check" |> get_session_id in

  let status_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized status denied" false status_ok;

  let report_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [ ("session_id", `String session_id); ("force_regenerate", `Bool false) ])
  in
  Alcotest.(check bool) "unauthorized report denied" false report_ok;

  let stop_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_stop"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized stop denied" false stop_ok;

  let list_ok, list_body =
    dispatch_exn intruder_ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("limit", `Int 10) ])
  in
  Alcotest.(check bool) "unauthorized list filtered" true list_ok;
  let listed_sessions =
    parse_json_exn list_body |> result_field |> Yojson.Safe.Util.member "sessions"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "unauthorized list empty" 0 (List.length listed_sessions);

  let compare_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_compare"
      ~args:
        (`Assoc
          [
            ("base_session_id", `String session_id);
            ("target_session_id", `String session_id);
          ])
  in
  Alcotest.(check bool) "unauthorized compare denied" false compare_ok;

  let turn_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_turn"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "intruder");
          ])
  in
  Alcotest.(check bool) "unauthorized turn denied" false turn_ok;

  let events_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_events"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized events denied" false events_ok;

  let prove_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_prove"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized prove denied" false prove_ok;

  let owner_stop_ok, _ =
    dispatch_exn owner_ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "owner_cleanup");
            ("generate_report", `Bool false);
          ])
  in
  Alcotest.(check bool) "owner stop allowed" true owner_stop_ok;
  ignore (wait_until_terminal owner_ctx session_id);
  cleanup_dir base_dir

let test_final_done_delta_snapshot_stable () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"snapshot-stability" |> get_session_id in

  let task_before = add_task_id config ~title:"before-finalize" in
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"claim";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"start";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"done";

  let stop_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "snapshot_finalize");
            ("generate_report", `Bool true);
          ])
  in
  Alcotest.(check bool) "stop accepted" true stop_ok;
  ignore (wait_until_terminal ctx session_id);

  let status_ok_before, status_body_before =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status before stable check" true status_ok_before;
  let done_before = done_delta_total_of_status_body status_body_before in
  Alcotest.(check int) "done delta before finalize snapshot" 1 done_before;

  let task_after = add_task_id config ~title:"after-finalize" in
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"claim";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"start";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"done";

  let status_ok_after, status_body_after =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status after stable check" true status_ok_after;
  let done_after = done_delta_total_of_status_body status_body_after in
  Alcotest.(check int) "done delta should stay frozen after finalize" done_before
    done_after;

  let report_ok, report_body =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [ ("session_id", `String session_id); ("force_regenerate", `Bool true) ])
  in
  Alcotest.(check bool) "report regenerate" true report_ok;
  let report_json = parse_json_exn report_body |> result_field in
  let report_json_path =
    report_json |> Yojson.Safe.Util.member "json_path" |> Yojson.Safe.Util.to_string
  in
  let report_doc = Room_utils.read_json config report_json_path in
  let done_in_report =
    report_doc |> Yojson.Safe.Util.member "summary"
    |> Yojson.Safe.Util.member "done_delta_total"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "report uses frozen done delta" done_before done_in_report;
  cleanup_dir base_dir

let () =
  Alcotest.run "Tool_team_session"
    [
      ( "team_session",
        [
          Alcotest.test_case "start-status-report-stop" `Quick
            test_start_status_report_stop;
          Alcotest.test_case "proof-exposes-spawn-selection-rationale" `Quick
            test_proof_exposes_spawn_selection_rationale;
          Alcotest.test_case "bootstrap-grace-suppresses-min-agents-violation"
            `Quick test_bootstrap_grace_suppresses_min_agents_violation;
          Alcotest.test_case "min-agents-violation-after-bootstrap-grace"
            `Quick test_min_agents_violation_after_bootstrap_grace;
          Alcotest.test_case "report-uses-participant-and-turn-metrics" `Quick
            test_report_uses_participant_and_turn_metrics;
          Alcotest.test_case "duration-reached-path" `Quick
            test_duration_reached_path;
          Alcotest.test_case "recover-elapsed-session" `Quick
            test_recover_elapsed_session;
          Alcotest.test_case "read-events-limit" `Quick
            test_read_events_limit;
          Alcotest.test_case "list-and-compare" `Quick test_list_and_compare;
          Alcotest.test_case "turn-events-prove" `Quick
            test_turn_events_and_prove;
          Alcotest.test_case "step-plain-turn-matches-legacy-turn" `Quick
            test_step_plain_turn_matches_legacy_turn;
          Alcotest.test_case "prove-requires-multi-actor-turn-coverage" `Quick
            test_prove_requires_multi_actor_turn_coverage;
          Alcotest.test_case "missing-required-args" `Quick
            test_missing_required_args;
          Alcotest.test_case "step-spawn-requires-proc-mgr" `Quick
            test_step_spawn_requires_proc_mgr;
          Alcotest.test_case "step-spawn-llama-requires-spawn-model" `Quick
            test_step_spawn_llama_requires_spawn_model;
          Alcotest.test_case "step-spawn-batch-records-planned-workers"
            `Quick test_step_spawn_batch_records_planned_workers;
          Alcotest.test_case "step-spawn-batch-applies-hybrid-routing"
            `Quick test_step_spawn_batch_applies_hybrid_routing;
          Alcotest.test_case "parse-step-spawn-specs-applies-top-level-batch-timeout"
            `Quick test_parse_step_spawn_specs_applies_top_level_batch_timeout;
          Alcotest.test_case "reconcile-failed-spawn-actor-detaches-without-turn"
            `Quick test_reconcile_failed_spawn_actor_detaches_without_turn;
          Alcotest.test_case "reconcile-failed-spawn-actor-retains-after-turn"
            `Quick test_reconcile_failed_spawn_actor_retains_after_turn;
          Alcotest.test_case "proof-exposes-failed-spawn-and-detach-counts"
            `Quick test_proof_exposes_failed_spawn_and_detach_counts;
          Alcotest.test_case "report-and-proof-expose-empty-note-turn-evidence"
            `Quick test_report_and_proof_expose_empty_note_turn_evidence;
          Alcotest.test_case "prove-strong-requires-additional-evidence" `Quick
            test_prove_strong_requires_additional_evidence;
          Alcotest.test_case "dispatch-unknown" `Quick test_dispatch_unknown;
          Alcotest.test_case "unauthorized-session-access" `Quick
            test_unauthorized_session_access;
          Alcotest.test_case "final-done-delta-snapshot-stable" `Quick
            test_final_done_delta_snapshot_stable;
        ] );
    ]
