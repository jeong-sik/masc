open Masc_mcp
open Test_tool_team_session_support

let test_step_spawn_batch_records_planned_workers () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
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
                          ("spawn_role", `String "planner");
                          ("spawn_selection_note", `String selection_note);
                          ("spawn_prompt", `String "planner prompt");
                        ];
                      `Assoc
                        [
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
                          ("spawn_role", `String "normalizer");
                          ("spawn_prompt", `String "normalize evidence into strict JSON schema");
                        ];
                      `Assoc
                        [
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
  with_eio @@ fun _env ->
  let args =
    `Assoc
      [
        ("spawn_timeout_seconds", `Int 1500);
        ( "spawn_batch",
          `List
            [
              `Assoc
                [
                  ("spawn_prompt", `String "first prompt");
                ];
              `Assoc
                [
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

let test_parse_step_spawn_specs_applies_worker_policy_fields () =
  with_eio @@ fun _env ->
  let args =
    `Assoc
      [
        ( "worker_policy",
          `Assoc
            [
              ("thinking", `Bool true);
              ("timeout_seconds", `Int 42);
              ("max_turns", `Int 7);
            ] );
        ( "spawn_batch",
          `List
            [
              `Assoc [ ("spawn_prompt", `String "planner prompt") ];
              `Assoc
                [
                  ("spawn_prompt", `String "implementer prompt");
                  ( "worker_policy",
                    `Assoc
                      [
                        ("thinking", `Bool false);
                        ("timeout_seconds", `Int 9);
                        ("max_turns", `Int 2);
                      ] );
                ];
            ] );
      ]
  in
  let specs = unwrap_ok (Tool_team_session.parse_step_spawn_specs args) in
  match specs with
  | [ first; second ] ->
      Alcotest.(check (option bool)) "top-level thinking" (Some true)
        first.thinking_enabled;
      Alcotest.(check (option int)) "top-level max_turns" (Some 7)
        first.max_turns;
      Alcotest.(check int) "top-level timeout applied" 42
        first.spawn_timeout_seconds;
      Alcotest.(check (option bool)) "item thinking override" (Some false)
        second.thinking_enabled;
      Alcotest.(check (option int)) "item max_turns override" (Some 2)
        second.max_turns;
      Alcotest.(check int) "item timeout override" 9
        second.spawn_timeout_seconds
  | _ -> Alcotest.fail "expected exactly two parsed spawn specs"

let test_status_reports_worker_run_progress_summary () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"worker-run-summary" |> get_session_id in
  let planned_worker runtime_actor spawn_role =
    {
      Team_session_types.spawn_agent = "default";
      runtime_actor = Some runtime_actor;
      spawn_role = Some spawn_role;
      spawn_model = Some "qwen3.5-35b-a3b-ud-q8-xl";
      execution_scope = Some Team_session_types.Limited_code_change;
      thinking_enabled = None;
      thinking_budget = None;
      max_turns = None;
      timeout_seconds = Some 300;
      worker_class = Some Team_session_types.Worker_executor;
      parent_actor = None;
      capsule_mode = None;
      runtime_pool = Some "local";
      lane_id = None;
      controller_level = None;
      control_domain = None;
      supervisor_actor = None;
      model_tier = Some Team_session_types.Tier_35b;
      task_profile = Some Team_session_types.Profile_normalize;
      risk_level = Some Team_session_types.Risk_low;
      routing_confidence = Some 0.9;
      routing_reason = Some "test-routing";
      routing_escalated = false;
    }
  in
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           planned_workers =
             [
               planned_worker "worker-a" "planner";
               planned_worker "worker-b" "implementer";
             ];
           updated_at_iso = Types.now_iso ();
         }));
  Team_session_store.write_artifact_text config
    (Team_session_store.worker_container_checkpoint_path config session_id
       "worker-a")
    "checkpoint";
  Team_session_store.append_event config session_id
    ~event_type:"team_step_spawn_requested"
    ~detail:(`Assoc [ ("worker_run_id", `String "run-a"); ("runtime_actor", `String "worker-a") ]);
  Team_session_store.append_event config session_id
    ~event_type:"team_step_spawn_requested"
    ~detail:(`Assoc [ ("worker_run_id", `String "run-b"); ("runtime_actor", `String "worker-b") ]);
  Team_session_store.append_event config session_id
    ~event_type:"team_step_delegate_requested"
    ~detail:(`Assoc [ ("worker_run_id", `String "run-c"); ("target_agent", `String "worker-c") ]);
  Team_session_store.append_event config session_id
    ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc [ ("worker_run_id", `String "run-a"); ("success", `Bool true) ]);
  Team_session_store.append_event config session_id
    ~event_type:"team_step_delegate"
    ~detail:
      (`Assoc [ ("worker_run_id", `String "run-c"); ("success", `Bool false) ]);
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let worker_runs =
    parse_json_exn status_body |> result_field |> Yojson.Safe.Util.member "worker_runs"
  in
  Alcotest.(check int) "requested count" 3
    Yojson.Safe.Util.(worker_runs |> member "requested_count" |> to_int);
  Alcotest.(check int) "completed success count" 1
    Yojson.Safe.Util.(worker_runs |> member "completed_success_count" |> to_int);
  Alcotest.(check int) "completed failed count" 1
    Yojson.Safe.Util.(worker_runs |> member "completed_failed_count" |> to_int);
  Alcotest.(check int) "in flight count" 1
    Yojson.Safe.Util.(worker_runs |> member "in_flight_count" |> to_int);
  Alcotest.(check (list string)) "in flight run ids" [ "run-b" ]
    Yojson.Safe.Util.(
      worker_runs |> member "in_flight_run_ids" |> to_list |> List.map to_string);
  Alcotest.(check (list string)) "in flight actors" [ "worker-b" ]
    Yojson.Safe.Util.(
      worker_runs |> member "in_flight_actor_names" |> to_list |> List.map to_string);
  Alcotest.(check (list string)) "ready worker names" [ "worker-a" ]
    Yojson.Safe.Util.(
      worker_runs |> member "ready_worker_names" |> to_list |> List.map to_string);
  Alcotest.(check (list string)) "pending worker names" [ "worker-b" ]
    Yojson.Safe.Util.(
      worker_runs |> member "pending_worker_names" |> to_list |> List.map to_string);
  cleanup_dir base_dir

let test_step_spawn_batch_infers_exact_env_model_tiers () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Local_runtime_pool.reset ();
      cleanup_dir base_dir)
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
      with_env "MASC_TEAM_SESSION_MODEL_35B" (Some "lead-model-exact") @@ fun () ->
      with_env "MASC_TEAM_SESSION_MODEL_27B" (Some "middle-model-exact") @@ fun () ->
      with_env "MASC_TEAM_SESSION_MODEL_9B" (Some "worker-model-exact") @@ fun () ->
      with_env "MASC_TEAM_SESSION_ROUTER_JUDGE" (Some "false") @@ fun () ->
      Local_runtime_pool.reset ();
      let session_id =
        start_session_exn ctx ~goal:"infer exact env model tiers"
        |> get_session_id
      in
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
                          ("spawn_role", `String "exact-lead");
                          ("worker_size", `String "xlg");
                          ( "spawn_prompt",
                            `String
                              "final architecture decision and synthesize the proposal" );
                        ];
                      `Assoc
                        [
                          ("spawn_role", `String "exact-middle");
                          ("worker_size", `String "lg");
                          ( "spawn_prompt",
                            `String
                              "verify the retrieved evidence and highlight contradictions" );
                        ];
                    ] );
              ])
      in
      Alcotest.(check bool) "batch step fails without proc manager" false step_ok;
      let session =
        Team_session_store.load_session config session_id |> Option.get
      in
      let exact_lead =
        List.find
          (fun worker -> worker.Team_session_types.spawn_role = Some "exact-lead")
          session.planned_workers
      in
      Alcotest.(check (option string)) "exact lead model kept"
        (Some "lead-model-exact") exact_lead.spawn_model;
      Alcotest.(check (option string)) "exact lead tier inferred as 35b"
        (Some "35b")
        (Option.map Team_session_types.model_tier_to_string exact_lead.model_tier);
      let exact_middle =
        List.find
          (fun worker -> worker.Team_session_types.spawn_role = Some "exact-middle")
          session.planned_workers
      in
      Alcotest.(check (option string)) "exact middle model kept"
        (Some "middle-model-exact") exact_middle.spawn_model;
      Alcotest.(check (option string)) "exact middle tier inferred as 27b"
        (Some "27b")
        (Option.map Team_session_types.model_tier_to_string
           exact_middle.model_tier))
