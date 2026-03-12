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

let unit_update_exn config ~actor args =
  match Command_plane_v2.unit_update_json config ~actor args with
  | Ok _ -> ()
  | Error message -> failwith message

let start_operation_exn config ~actor args =
  match Command_plane_v2.start_operation config ~actor args with
  | Ok operation -> operation
  | Error message -> failwith message

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let record_operator_judgment config ~surface ~target_type ~target_id ~summary
    ?recommended_action ~fresh_for_sec () =
  let now_unix = Unix.gettimeofday () in
  ignore
    (Operator_judgment.record config ~surface ~target_type ~target_id ~summary
       ~confidence:0.91 ?recommended_action ~generated_at:(Types.now_iso ())
       ~generated_at_unix:now_unix
       ~fresh_until:(iso_of_unix (now_unix +. fresh_for_sec))
       ~fresh_until_unix:(now_unix +. fresh_for_sec)
       ~keeper_name:"operator-judge" ())

let setup_swarm_run_env config ~owner ~worker_one ~worker_two ~run_id =
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:owner ~capabilities:[] ());
  ignore (Room.join config ~agent_name:worker_one ~capabilities:[] ());
  ignore (Room.join config ~agent_name:worker_two ~capabilities:[] ());
  unit_update_exn config ~actor:owner
    (`Assoc
      [
        ("unit_id", `String "company-main");
        ("kind", `String "company");
        ("label", `String "Main Company");
        ("leader_id", `String owner);
        ("roster", `List [ `String owner; `String worker_one; `String worker_two ]);
      ]);
  unit_update_exn config ~actor:owner
    (`Assoc
      [
        ("unit_id", `String "platoon-alpha");
        ("kind", `String "platoon");
        ("label", `String "Alpha Platoon");
        ("parent_unit_id", `String "company-main");
        ("leader_id", `String worker_one);
        ("roster", `List [ `String worker_one; `String worker_two ]);
      ]);
  let operation =
    start_operation_exn config ~actor:owner
      (`Assoc
        [
          ("assigned_unit_id", `String "company-main");
          ("objective", `String "Operator swarm resolution test");
          ("note", `String (Printf.sprintf "run_id=%s" run_id));
          ("policy_class", `String "guarded");
          ("budget_class", `String "standard");
        ])
  in
  ignore
    (match
       Command_plane_v2.dispatch_tick_json config ~actor:owner
         (`Assoc [ ("operation_id", `String operation.operation_id) ])
     with
    | Ok _ -> ()
    | Error message -> failwith message);
  operation

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
      let room = Yojson.Safe.Util.member "room" json in
      Alcotest.(check bool) "room present" true (Yojson.Safe.Util.member "room" json <> `Null);
      Alcotest.(check string) "room mirrors current_room"
        Yojson.Safe.Util.(room |> member "current_room" |> to_string)
        Yojson.Safe.Util.(room |> member "room" |> to_string);
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
      Alcotest.(check bool) "resident judge runtime present" true
        (Yojson.Safe.Util.member "resident_judge_runtime" json <> `Null);
      Alcotest.(check bool) "resident judge disabled by default" false
        Yojson.Safe.Util.
          (json |> member "resident_judge_runtime" |> member "enabled"
          |> to_bool);
      Alcotest.(check string) "judgment owner" "fallback_read_model"
        Yojson.Safe.Util.(json |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "no authoritative judgment" false
        Yojson.Safe.Util.(json |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "command plane provenance" "truth"
        Yojson.Safe.Util.(json |> member "provenance_summary" |> member "command_plane" |> to_string);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
         | `List _ -> true
         | _ -> false);
      Alcotest.(check bool) "swarm_status present" true
        (Yojson.Safe.Util.member "swarm_status" json <> `Null))

