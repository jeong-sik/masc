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
  with_eio @@ fun _env ->
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

let test_memory_backend_event_lock_serializes_fibers () =
  let cluster_name = "team-session-lock-" ^ Team_session_store.make_session_id () in
  with_env "MASC_STORAGE_TYPE" (Some "memory") @@ fun () ->
  with_env "MASC_CLUSTER_NAME" (Some cluster_name) @@ fun () ->
  with_eio @@ fun _env ->
  Eio_guard.enable ();
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let path = Team_session_store.events_jsonl_path config "lock-regression" in
  let active = ref 0 in
  let overlapped = ref false in
  Eio.Fiber.all
    (List.init 16 (fun _ ->
         fun () ->
           Room_utils.with_file_lock config path (fun () ->
               incr active;
               if !active > 1 then overlapped := true;
               Eio.Fiber.yield ();
               decr active)));
  Alcotest.(check bool) "memory event lock is exclusive" false !overlapped

let test_filesystem_backend_event_lock_serializes_fibers () =
  let cluster_name = "team-session-lock-" ^ Team_session_store.make_session_id () in
  with_env "MASC_STORAGE_TYPE" (Some "filesystem") @@ fun () ->
  with_env "MASC_CLUSTER_NAME" (Some cluster_name) @@ fun () ->
  with_eio @@ fun env ->
  Eio_guard.enable ();
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) @@ fun () ->
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let path = Team_session_store.events_jsonl_path config "lock-regression-fs" in
  let active = ref 0 in
  let overlapped = ref false in
  Eio.Fiber.all
    (List.init 8 (fun _ ->
         fun () ->
           Room_utils.with_file_lock_eio ~clock:(Eio.Stdenv.clock env) config path
             (fun () ->
               incr active;
               if !active > 1 then overlapped := true;
               Eio.Fiber.yield ();
               decr active)));
  Alcotest.(check bool) "filesystem event lock is exclusive" false !overlapped

let test_list_and_compare () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
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
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"turn-events-prove" |> get_session_id in

  let invalid_turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "invalid-kind");
          ])
  in
  Alcotest.(check bool) "invalid turn kind rejected" false invalid_turn_ok;
  let empty_note_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
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
      dispatch_exn ctx ~name:"masc_team_session_step"
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
  Alcotest.(check bool) "proof md exists" true
    (Room_utils.path_exists config proof_md_path);
  Alcotest.(check string) "verdict proved" "proved" verdict;
  let proof_doc = Room_utils.read_json config proof_json_path in
  let proof_schema_version =
    proof_doc |> Yojson.Safe.Util.member "schema_version"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "proof schema version" "1.0.0"
    proof_schema_version;
  cleanup_dir base_dir

(* test_step_plain_turn_matches_legacy_turn removed — handle_turn archived *)

let test_idle_session_stays_running_before_first_step () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"idle-session-before-first-step" |> get_session_id
  in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  Alcotest.(check string) "session stays running" "running"
    (session_status_of_body status_body);
  let step_ok, _step_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "broadcast");
            ("message", `String "contract turn broadcast");
          ])
  in
  Alcotest.(check bool) "first step still accepted" true step_ok;
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
  Alcotest.(check int) "team_turn events present" 1
    (events_count_of_body events_body);
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "test_cleanup");
             ("generate_report", `Bool false);
           ]));
  cleanup_dir base_dir
