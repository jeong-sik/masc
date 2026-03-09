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
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    mcp_session_id;
  }

let team_ctx env sw config agent_name : _ Tool_team_session.context =
  { config; agent_name; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }

let dispatch_team_exn ctx ~name ~args =
  match Tool_team_session.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("team session dispatch missing: " ^ name)

let dispatch_keeper_exn ctx ~name ~args =
  match Tool_keeper.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("keeper dispatch missing: " ^ name)

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
      Alcotest.(check bool) "attention summary present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
         | `List _ -> true
         | _ -> false);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" json <> `Null))

let test_digest_room_exposes_pending_confirm_attention () =
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
      (match action_json with Ok _ -> () | Error err -> Alcotest.fail err);
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "room"
        Yojson.Safe.Util.(digest |> member "target_type" |> to_string);
      Alcotest.(check string) "health" "bad"
        Yojson.Safe.Util.(digest |> member "health" |> to_string);
      Alcotest.(check bool) "command_plane present" true
        (Yojson.Safe.Util.member "command_plane" digest <> `Null);
      Alcotest.(check bool) "command_plane microarch present" true
        (Yojson.Safe.Util.(digest |> member "command_plane" |> member "operations"
         |> member "microarch")
         <> `Null);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" digest <> `Null);
      let attention_items = Yojson.Safe.Util.(digest |> member "attention_items" |> to_list) in
      Alcotest.(check bool) "pending confirm attention present" true
        (List.exists
           (fun item ->
             Yojson.Safe.Util.(item |> member "kind" |> to_string)
             = "pending_confirm_waiting")
           attention_items);
      Alcotest.(check bool) "command attention present" true
        (List.exists
           (fun item ->
             String.starts_with
               ~prefix:"command_"
               Yojson.Safe.Util.(item |> member "kind" |> to_string))
           attention_items)
    )

let test_digest_team_session_shape () =
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
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "team_session"
        Yojson.Safe.Util.(digest |> member "target_type" |> to_string);
      Alcotest.(check string) "target_id" session_id
        Yojson.Safe.Util.(digest |> member "target_id" |> to_string);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" digest <> `Null);
      Alcotest.(check bool) "command_plane present" true
        (Yojson.Safe.Util.member "command_plane" digest <> `Null);
      Alcotest.(check int) "single session card" 1
        Yojson.Safe.Util.(digest |> member "session_cards" |> to_list |> List.length);
      Alcotest.(check bool) "worker_cards list" true
        (match Yojson.Safe.Util.member "worker_cards" digest with
         | `List _ -> true
         | _ -> false))

let test_digest_team_session_can_skip_workers () =
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
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ~include_workers:false ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check int) "worker_cards skipped" 0
        Yojson.Safe.Util.(digest |> member "worker_cards" |> to_list |> List.length))