let test_snapshot_pending_confirm_summary_tracks_actor_scope () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      let ctx = operator_ctx env sw config "owner" in
      let inject_task actor title =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String actor);
                ("action_type", `String "task_inject");
                ("target_type", `String "room");
                ( "payload",
                  `Assoc
                    [
                      ("title", `String title);
                      ("description", `String "created by operator");
                      ("priority", `Int 2);
                    ] );
              ])
        with
        | Ok _ -> ()
        | Error err -> Alcotest.fail err
      in
      inject_task "operator-a" "alpha preview";
      inject_task "operator-b" "beta preview";
      let snapshot = Operator_control.snapshot_json ~actor:"operator-a" ctx in
      let summary = Yojson.Safe.Util.(snapshot |> member "pending_confirm_summary") in
      Alcotest.(check string) "actor filter" "operator-a"
        Yojson.Safe.Util.(summary |> member "actor_filter" |> to_string);
      Alcotest.(check bool) "filter active" true
        Yojson.Safe.Util.(summary |> member "filter_active" |> to_bool);
      Alcotest.(check int) "visible count" 1
        Yojson.Safe.Util.(summary |> member "visible_count" |> to_int);
      Alcotest.(check int) "total count" 2
        Yojson.Safe.Util.(summary |> member "total_count" |> to_int);
      Alcotest.(check int) "hidden count" 1
        Yojson.Safe.Util.(summary |> member "hidden_count" |> to_int);
      Alcotest.(check bool) "hidden actor listed" true
        (List.mem (`String "operator-b")
           Yojson.Safe.Util.(summary |> member "hidden_actors" |> to_list));
      let confirm_required_actions =
        Yojson.Safe.Util.(summary |> member "confirm_required_actions" |> to_list)
      in
      Alcotest.(check bool) "task inject listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string)
             = "task_inject")
           confirm_required_actions))

let test_orchestra_room_core_shape () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "owner"));
      ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Room.add_task config ~title:"orchestra backlog" ~priority:2 ~description:"");
      ignore (Room.broadcast config ~from_agent:"owner" ~content:"orchestra seed");
      let json = Command_plane_orchestra.json (operator_ctx env sw config "owner") in
      let nodes = Yojson.Safe.Util.(json |> member "nodes" |> to_list) in
      Alcotest.(check bool) "room node exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "kind" |> to_string) = "room")
           nodes);
      Alcotest.(check int) "session count" 0
        Yojson.Safe.Util.(json |> member "summary" |> member "session_count" |> to_int);
      Alcotest.(check string) "focus kind" "node"
        Yojson.Safe.Util.(json |> member "focus" |> member "target_kind" |> to_string))

let test_orchestra_includes_session_edge_and_pending_signal () =
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
      (match
         Operator_control.action_json ctx
           (`Assoc
             [
               ("actor", `String "dashboard");
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
       with
      | Ok _ -> ()
      | Error err -> Alcotest.fail err);
      let json = Command_plane_orchestra.json ctx in
      let nodes = Yojson.Safe.Util.(json |> member "nodes" |> to_list) in
      let edges = Yojson.Safe.Util.(json |> member "edges" |> to_list) in
      let signals = Yojson.Safe.Util.(json |> member "signals" |> to_list) in
      Alcotest.(check bool) "session node exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "id" |> to_string)
             = "session:" ^ session_id)
           nodes);
      Alcotest.(check bool) "room-session edge exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "source" |> to_string)
             = "room:default"
             && Yojson.Safe.Util.(row |> member "target" |> to_string)
                = "session:" ^ session_id)
           edges);
      Alcotest.(check bool) "pending confirm signal exists" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "kind" |> to_string)
             = "pending_confirm")
           signals))

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
      Alcotest.(check bool) "resident judge runtime present" true
        (Yojson.Safe.Util.member "resident_judge_runtime" digest <> `Null);
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
      Alcotest.(check bool) "attention provenance present" true
        (List.for_all
           (fun item ->
             String.equal "derived"
               Yojson.Safe.Util.(item |> member "provenance" |> to_string))
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
      Alcotest.(check string) "recommendation provenance summary" "fallback"
        Yojson.Safe.Util.(digest |> member "provenance_summary" |> member "recommended_actions" |> to_string);
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
           events);
      let spawn_event =
        match
          List.find_opt
            (fun json ->
              Yojson.Safe.Util.(json |> member "event_type" |> to_string)
              = "team_step_spawn")
            events
        with
        | Some json -> json
        | None -> Alcotest.fail "expected team_step_spawn event"
      in
      Alcotest.(check string) "spawn actor falls back to owner" "owner"
        Yojson.Safe.Util.(
          spawn_event |> member "detail" |> member "actor" |> to_string)
    )

let test_digest_room_prefers_fresh_resident_judgment () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      ignore (Room.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.warroom"
        ~target_type:Operator_judgment.Room ~target_id:None
        ~summary:"Pause the room before taking any destructive action."
        ~recommended_action:
          (`Assoc
            [
              ("action_kind", `String "pause_room");
              ("resolved_tool", `String "masc_operator_confirm");
              ("target_type", `String "room");
              ("target_id", `Null);
              ("reason", `String "resident judge requires manual gate");
              ("payload_preview", `Assoc [ ("reason", `String "manual review") ]);
            ])
        ~fresh_for_sec:90.0 ();
      Alcotest.(check int) "stored judgments" 1
        (List.length (Operator_judgment.load_all config));
      (match
         Operator_judgment.latest_active config ~surface:"command.warroom"
           ~target_type:Operator_judgment.Room ~target_id:None
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected room judgment in %s"
            (Operator_judgment.judgments_path config));
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner" "resident_operator_keeper"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment available" true
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer" "judgment"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check string) "active summary from judgment"
        "Pause the room before taking any destructive action."
        Yojson.Safe.Util.
          (digest |> member "active_summary" |> member "summary" |> to_string);
      Alcotest.(check string) "active recommendation source" "judgment"
        Yojson.Safe.Util.
          (digest |> member "active_recommendation_source" |> to_string);
      Alcotest.(check bool) "judgment present" true
        (Yojson.Safe.Util.member "judgment" digest <> `Null))

let test_digest_room_ignores_stale_resident_judgment () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      ignore (Room.join config ~agent_name:"operator" ~capabilities:[] ());
      record_operator_judgment config ~surface:"command.warroom"
        ~target_type:Operator_judgment.Room ~target_id:None
        ~summary:"This judgment is stale."
        ~fresh_for_sec:(-5.0) ();
      let ctx = operator_ctx env sw config "operator" in
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "judgment owner fallback" "fallback_read_model"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "authoritative judgment unavailable" false
        Yojson.Safe.Util.
          (digest |> member "authoritative_judgment_available" |> to_bool);
      Alcotest.(check string) "active guidance layer fallback" "fallback"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check bool) "judgment missing" true
        (Yojson.Safe.Util.member "judgment" digest = `Null))

let test_digest_team_session_prefers_fresh_resident_judgment () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let ctx = team_ctx env sw config "operator" in
      let session_id = start_session_exn ctx in
      record_operator_judgment config ~surface:"command.swarm"
        ~target_type:Operator_judgment.Team_session
        ~target_id:(Some session_id)
        ~summary:"Spawn one more worker before continuing the session."
        ~fresh_for_sec:120.0 ();
      (match
         Operator_judgment.latest_active config ~surface:"command.swarm"
           ~target_type:Operator_judgment.Team_session
           ~target_id:(Some session_id)
       with
      | Some _ -> ()
      | None ->
          Alcotest.failf "expected team session judgment in %s"
            (Operator_judgment.judgments_path config));
      let digest =
        match
          Operator_control.digest_json ~actor:"operator"
            ~target_type:"team_session" ~target_id:session_id
            (operator_ctx env sw config "operator")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "team_session judgment owner"
        "resident_operator_keeper"
        Yojson.Safe.Util.(digest |> member "judgment_owner" |> to_string);
      Alcotest.(check string) "team_session active guidance layer" "judgment"
        Yojson.Safe.Util.(digest |> member "active_guidance_layer" |> to_string);
      Alcotest.(check string) "team_session active summary"
        "Spawn one more worker before continuing the session."
        Yojson.Safe.Util.
          (digest |> member "active_summary" |> member "summary" |> to_string))

