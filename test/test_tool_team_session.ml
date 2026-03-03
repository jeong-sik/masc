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
      model_cascade = [ "glm:glm-5" ];
      fallback_policy = Team_session_types.Fallback_cascade_then_task;
      instruction_profile = Team_session_types.Profile_standard;
      alert_channel = Team_session_types.Alert_both;
      auto_resume = true;
      report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
      turn_count = 0;
      agent_names = [ "tester" ];
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
            ("turn_kind", `String "note");
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
          Alcotest.test_case "duration-reached-path" `Quick
            test_duration_reached_path;
          Alcotest.test_case "recover-elapsed-session" `Quick
            test_recover_elapsed_session;
          Alcotest.test_case "read-events-limit" `Quick
            test_read_events_limit;
          Alcotest.test_case "list-and-compare" `Quick test_list_and_compare;
          Alcotest.test_case "turn-events-prove" `Quick
            test_turn_events_and_prove;
          Alcotest.test_case "prove-requires-multi-actor-turn-coverage" `Quick
            test_prove_requires_multi_actor_turn_coverage;
          Alcotest.test_case "missing-required-args" `Quick
            test_missing_required_args;
          Alcotest.test_case "step-spawn-requires-proc-mgr" `Quick
            test_step_spawn_requires_proc_mgr;
          Alcotest.test_case "prove-strong-requires-additional-evidence" `Quick
            test_prove_strong_requires_additional_evidence;
          Alcotest.test_case "dispatch-unknown" `Quick test_dispatch_unknown;
          Alcotest.test_case "unauthorized-session-access" `Quick
            test_unauthorized_session_access;
          Alcotest.test_case "final-done-delta-snapshot-stable" `Quick
            test_final_done_delta_snapshot_stable;
        ] );
    ]
