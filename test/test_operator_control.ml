open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_operator_control_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let result_field json =
  Yojson.Safe.Util.member "result" json

let operator_ctx ?mcp_session_id env sw config agent_name : _ Operator_control.context =
  { config; agent_name; sw; clock = Eio.Stdenv.clock env; mcp_session_id }

let team_ctx env sw config agent_name : _ Tool_team_session.context =
  { config; agent_name; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }

let dispatch_team_exn ctx ~name ~args =
  match Tool_team_session.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("team session dispatch missing: " ^ name)

let start_session_exn ctx =
  let ok, body =
    dispatch_team_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String "Operator control test session");
            ("duration_seconds", `Int 120);
            ("checkpoint_interval_sec", `Int 30);
            ("min_agents", `Int 1);
            ("orchestration_mode", `String "assist");
            ("communication_mode", `String "broadcast");
            ("agents", `List [ `String ctx.Tool_team_session.agent_name ]);
          ])
  in
  Alcotest.(check bool) "session start ok" true ok;
  let json = parse_json_exn body in
  json |> result_field |> Yojson.Safe.Util.member "session_id"
  |> Yojson.Safe.Util.to_string

let test_snapshot_has_expected_sections () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Room.add_task config ~title:"operator backlog" ~priority:2 ~description:"");
      ignore (Room.broadcast config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      Alcotest.(check bool) "room present" true (Yojson.Safe.Util.member "room" json <> `Null);
      Alcotest.(check bool) "sessions present" true (Yojson.Safe.Util.member "sessions" json <> `Null);
      Alcotest.(check bool) "keepers present" true (Yojson.Safe.Util.member "keepers" json <> `Null);
      Alcotest.(check bool) "recent_messages present" true
        (Yojson.Safe.Util.member "recent_messages" json <> `Null);
      Alcotest.(check bool) "pending_confirms present" true
        (Yojson.Safe.Util.member "pending_confirms" json <> `Null);
      Alcotest.(check bool) "trace_id present" true
        (json |> Yojson.Safe.Util.member "trace_id" |> Yojson.Safe.Util.to_string <> "");
      Alcotest.(check string) "server profile"
        "operator_remote_v1"
        (json |> Yojson.Safe.Util.member "server_profile"
         |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
         | `List _ -> true
         | _ -> false))

let test_task_inject_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("action_type", `String "task_inject");
              ("target_type", `String "room");
              ( "payload",
                `Assoc
                  [
                    ("title", `String "Injected task");
                    ("description", `String "created by operator");
                    ("priority", `Int 1);
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        (action_json |> Yojson.Safe.Util.member "confirm_required"
       |> Yojson.Safe.Util.to_bool);
      let confirm_token =
        action_json |> Yojson.Safe.Util.member "confirm_token"
        |> Yojson.Safe.Util.to_string
      in
      let snapshot = Operator_control.snapshot_json ~actor:"operator" ctx in
      let pending_confirms =
        snapshot |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm count" 1 (List.length pending_confirms);
      Alcotest.(check bool) "pending confirm preview" true
        (List.hd pending_confirms |> Yojson.Safe.Util.member "preview" <> `Null);
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("confirm_token", `String confirm_token);
            ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "executed action present" true
        (Yojson.Safe.Util.member "executed_action" confirm_json <> `Null);
      let tasks = Room.get_tasks_raw config in
      Alcotest.(check int) "task injected" 1 (List.length tasks))

let test_team_turn_falls_back_to_session_actor () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_turn");
              ("target_type", `String "team_session");
              ("target_id", `String session_id);
              ( "payload",
                `Assoc
                  [
                    ("turn_kind", `String "note");
                    ("message", `String "operator note");
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let delegated = action_json |> Yojson.Safe.Util.member "result" in
      Alcotest.(check bool) "override true" true
        (delegated |> Yojson.Safe.Util.member "operator_override"
         |> Yojson.Safe.Util.to_bool);
      let events =
        Team_session_store.read_events ~max_events:20 config session_id
      in
      Alcotest.(check bool) "event recorded" true (List.length events > 0))

let test_team_note_records_action_log () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx ~mcp_session_id:"remote-session-1" env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_note");
              ("target_id", `String session_id);
              ("payload", `Assoc [ ("message", `String "operator note") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "no confirm required" false
        (action_json |> Yojson.Safe.Util.member "confirm_required"
         |> Yojson.Safe.Util.to_bool);
      let snapshot = Operator_control.snapshot_json ~actor:"dashboard" ctx in
      let recent_actions =
        snapshot |> Yojson.Safe.Util.member "recent_actions" |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "recent action count" 1 (List.length recent_actions);
      let entry = List.hd recent_actions in
      Alcotest.(check string) "action_type" "team_note"
        (entry |> Yojson.Safe.Util.member "action_type" |> Yojson.Safe.Util.to_string);
      Alcotest.(check string) "remote session id" "remote-session-1"
        (entry |> Yojson.Safe.Util.member "remote_session_id"
         |> Yojson.Safe.Util.to_string))

let test_team_broadcast_records_event () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_broadcast");
              ("target_id", `String session_id);
              ("payload", `Assoc [ ("message", `String "broadcast to session") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "result present" true
        (Yojson.Safe.Util.member "result" action_json <> `Null);
      let events = Team_session_store.read_events ~max_events:20 config session_id in
      Alcotest.(check bool) "event recorded" true (List.length events > 0))

let test_team_task_inject_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      let session_id = start_session_exn (team_ctx env sw config "owner") in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "team_task_inject");
              ("target_id", `String session_id);
              ( "payload",
                `Assoc
                  [
                    ("title", `String "Injected session task");
                    ("description", `String "created by remote operator");
                    ("priority", `Int 1);
                  ] );
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let confirm_token =
        action_json |> Yojson.Safe.Util.member "confirm_token"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check bool) "confirm required" true
        (action_json |> Yojson.Safe.Util.member "confirm_required"
         |> Yojson.Safe.Util.to_bool);
      let confirm_json =
        Operator_control.confirm_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("confirm_token", `String confirm_token);
            ])
      in
      let confirm_json =
        match confirm_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "delegated tool result present" true
        (Yojson.Safe.Util.member "delegated_tool_result" confirm_json <> `Null);
      let pending_confirms =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm cleared" 0 (List.length pending_confirms))

let test_confirm_rejects_expired_token () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Room.masc_dir config) "operator" in
      Masc_mcp.Room_utils.mkdir_p pending_dir;
      let path = Filename.concat pending_dir "pending_confirms.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc
            (Yojson.Safe.to_string
               (`List
                 [
                   `Assoc
                     [
                       ("token", `String "expired-token");
                       ("trace_id", `String "ops_expired");
                       ("actor", `String "operator");
                       ("action_type", `String "team_stop");
                       ("target_type", `String "team_session");
                       ("target_id", `String "session-1");
                       ("payload", `Assoc []);
                       ("delegated_tool", `String "masc_team_session_stop");
                       ("created_at", `String "2026-03-06T00:00:00Z");
                       ("expires_at", `String "2026-03-06T00:00:01Z");
                     ];
                 ])));
      let ctx = operator_ctx env sw config "operator" in
      match
        Operator_control.confirm_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
              ("confirm_token", `String "expired-token");
            ])
      with
      | Ok _ -> Alcotest.fail "expected expired confirmation error"
      | Error err ->
          Alcotest.(check string) "expired error"
            "pending confirmation expired" err)