let test_operator_judgment_write_and_latest_roundtrip () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator-judge"));
      let ctx = operator_ctx env sw config "operator-judge" in
      let written =
        match
          Operator_control.judgment_write_json ctx
            (`Assoc
              [
                ("surface", `String "command.warroom");
                ("target_type", `String "room");
                ("summary", `String "Resident judge requests a human checkpoint.");
                ("confidence", `Float 0.88);
                ("fresh_ttl_sec", `Int 90);
                ("evidence_refs", `List [ `String "trace:opsd-1" ]);
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "write ok" "ok"
        Yojson.Safe.Util.(written |> member "status" |> to_string);
      let latest =
        match
          Operator_control.judgment_latest_json ctx
            (`Assoc
              [
                ("surface", `String "command.warroom");
                ("target_type", `String "room");
              ])
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "latest ok" "ok"
        Yojson.Safe.Util.(latest |> member "status" |> to_string);
      Alcotest.(check string) "latest summary"
        "Resident judge requests a human checkpoint."
        Yojson.Safe.Util.
          (latest |> member "judgment" |> member "summary" |> to_string))

let test_confirm_keeps_pending_token_when_delegated_action_fails () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let pending_dir = Filename.concat (Room.masc_dir config) "operator" in
      let path = Filename.concat pending_dir "pending_confirms.json" in
      Masc_mcp.Room_utils.mkdir_p pending_dir;
      let token = "retry-token" in
      let entry_json =
        `Assoc
          [
            ("token", `String token);
            ("trace_id", `String "trace-retry");
            ("actor", `String "operator");
            ("action_type", `String "team_stop");
            ("target_type", `String "team_session");
            ("target_id", `String "missing-session");
            ("payload", `Assoc []);
            ("delegated_tool", `String "masc_team_session_stop");
            ("created_at", `String (Types.now_iso ()));
            ("expires_at", `Null);
          ]
      in
      Masc_mcp.Room_utils.write_json config path (`List [ entry_json ]);
      let ctx = operator_ctx env sw config "operator" in
      (match
         Operator_control.confirm_json ctx
           (`Assoc
             [
               ("actor", `String "operator");
               ("confirm_token", `String token);
             ])
       with
      | Ok _ -> Alcotest.fail "expected delegated action failure"
      | Error err ->
          Alcotest.(check bool) "non-empty error" true (String.length err > 0));
      let pending_confirms =
        Operator_control.pending_confirms_json ~actor:"operator" config
        |> Yojson.Safe.Util.to_list
      in
      Alcotest.(check int) "pending confirm retained" 1
        (List.length pending_confirms);
      Alcotest.(check string) "same token retained" token
        Yojson.Safe.Util.(
          List.hd pending_confirms |> member "token" |> to_string))

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
        Yojson.Safe.Util.(worker |> member "spawn_role" |> to_string);
      Alcotest.(check string) "recommendation provenance" "fallback"
        Yojson.Safe.Util.(recommendation |> member "provenance" |> to_string))

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

let test_swarm_run_continue_requires_confirm_then_executes () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let run_id = "operator-swarm-continue" in
      let operation =
        setup_swarm_run_env config ~owner:"owner-root-node"
          ~worker_one:"alpha-lead-node" ~worker_two:"alpha-two-node" ~run_id
      in
      ignore
        (match
           Command_plane_v2.pause_operation_json config ~actor:"owner"
             (`Assoc [ ("operation_id", `String operation.operation_id) ])
         with
        | Ok _ -> ()
        | Error message -> failwith message);
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "swarm_run_continue");
              ("target_type", `String "swarm_run");
              ("target_id", `String run_id);
              ("payload", `Assoc [ ("operation_id", `String operation.operation_id) ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      Alcotest.(check string) "delegated tool" "swarm_run_continue_chain"
        Yojson.Safe.Util.(action_json |> member "delegated_tool" |> to_string);
      Alcotest.(check string) "preview kind" "continue"
        Yojson.Safe.Util.(action_json |> member "preview" |> member "resolution_kind" |> to_string);
      Alcotest.(check int) "preview step count" 2
        Yojson.Safe.Util.(action_json |> member "preview" |> member "tool_chain_preview" |> to_list |> List.length);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
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
      let delegated_result = Yojson.Safe.Util.member "delegated_tool_result" confirm_json in
      Alcotest.(check int) "executed steps" 2
        Yojson.Safe.Util.(delegated_result |> member "result" |> to_list |> List.length);
      Alcotest.(check string) "resolution persisted" "continued"
        Yojson.Safe.Util.(delegated_result |> member "resolution" |> member "status" |> to_string))

