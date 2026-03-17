open Masc_mcp
open Test_tool_team_session_support

let test_recover_orphan_session () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let session_id = Team_session_store.make_session_id () in
  let now = Time_compat.now () in
  Team_session_store.ensure_session_dirs config session_id;
  let session : Team_session_types.session =
    {
      session_id;
      goal = "test orphan cleanup";
      created_by = "tester";
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
      model_cascade = [ "glm:glm-5" ];
      fallback_policy = Team_session_types.Fallback_cascade_then_task;
      instruction_profile = Team_session_types.Profile_standard;
      alert_channel = Team_session_types.Alert_both;
      auto_resume = false;
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
      planned_end_at = now +. 3600.0;
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
      failwith "orphan session not transitioned after recover"
    else
      match Team_session_store.load_session config session_id with
      | Some s -> s
      | None ->
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
          wait_loaded (attempts - 1)
  in
  let reloaded = wait_loaded 100 in
  Alcotest.(check string) "orphan becomes interrupted" "interrupted"
    (Team_session_types.status_to_string reloaded.status);
  Alcotest.(check string) "stop reason" "no_auto_resume_on_restart"
    (Option.value ~default:"" reloaded.stop_reason);
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
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
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