let test_snapshot_exposes_lodge_tick_action () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "dashboard"));
      let ctx = operator_ctx env sw config "dashboard" in
      let available_actions =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "available_actions"
        |> Yojson.Safe.Util.to_list
      in
      let lodge_tick =
        List.find_opt
          (fun row ->
            Yojson.Safe.Util.(row |> member "action_type" |> to_string = "lodge_tick"))
          available_actions
      in
      match lodge_tick with
      | None -> Alcotest.fail "expected lodge_tick in available_actions"
      | Some row ->
          Alcotest.(check string) "target_type" "room"
            Yojson.Safe.Util.(row |> member "target_type" |> to_string);
          Alcotest.(check bool) "confirm_required false" false
            Yojson.Safe.Util.(row |> member "confirm_required" |> to_bool))

let test_select_checkin_agents_manual_override_quiet_hours () =
  let current_hour = Lodge_heartbeat.current_hour_kst () in
  let config =
    {
      Lodge_heartbeat.default_config with
      quiet_hours = (current_hour, current_hour + 1);
      agents_per_tick = 1;
      min_checkin_gap_s = 0.0;
    }
  in
  let agent_name = "operator-lodge-quiet-override-test" in
  let agents =
    [
      {
        Lodge_heartbeat.name = agent_name;
        preferred_hours = [];
        peak_hour = None;
        traits = [];
        interests = [];
        personality_hint = None;
        activity_level = 0.7;
      };
    ]
  in
  let pending_triggers = [ (agent_name, Lodge_heartbeat.ManualTrigger) ] in
  let blocked =
    Lodge_heartbeat.select_checkin_agents ~ignore_quiet_hours:false ~config
      ~agents ~pending_triggers
  in
  Alcotest.(check int) "quiet hours block selection" 0 (List.length blocked);
  let overridden =
    Lodge_heartbeat.select_checkin_agents ~ignore_quiet_hours:true ~config
      ~agents ~pending_triggers
  in
  Alcotest.(check int) "manual override selects one agent" 1
    (List.length overridden)

let () =
  Alcotest.run "Operator_control"
    [
      ( "operator",
        [
          Alcotest.test_case "snapshot sections" `Quick
            test_snapshot_has_expected_sections;
          Alcotest.test_case "task inject confirm flow" `Quick
            test_task_inject_requires_confirm_then_executes;
          Alcotest.test_case "team turn fallback actor" `Quick
            test_team_turn_falls_back_to_session_actor;
          Alcotest.test_case "team note logs action" `Quick
            test_team_note_records_action_log;
          Alcotest.test_case "team broadcast event" `Quick
            test_team_broadcast_records_event;
          Alcotest.test_case "team task inject confirm flow" `Quick
            test_team_task_inject_requires_confirm_then_executes;
          Alcotest.test_case "snapshot exposes lodge tick action" `Quick
            test_snapshot_exposes_lodge_tick_action;
          Alcotest.test_case "manual selection overrides quiet hours" `Quick
            test_select_checkin_agents_manual_override_quiet_hours;
          Alcotest.test_case "expired confirmation rejected" `Quick
            test_confirm_rejects_expired_token;
        ] );
    ]
