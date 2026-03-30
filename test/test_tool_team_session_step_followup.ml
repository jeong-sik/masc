open Masc_mcp
open Test_tool_team_session_support

let test_step_spawn_batch_preserves_explicit_hierarchical_assignments () =
  with_eio @@ fun env ->
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
          proc_mgr = None; net = None;
        }
      in
      let start_ok, start_body =
        dispatch_exn ctx ~name:"masc_team_session_start"
          ~args:
            (`Assoc
              [
                ("goal", `String "preserve explicit hierarchical assignments");
                ("duration_seconds", `Int 90);
                ("checkpoint_interval_sec", `Int 10);
                ("min_agents", `Int 1);
                ("orchestration_mode", `String "assist");
                ("communication_mode", `String "hybrid");
                ("scale_profile", `String "local64");
                ("model_cascade", `List [ `String "glm:auto" ]);
                ("fallback_policy", `String "strict_local_only");
                ("instruction_profile", `String "strict");
                ("alert_channel", `String "both");
                ("report_formats", `List [ `String "markdown"; `String "json" ]);
                ("agents", `List []);
              ])
      in
      Alcotest.(check bool) "start ok" true start_ok;
      let session_id = parse_json_exn start_body |> get_session_id in
      let step_ok, _step_body =
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
                          ("spawn_role", `String "explicit-manager");
                          ("worker_class", `String "manager");
                          ("worker_size", `String "xlg");
                          ("lane_id", `String "lane-z");
                          ("control_domain", `String "quality");
                          ("supervisor_actor", `String "ctrl-custom");
                          ( "spawn_prompt",
                            `String "final architecture decision and synthesize proposal" );
                        ];
                      `Assoc
                        [
                          ("spawn_role", `String "explicit-worker");
                          ("worker_class", `String "executor");
                          ("worker_size", `String "sm");
                          ("lane_id", `String "lane-q");
                          ("control_domain", `String "execution");
                          ("supervisor_actor", `String "ctrl-worker-custom");
                          ("spawn_prompt", `String "normalize evidence into strict JSON schema");
                        ];
                    ] );
              ])
      in
      Alcotest.(check bool) "batch step fails without proc manager" false step_ok;
      let session =
        Team_session_store.load_session config session_id |> Option.get
      in
      let explicit_manager =
        List.find
          (fun worker ->
            worker.Team_session_types.spawn_role = Some "explicit-manager")
          session.planned_workers
      in
      Alcotest.(check (option string)) "manager tier follows worker size"
        (Some "35b")
        (Option.map Team_session_types.model_tier_to_string
           explicit_manager.model_tier);
      Alcotest.(check (option string)) "manager keeps explicit lane"
        (Some "lane-z") explicit_manager.lane_id;
      Alcotest.(check (option string)) "manager keeps explicit supervisor"
        (Some "ctrl-custom") explicit_manager.supervisor_actor;
      let explicit_worker =
        List.find
          (fun worker ->
            worker.Team_session_types.spawn_role = Some "explicit-worker")
          session.planned_workers
      in
      Alcotest.(check (option string)) "worker tier follows worker size"
        (Some "9b")
        (Option.map Team_session_types.model_tier_to_string
           explicit_worker.model_tier);
      Alcotest.(check (option string)) "worker keeps explicit lane"
        (Some "lane-q") explicit_worker.lane_id;
      Alcotest.(check (option string)) "worker keeps explicit supervisor"
        (Some "ctrl-worker-custom") explicit_worker.supervisor_actor)

let test_reconcile_failed_spawn_actor_detaches_without_turn () =
  with_eio @@ fun _env ->
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
  ignore (unwrap_ok (Tool_team_session.ensure_session_actor config session.session_id "local-failed"));
  let outcome =
    unwrap_ok
      (Tool_team_session.reconcile_failed_spawn_actor config session.session_id
         "local-failed")
  in
  Alcotest.(check string) "failed spawn actor detached" "detached"
    (match outcome with `Detached -> "detached" | `Retained -> "retained");
  let reloaded = Team_session_store.load_session config session.session_id |> Option.get in
  Alcotest.(check bool) "actor removed from participants" false
    (List.mem "local-failed" reloaded.agent_names);
  let detached_events =
    Team_session_store.read_events config session.session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_detached")
  in
  Alcotest.(check int) "detached event recorded" 1 (List.length detached_events);
  cleanup_dir base_dir

let test_reconcile_failed_spawn_actor_retains_after_turn () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"retain-failed-spawn-after-turn" |> get_session_id in
  ignore
    (unwrap_ok
       (Tool_team_session.ensure_session_actor config session_id
          "local-turned"));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id
          ~actor:"local-turned" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "worker left one turn before failing")
          ~target_agent:None ~task_title:None ~task_description:None
          ~task_priority:3));
  let outcome =
    unwrap_ok
      (Tool_team_session.reconcile_failed_spawn_actor config session_id
         "local-turned")
  in
  Alcotest.(check string) "actor retained after emitting a turn" "retained"
    (match outcome with `Detached -> "detached" | `Retained -> "retained");
  let reloaded = Team_session_store.load_session config session_id |> Option.get in
  Alcotest.(check bool) "actor still authorized" true
    (List.mem "local-turned" reloaded.agent_names);
  let detached_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "session_agent_detached")
  in
  Alcotest.(check int) "no detach event recorded" 0 (List.length detached_events);
  cleanup_dir base_dir

let test_proof_exposes_failed_spawn_and_detach_counts () =
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
    start_session_exn ctx ~goal:"prove failed spawn and detach visibility"
  in
  let session_id = get_session_id start_json in
  Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "tester");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "local-failed");
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
          ("actor", `String "local-failed");
          ("reason", `String "spawn_failed_without_turn");
          ("agent_count", `Int 1);
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_step"
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
  Alcotest.(check string) "proof failed runtime actor recorded" "local-failed"
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
  let proof_md = Team_session_store.read_artifact_text config proof_md_path in
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
         Str.search_forward (Str.regexp_string "local-failed | agent=llama | role=implementer-a")
           proof_md 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes detached reason" true
    (try
       let _ =
         Str.search_forward (Str.regexp_string "local-failed | reason=spawn_failed_without_turn")
           proof_md 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_report_and_proof_expose_empty_note_turn_evidence () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"empty-note-evidence" |> get_session_id in
  Team_session_store.append_event config session_id ~event_type:"team_turn"
    ~detail:
      (`Assoc
        [
          ("turn_no", `Int 1);
          ("kind", `String "note");
          ("actor", `String "local-empty");
          ("message", `Null);
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_step"
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
    "local-empty"
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
  let proof_md = Team_session_store.read_artifact_text config proof_md_path in
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
         Str.search_forward (Str.regexp_string "- local-empty") proof_md 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir
