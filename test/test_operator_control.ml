open Masc_mcp

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

let operator_ctx env sw config agent_name : _ Operator_control.context =
  { config; agent_name; sw; clock = Eio.Stdenv.clock env }

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
        (Yojson.Safe.Util.member "pending_confirms" json <> `Null))

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
        ] );
    ]
