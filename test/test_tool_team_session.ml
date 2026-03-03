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

let session_status_of_body body =
  let json = parse_json_exn body in
  let result = result_field json in
  result |> Yojson.Safe.Util.member "session" |> Yojson.Safe.Util.member "status"
  |> Yojson.Safe.Util.to_string

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

let test_start_status_report_stop () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());

  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env }
  in

  let start_args =
    `Assoc
      [
        ("goal", `String "Run coordinated team session and capture report");
        ("duration_seconds", `Int 90);
        ("checkpoint_interval_sec", `Int 10);
        ("report_formats", `List [ `String "markdown"; `String "json" ]);
      ]
  in
  let start_ok, start_body =
    dispatch_exn ctx ~name:"masc_team_session_start" ~args:start_args
  in
  Alcotest.(check bool) "start ok" true start_ok;
  let start_json = parse_json_exn start_body in
  Alcotest.(check string) "start status ok" "ok"
    (Yojson.Safe.Util.member "status" start_json |> Yojson.Safe.Util.to_string);
  let session_id =
    start_json |> result_field |> Yojson.Safe.Util.member "session_id"
    |> Yojson.Safe.Util.to_string
  in

  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let status_json = parse_json_exn status_body in
  Alcotest.(check string) "status wrapper" "ok"
    (Yojson.Safe.Util.member "status" status_json |> Yojson.Safe.Util.to_string);

  let report_ok, report_body =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("force_regenerate", `Bool true);
          ])
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
  Alcotest.(check bool) "json report exists" true (Room_utils.path_exists config json_path);

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
  Alcotest.(check bool) "terminal status"
    true
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
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env }
  in
  let start_ok, start_body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String "exercise duration_reached branch");
            ("duration_seconds", `Int 60);
            ("checkpoint_interval_sec", `Int 10);
          ])
  in
  Alcotest.(check bool) "start ok" true start_ok;
  let start_json = parse_json_exn start_body in
  let session_id =
    start_json |> result_field |> Yojson.Safe.Util.member "session_id"
    |> Yojson.Safe.Util.to_string
  in
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
      auto_resume = true;
      report_formats = [ Team_session_types.Markdown; Team_session_types.Json ];
      agent_names = [ "tester" ];
      baseline_done_counts = [];
      started_at = now -. 120.0;
      planned_end_at = now -. 5.0;
      stopped_at = None;
      last_checkpoint_at = Some (now -. 30.0);
      last_event_at = Some (now -. 30.0);
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
           match Yojson.Safe.Util.member "detail" json |> Yojson.Safe.Util.member "seq" with
           | `Int n -> n
           | _ -> -1)
  in
  Alcotest.(check (list int)) "tail events kept" [ 16; 17; 18; 19; 20 ] seqs;
  cleanup_dir base_dir

let test_missing_required_args () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env }
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
  Alcotest.(check bool) "start invalid" false ok1;
  Alcotest.(check bool) "status invalid" false ok2;
  Alcotest.(check bool) "stop invalid" false ok3;
  Alcotest.(check bool) "report invalid" false ok4;
  Alcotest.(check bool) "status traversal invalid" false ok5;
  Alcotest.(check bool) "stop traversal invalid" false ok6;
  Alcotest.(check bool) "report format invalid" false ok7;
  cleanup_dir base_dir

let test_dispatch_unknown () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env }
  in
  Alcotest.(check bool) "dispatch none" true
    (Tool_team_session.dispatch ctx ~name:"masc_team_session_unknown"
       ~args:(`Assoc [])
    = None);
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
          Alcotest.test_case "missing-required-args" `Quick
            test_missing_required_args;
          Alcotest.test_case "dispatch-unknown" `Quick test_dispatch_unknown;
        ] );
    ]