let test_swarm_run_abandon_records_soft_resolution () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      let run_id = "operator-swarm-abandon" in
      let operation =
        setup_swarm_run_env config ~owner:"owner-root-node"
          ~worker_one:"alpha-lead-node" ~worker_two:"alpha-two-node" ~run_id
      in
      let ctx = operator_ctx env sw config "dashboard" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "dashboard");
              ("action_type", `String "swarm_run_abandon");
              ("target_type", `String "swarm_run");
              ("target_id", `String run_id);
              ("payload", `Assoc [ ("reason", `String "operator chose to move on") ]);
            ])
      in
      let action_json =
        match action_json with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check bool) "confirm required" true
        Yojson.Safe.Util.(action_json |> member "confirm_required" |> to_bool);
      let confirm_token =
        Yojson.Safe.Util.(action_json |> member "confirm_token" |> to_string)
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
      let delegated_result = Yojson.Safe.Util.member "delegated_tool_result" confirm_json in
      Alcotest.(check string) "delegated tool" "swarm_run_resolution"
        Yojson.Safe.Util.(delegated_result |> member "delegated_tool" |> to_string);
      Alcotest.(check string) "resolution persisted" "abandoned"
        Yojson.Safe.Util.(delegated_result |> member "resolution" |> member "status" |> to_string);
      let operation_status =
        Command_plane_v2.operation_status_json config ~operation_id:operation.operation_id ()
        |> Yojson.Safe.Util.member "operations"
        |> Yojson.Safe.Util.index 0
        |> Yojson.Safe.Util.member "operation"
        |> Yojson.Safe.Util.member "status"
        |> Yojson.Safe.Util.to_string
      in
      Alcotest.(check string) "operation not stopped" "active" operation_status)

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
            Yojson.Safe.Util.(keeper_recover |> member "confirm_required" |> to_bool);
          let swarm_continue =
            match find_action "swarm_run_continue" with
            | Some row -> row
            | None -> Alcotest.fail "expected swarm_run_continue in available_actions"
          in
          Alcotest.(check string) "swarm continue target_type" "swarm_run"
            Yojson.Safe.Util.(swarm_continue |> member "target_type" |> to_string);
          Alcotest.(check bool) "swarm continue confirm true" true
            Yojson.Safe.Util.(swarm_continue |> member "confirm_required" |> to_bool))

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
                ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
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
      (match
         Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
           ~args:(`Assoc [ ("name", `String keeper_name) ])
       with
      | Some (false, err) ->
          Alcotest.(check string) "resident status missing after down"
            (Printf.sprintf "resident keeper not found: %s" keeper_name)
            err
      | Some (true, _) -> Alcotest.fail "resident keeper should not remain registered after down"
      | None -> Alcotest.fail "missing resident keeper status dispatch");
      let ok, body =
        dispatch_keeper_exn keeper_ctx ~name:"masc_persistent_agent_status"
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
      Alcotest.(check bool) "persistent status ok" true ok;
      let diagnostic = parse_json_exn body |> Yojson.Safe.Util.member "diagnostic" in
      Alcotest.(check string) "health_state" "offline"
        Yojson.Safe.Util.(diagnostic |> member "health_state" |> to_string);
      Alcotest.(check string) "next action recover" "recover"
        Yojson.Safe.Util.(diagnostic |> member "next_action_path" |> to_string);
      Alcotest.(check bool) "recoverable true" true
        Yojson.Safe.Util.(diagnostic |> member "recoverable" |> to_bool);
      Alcotest.(check bool) "summary present" true
        (String.length Yojson.Safe.Util.(diagnostic |> member "summary" |> to_string) > 0))

let test_snapshot_keeper_tool_audit_fallback () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "audit-keeper";
      cleanup_dir base_dir)
    (fun () ->
      let config = Room.default_config base_dir in
      ignore (Room.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
        { config; sw; clock = Eio.Stdenv.clock env }
      in
      let keeper_name = "audit-keeper" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose dashboard fallback keeper audit");
                ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
                ("presence_keepalive", `Bool true);
                ("proactive_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Masc_mcp.Keeper_keepalive.stop_keepalive keeper_name;
      let snapshot =
        Operator_control.snapshot_json ~include_messages:false ~include_sessions:false
          ~include_keepers:true (operator_ctx env sw config "operator")
      in
      let open Yojson.Safe.Util in
      let keeper =
        snapshot
        |> member "keepers" |> member "items" |> to_list
        |> List.find (fun row -> row |> member "name" |> to_string = keeper_name)
      in
      Alcotest.(check string) "offline when no agent runtime" "offline"
        (keeper |> member "status" |> to_string);
      Alcotest.(check bool) "allowed tool fallback present" true
        ((keeper |> member "allowed_tool_names" |> to_list) <> []);
      Alcotest.(check bool) "tool audit source omitted without evidence" true
        (keeper |> member "tool_audit_source" = `Null);
      Alcotest.(check bool) "diagnostic present" true
        (keeper |> member "diagnostic" <> `Null);
      Alcotest.(check string) "diagnostic health offline" "offline"
        (keeper |> member "diagnostic" |> member "health_state" |> to_string);
      Alcotest.(check string) "diagnostic continuity desired offline" "desired_offline"
        (keeper |> member "diagnostic" |> member "continuity_state" |> to_string))

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
          Alcotest.test_case "snapshot pending confirm summary tracks actor scope" `Quick
            test_snapshot_pending_confirm_summary_tracks_actor_scope;
          Alcotest.test_case "orchestra room core shape" `Quick
            test_orchestra_room_core_shape;
          Alcotest.test_case "orchestra session edge and pending signal" `Quick
            test_orchestra_includes_session_edge_and_pending_signal;
          Alcotest.test_case "digest room pending confirm attention" `Quick
            test_digest_room_exposes_pending_confirm_attention;
          Alcotest.test_case "digest room prefers fresh resident judgment"
            `Quick test_digest_room_prefers_fresh_resident_judgment;
          Alcotest.test_case "digest room ignores stale resident judgment"
            `Quick test_digest_room_ignores_stale_resident_judgment;
          Alcotest.test_case "digest team session shape" `Quick
            test_digest_team_session_shape;
          Alcotest.test_case "digest team session prefers fresh resident judgment"
            `Quick test_digest_team_session_prefers_fresh_resident_judgment;
          Alcotest.test_case "digest team session can skip workers" `Quick
            test_digest_team_session_can_skip_workers;
          Alcotest.test_case "operator judgment write and latest roundtrip"
            `Quick test_operator_judgment_write_and_latest_roundtrip;
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
          Alcotest.test_case "confirm keeps token on delegated failure" `Quick
            test_confirm_keeps_pending_token_when_delegated_action_fails;
          Alcotest.test_case "digest recommends worker spawn batch" `Quick
            test_digest_recommends_worker_spawn_batch_for_planned_worker_without_turn;
          Alcotest.test_case "snapshot exposes keeper and lodge actions" `Quick
            test_snapshot_exposes_keeper_and_lodge_actions;
          Alcotest.test_case "manual selection overrides quiet hours" `Quick
            test_select_checkin_agents_manual_override_quiet_hours;
          Alcotest.test_case "keeper status exposes summary and recoverable" `Quick
            test_keeper_status_exposes_summary_and_recoverable;
          Alcotest.test_case "snapshot keeper tool audit fallback" `Quick
            test_snapshot_keeper_tool_audit_fallback;
          Alcotest.test_case "manual lodge tick updates observable state" `Quick
            test_manual_lodge_tick_updates_observable_state;
          Alcotest.test_case "expired confirmation rejected" `Quick
            test_confirm_rejects_expired_token;
          Alcotest.test_case "swarm run continue confirm flow" `Quick
            test_swarm_run_continue_requires_confirm_then_executes;
          Alcotest.test_case "swarm run abandon soft resolution" `Quick
            test_swarm_run_abandon_records_soft_resolution;
        ] );
    ]