let test_snapshot_and_digest_expose_role_runtime_census () =
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
      let update_result =
        Team_session_store.update_session config session_id (fun session ->
            {
              session with
              planned_workers =
                [
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-manager";
                    spawn_role = Some "middle-manager";
                    spawn_model = Some "qwen3.5";
                    worker_class = Some Team_session_types.Worker_manager;
                    parent_actor = None;
                    capsule_mode = Some Team_session_types.Capsule_capsule;
                    runtime_pool = Some "local64";
                    lane_id = Some "lane-a";
                    controller_level = Some Team_session_types.Controller_lane;
                    control_domain = Some Team_session_types.Domain_execution;
                    supervisor_actor = Some "ctrl-root";
                    model_tier = Some Team_session_types.Tier_35b;
                    task_profile = Some Team_session_types.Profile_decide;
                    risk_level = Some Team_session_types.Risk_high;
                    routing_confidence = Some 0.94;
                    routing_reason = Some "explicit:lead_manager";
                    routing_escalated = false;
                  };
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-metacog";
                    spawn_role = Some "metacog-observer";
                    spawn_model = Some "qwen3.5";
                    worker_class = Some Team_session_types.Worker_metacog;
                    parent_actor = Some "llama-local-manager";
                    capsule_mode = Some Team_session_types.Capsule_capsule;
                    runtime_pool = Some "local64";
                    lane_id = Some "global";
                    controller_level = Some Team_session_types.Controller_submanager;
                    control_domain = Some Team_session_types.Domain_meta;
                    supervisor_actor = Some "ctrl-global-metacog";
                    model_tier = Some Team_session_types.Tier_35b;
                    task_profile = Some Team_session_types.Profile_verify;
                    risk_level = Some Team_session_types.Risk_high;
                    routing_confidence = Some 0.88;
                    routing_reason = Some "policy:metacog_guard";
                    routing_escalated = true;
                  };
                  {
                    Team_session_types.spawn_agent = "llama";
                    runtime_actor = Some "llama-local-executor";
                    spawn_role = Some "executor-1";
                    spawn_model = Some "qwen3.5";
                    worker_class = Some Team_session_types.Worker_executor;
                    parent_actor = Some "llama-local-manager";
                    capsule_mode = Some Team_session_types.Capsule_inherit;
                    runtime_pool = Some "local64";
                    lane_id = Some "lane-a";
                    controller_level = Some Team_session_types.Controller_worker;
                    control_domain = Some Team_session_types.Domain_execution;
                    supervisor_actor = Some "ctrl-lane-a";
                    model_tier = Some Team_session_types.Tier_9b;
                    task_profile = Some Team_session_types.Profile_normalize;
                    risk_level = Some Team_session_types.Risk_low;
                    routing_confidence = Some 0.83;
                    routing_reason = Some "rule:machine_checkable";
                    routing_escalated = false;
                  };
                ];
              updated_at_iso = Types.now_iso ();
            })
      in
      (match update_result with Ok _ -> () | Error err -> Alcotest.fail err);
      let ctx = operator_ctx env sw config "dashboard" in
      let snapshot = Operator_control.snapshot_json ctx in
      Alcotest.(check int) "room role census manager" 1
        Yojson.Safe.Util.(snapshot |> member "role_census" |> member "manager" |> to_int);
      Alcotest.(check int) "room role census metacog" 1
        Yojson.Safe.Util.(snapshot |> member "role_census" |> member "metacog" |> to_int);
      Alcotest.(check int) "room runtime pool local64" 3
        Yojson.Safe.Util.(snapshot |> member "runtime_pools" |> member "local64" |> to_int);
      Alcotest.(check int) "room tier 35b count" 2
        Yojson.Safe.Util.(snapshot |> member "model_tiers" |> member "35b" |> to_int);
      Alcotest.(check int) "room tier 9b count" 1
        Yojson.Safe.Util.(snapshot |> member "model_tiers" |> member "9b" |> to_int);
      Alcotest.(check int) "room task profile normalize" 1
        Yojson.Safe.Util.(snapshot |> member "task_profiles" |> member "normalize" |> to_int);
      Alcotest.(check int) "room escalation count" 1
        Yojson.Safe.Util.(snapshot |> member "escalation_count" |> to_int);
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let session_card =
        Yojson.Safe.Util.(digest |> member "session_cards" |> index 0)
      in
      Alcotest.(check string) "scale_profile" "standard"
        Yojson.Safe.Util.(session_card |> member "scale_profile" |> to_string);
      Alcotest.(check int) "session card manager count" 1
        Yojson.Safe.Util.(session_card |> member "worker_class_counts" |> member "manager" |> to_int);
      Alcotest.(check int) "session card metacog count" 1
        Yojson.Safe.Util.(session_card |> member "worker_class_counts" |> member "metacog" |> to_int);
      Alcotest.(check int) "session card runtime pool local64" 3
        Yojson.Safe.Util.(session_card |> member "runtime_pool_counts" |> member "local64" |> to_int);
      Alcotest.(check int) "session card tier 35b count" 2
        Yojson.Safe.Util.(session_card |> member "tier_counts" |> member "35b" |> to_int);
      Alcotest.(check int) "session card tier 9b count" 1
        Yojson.Safe.Util.(session_card |> member "tier_counts" |> member "9b" |> to_int);
      Alcotest.(check int) "session card profile decide count" 1
        Yojson.Safe.Util.(session_card |> member "task_profile_counts" |> member "decide" |> to_int);
      Alcotest.(check int) "session card escalation count" 1
        Yojson.Safe.Util.(session_card |> member "escalation_count" |> to_int);
      let worker_cards =
        Yojson.Safe.Util.(digest |> member "worker_cards" |> to_list)
      in
      let manager_card =
        match
          List.find_opt
            (fun card ->
              Yojson.Safe.Util.(card |> member "actor" |> to_string)
              = "llama-local-manager")
            worker_cards
        with
        | Some card -> card
        | None -> Alcotest.fail "expected manager worker card"
      in
      Alcotest.(check string) "manager card model tier" "35b"
        Yojson.Safe.Util.(manager_card |> member "model_tier" |> to_string);
      Alcotest.(check string) "manager card task profile" "decide"
        Yojson.Safe.Util.(manager_card |> member "task_profile" |> to_string);
      Alcotest.(check string) "manager card risk level" "high"
        Yojson.Safe.Util.(manager_card |> member "risk_level" |> to_string))

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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let delegated = action_json |> Yojson.Safe.Util.member "result" in
      Alcotest.(check bool) "override true" true
        (delegated |> Yojson.Safe.Util.member "operator_override"
         |> Yojson.Safe.Util.to_bool);
      Alcotest.(check string) "result delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(delegated |> member "delegated_tool" |> to_string);
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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
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
      Alcotest.(check string) "delegated tool result" "masc_team_session_step"
        Yojson.Safe.Util.(
          confirm_json |> member "delegated_tool_result" |> member "delegated_tool"
          |> to_string);
      let pending_confirms =
        Operator_control.snapshot_json ~actor:"dashboard" ctx
        |> Yojson.Safe.Util.member "pending_confirms"
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm cleared" 0 (List.length pending_confirms))

let test_team_worker_spawn_batch_requires_confirm_then_executes () =
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
              ("action_type", `String "team_worker_spawn_batch");
              ("target_id", `String session_id);
              ( "payload",
                `Assoc
                  [
                    ( "spawn_batch",
                      `List
                        [
                          `Assoc
                            [
                              ("spawn_agent", `String "not-a-real-agent");
                              ("spawn_prompt", `String "record one worker turn");
                              ("spawn_role", `String "replacement");
                              ("spawn_timeout_seconds", `Int 1);
                            ];
                        ] );
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
      Alcotest.(check string) "delegated tool" "masc_team_session_step"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      let confirm_token =
        action_json |> Yojson.Safe.Util.member "confirm_token"
        |> Yojson.Safe.Util.to_string
      in
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
      let delegated_result =
        Yojson.Safe.Util.member "delegated_tool_result" confirm_json
      in
      Alcotest.(check string) "delegated tool result" "masc_team_session_step"
        Yojson.Safe.Util.(delegated_result |> member "delegated_tool" |> to_string);
      let events = Team_session_store.read_events ~max_events:20 config session_id in
      Alcotest.(check bool) "team_step_spawn recorded" true
        (List.exists
           (fun json ->
             Yojson.Safe.Util.(json |> member "event_type" |> to_string)
             = "team_step_spawn")
           events))

let test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn () =
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
      let now = Unix.gettimeofday () in
      let update_result =
        Team_session_store.update_session config session_id (fun session ->
            {
              session with
              started_at = now -. 240.0;
              planned_workers =
	                [
	                  {
	                    Team_session_types.spawn_agent = "llama";
	                    runtime_actor = Some "llama-local-deadbeef";
	                    spawn_role = Some "implementer-a";
	                    spawn_model = Some "qwen3.5";
	                    worker_class = None;
	                    parent_actor = None;
	                    capsule_mode = None;
	                    runtime_pool = None;
	                    lane_id = Some "lane-a";
	                    controller_level = Some Team_session_types.Controller_worker;
	                    control_domain = Some Team_session_types.Domain_execution;
	                    supervisor_actor = Some "ctrl-lane-a";
	                    model_tier = Some Team_session_types.Tier_9b;
	                    task_profile = Some Team_session_types.Profile_normalize;
	                    risk_level = Some Team_session_types.Risk_low;
	                    routing_confidence = Some 0.82;
	                    routing_reason = Some "rule:machine_checkable";
	                    routing_escalated = false;
	                  };
	                ];
              updated_at_iso = Types.now_iso ();
            })
      in
      (match update_result with Ok _ -> () | Error err -> Alcotest.fail err);
      let ctx = operator_ctx env sw config "dashboard" in
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            ~target_type:"team_session" ~target_id:session_id ctx
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let recommendations =
        Yojson.Safe.Util.(digest |> member "recommended_actions" |> to_list)
      in
      let recommendation =
        match
          List.find_opt
            (fun item ->
              Yojson.Safe.Util.(item |> member "action_type" |> to_string)
              = "team_worker_spawn_batch")
            recommendations
        with
        | Some item -> item
        | None -> Alcotest.fail "expected team_worker_spawn_batch recommendation"
      in
      let spawn_batch =
        Yojson.Safe.Util.(
          recommendation |> member "suggested_payload" |> member "spawn_batch"
          |> to_list)
      in
      Alcotest.(check int) "single worker stub" 1 (List.length spawn_batch);
      let worker = List.hd spawn_batch in
      Alcotest.(check string) "spawn_agent" "llama"
        Yojson.Safe.Util.(worker |> member "spawn_agent" |> to_string);
      Alcotest.(check string) "spawn_role" "implementer-a"
        Yojson.Safe.Util.(worker |> member "spawn_role" |> to_string))

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

let test_snapshot_exposes_keeper_and_lodge_actions () =
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
      let find_action action_type =
        List.find_opt
          (fun row ->
            Yojson.Safe.Util.(row |> member "action_type" |> to_string = action_type))
          available_actions
      in
      match find_action "lodge_tick" with
      | None -> Alcotest.fail "expected lodge_tick in available_actions"
      | Some row ->
          Alcotest.(check string) "target_type" "room"
            Yojson.Safe.Util.(row |> member "target_type" |> to_string);
          Alcotest.(check bool) "confirm_required false" false
            Yojson.Safe.Util.(row |> member "confirm_required" |> to_bool);
          let keeper_probe =
            match find_action "keeper_probe" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_probe in available_actions"
          in
          Alcotest.(check string) "keeper_probe target_type" "keeper"
            Yojson.Safe.Util.(keeper_probe |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_probe confirm false" false
            Yojson.Safe.Util.(keeper_probe |> member "confirm_required" |> to_bool);
          let keeper_recover =
            match find_action "keeper_recover" with
            | Some row -> row
            | None -> Alcotest.fail "expected keeper_recover in available_actions"
          in
          Alcotest.(check string) "keeper_recover target_type" "keeper"
            Yojson.Safe.Util.(keeper_recover |> member "target_type" |> to_string);
          Alcotest.(check bool) "keeper_recover confirm false" false
            Yojson.Safe.Util.(keeper_recover |> member "confirm_required" |> to_bool))

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

let test_keeper_status_exposes_summary_and_recoverable () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        { config; sw; clock = Eio.Stdenv.clock env }
      in
      let keeper_name = "probe-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Probe keeper runtime");
                ("models", `List [ `String "ollama:glm-4.7-flash" ]);
                ("presence_keepalive", `Bool false);
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_down"
          ~args:(`Assoc [ ("name", `String keeper_name) ])
      in
      Alcotest.(check bool) "keeper down ok" true ok;
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_status"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("fast", `Bool false);
                ("include_context", `Bool false);
                ("include_metrics_overview", `Bool false);
                ("include_memory_bank", `Bool false);
                ("include_history_tail", `Bool false);
                ("include_compaction_history", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper status ok" true ok;
      let diagnostic = parse_json_exn body |> Yojson.Safe.Util.member "diagnostic" in
      Alcotest.(check string) "health_state" "offline"
        Yojson.Safe.Util.(diagnostic |> member "health_state" |> to_string);
      Alcotest.(check string) "next action recover" "recover"
        Yojson.Safe.Util.(diagnostic |> member "next_action_path" |> to_string);
      Alcotest.(check bool) "recoverable true" true
        Yojson.Safe.Util.(diagnostic |> member "recoverable" |> to_bool);
      Alcotest.(check bool) "summary present" true
        (String.length Yojson.Safe.Util.(diagnostic |> member "summary" |> to_string) > 0))

let test_manual_lodge_tick_updates_observable_state () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let before = Lodge_heartbeat.lodge_status () in
      let result : Lodge_heartbeat.heartbeat_result =
        {
          timestamp = Unix.gettimeofday ();
          current_hour = 11;
          agents_checked = 2;
          checkins =
            [
              ( "historian",
                Lodge_heartbeat.ManualTrigger,
                Lodge_heartbeat.Passed "no valuable contribution" );
            ];
          agents_woken = [];
          encounter_rolled = None;
          activity_report = "manual test tick";
        }
      in
      Lodge_heartbeat.record_tick_result result;
      let after = Lodge_heartbeat.lodge_status () in
      Alcotest.(check int) "manual tick increments total ticks"
        (before.ls_total_ticks + 1) after.ls_total_ticks;
      Alcotest.(check int) "manual tick increments total checkins"
        (before.ls_total_checkins + List.length result.Lodge_heartbeat.checkins)
        after.ls_total_checkins;
      Alcotest.(check bool) "manual tick stores last result" true
        (Option.is_some after.ls_last_result);
      Alcotest.(check bool) "manual tick running cleared" false
        after.ls_manual_tick_running)

let () =
  Alcotest.run "Operator_control"
    [
      ( "operator",
        [
          Alcotest.test_case "snapshot sections" `Quick
            test_snapshot_has_expected_sections;
          Alcotest.test_case "digest room pending confirm attention" `Quick
            test_digest_room_exposes_pending_confirm_attention;
          Alcotest.test_case "digest team session shape" `Quick
            test_digest_team_session_shape;
          Alcotest.test_case "digest team session can skip workers" `Quick
            test_digest_team_session_can_skip_workers;
          Alcotest.test_case "snapshot and digest expose role runtime census" `Quick
            test_snapshot_and_digest_expose_role_runtime_census;
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
          Alcotest.test_case "team worker spawn batch confirm flow" `Quick
            test_team_worker_spawn_batch_requires_confirm_then_executes;
          Alcotest.test_case "digest recommends worker spawn batch" `Quick
            test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn;
          Alcotest.test_case "snapshot exposes keeper and lodge actions" `Quick
            test_snapshot_exposes_keeper_and_lodge_actions;
          Alcotest.test_case "manual selection overrides quiet hours" `Quick
            test_select_checkin_agents_manual_override_quiet_hours;
          Alcotest.test_case "keeper status exposes summary and recoverable" `Quick
            test_keeper_status_exposes_summary_and_recoverable;
          Alcotest.test_case "manual lodge tick updates observable state" `Quick
            test_manual_lodge_tick_updates_observable_state;
          Alcotest.test_case "expired confirmation rejected" `Quick
            test_confirm_rejects_expired_token;
        ] );
    ]
