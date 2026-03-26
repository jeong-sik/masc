open Masc_mcp
open Test_tool_team_session_support

let test_proof_exposes_spawn_selection_rationale () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let start_json =
    start_session_exn ctx ~goal:"prove selection rationale visibility"
  in
  let session_id = get_session_id start_json in
  let spawn_model = "qwen3.5-35b-a3b-ud-q8-xl" in
  let selection_note =
    "[model-selection] leader selected qwen3.5-35b-a3b-ud-q8-xl from inventory"
  in
  Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "tester");
          ("spawn_agent", `String "llama");
          ("runtime_actor", `String "llama-local-proof");
          ("spawn_role", `String "planner");
          ("spawn_model", `String spawn_model);
          ("spawn_selection_note", `String selection_note);
          ("success", `Bool true);
          ("exit_code", `Int 0);
          ("elapsed_ms", `Int 10);
          ("output_preview", `String "worker turn recorded");
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (Team_session_store.update_session config session_id (fun s ->
         {
           s with
           planned_workers =
             Team_session_types.dedup_planned_workers
               [
                 {
                   Team_session_types.spawn_agent = "llama";
                   runtime_actor = Some "llama-local-proof";
                   spawn_role = Some "planner";
                   spawn_model = Some spawn_model;
                   execution_scope = Some Team_session_types.Observe_only;
                   worker_class = None;
                   parent_actor = None;
                   capsule_mode = None;
                   runtime_pool = None;
                   lane_id = None;
                   controller_level = None;
                   control_domain = None;
                   supervisor_actor = None;
                   model_tier = Some Team_session_types.Tier_35b;
                   task_profile = Some Team_session_types.Profile_decide;
                   risk_level = Some Team_session_types.Risk_high;
                   routing_confidence = Some 0.97;
                   routing_reason = Some "explicit:lead";
                   thinking_enabled = None;
                   thinking_budget = None;
                   max_turns = None;
                   timeout_seconds = None;
                   routing_escalated = false;
                 };
               ];
           updated_at_iso = Types.now_iso ();
         }));
  let turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "tester turn for proof");
          ])
  in
  Alcotest.(check bool) "turn recorded" true turn_ok;
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "selection_note_done");
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
  let proof_doc =
    prove_result |> Yojson.Safe.Util.member "proof"
  in
  let evidence =
    proof_doc |> Yojson.Safe.Util.member "evidence"
  in
  let recorded_note =
    evidence |> Yojson.Safe.Util.member "spawn_selection_note_summary"
    |> Yojson.Safe.Util.to_string
  in
  let planned_worker_count =
    evidence |> Yojson.Safe.Util.member "planned_worker_count"
    |> Yojson.Safe.Util.to_int
  in
  let runtime_actor_count =
    evidence |> Yojson.Safe.Util.member "unique_spawn_runtime_actors_count"
    |> Yojson.Safe.Util.to_int
  in
  let tier_35b_count =
    evidence |> Yojson.Safe.Util.member "tier_counts" |> Yojson.Safe.Util.member "35b"
    |> Yojson.Safe.Util.to_int
  in
  let decide_count =
    evidence |> Yojson.Safe.Util.member "task_profile_counts"
    |> Yojson.Safe.Util.member "decide" |> Yojson.Safe.Util.to_int
  in
  let recorded_models =
    evidence |> Yojson.Safe.Util.member "spawn_models"
    |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "selection note summary" selection_note recorded_note;
  Alcotest.(check int) "planned worker count" 1 planned_worker_count;
  Alcotest.(check int) "runtime actor count" 1 runtime_actor_count;
  Alcotest.(check int) "proof tier count" 1 tier_35b_count;
  Alcotest.(check int) "proof decide count" 1 decide_count;
  Alcotest.(check bool) "spawn model included" true
    (List.mem spawn_model recorded_models);
  let proof_md_path =
    prove_result |> Yojson.Safe.Util.member "proof_md_path"
    |> Yojson.Safe.Util.to_string
  in
  let proof_md = Team_session_store.read_artifact_text config proof_md_path in
  Alcotest.(check bool) "markdown includes model" true
    (try
       let _ = Str.search_forward (Str.regexp_string spawn_model) proof_md 0 in
       true
     with Not_found -> false);
  Alcotest.(check bool) "markdown includes rationale" true
    (try
       let _ = Str.search_forward (Str.regexp_string selection_note) proof_md 0 in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_report_and_proof_expose_spawn_tool_usage () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let start_json =
    start_session_exn ctx ~goal:"prove spawn tool evidence visibility"
  in
  let session_id = get_session_id start_json in
  Team_session_store.append_event config session_id ~event_type:"team_step_spawn"
    ~detail:
      (`Assoc
        [
          ("actor", `String "tester");
          ("runtime_actor", `String "llama-local-coder");
          ("spawn_role", `String "implementer");
          ("execution_scope", `String "limited_code_change");
          ("worker_class", `String "executor");
          ("worker_size", `String "lg");
          ("worker_backend", `String "local");
          ("tool_call_count", `Int 3);
          ("tool_names", `List [ `String "file_read"; `String "file_write"; `String "shell_exec" ]);
          ("success", `Bool true);
          ("exit_code", `Int 0);
          ("elapsed_ms", `Int 1200);
          ("output_preview", `String "updated calc.py and reran tests");
          ("ts_iso", `String (Types.now_iso ()));
        ]);
  ignore
    (Team_session_store.update_session config session_id (fun s ->
         {
           s with
           planned_workers =
             Team_session_types.dedup_planned_workers
               [
                 {
                   Team_session_types.spawn_agent = "default";
                   runtime_actor = Some "llama-local-coder";
                   spawn_role = Some "implementer";
                   spawn_model = Some "qwen3.5-35b-a3b-ud-q8-xl";
                   execution_scope = Some Team_session_types.Limited_code_change;
                   worker_class = Some Team_session_types.Worker_executor;
                   parent_actor = Some "tester";
                   capsule_mode = None;
                   runtime_pool = None;
                   lane_id = None;
                   controller_level = None;
                   control_domain = Some Team_session_types.Domain_execution;
                   supervisor_actor = Some "tester";
                   model_tier = Some Team_session_types.Tier_35b;
                   task_profile = Some Team_session_types.Profile_extract;
                   risk_level = Some Team_session_types.Risk_medium;
                   routing_confidence = Some 0.9;
                   routing_reason = Some "coding quick win";
                   thinking_enabled = None;
                   thinking_budget = None;
                   max_turns = None;
                   timeout_seconds = None;
                   routing_escalated = false;
                 };
               ];
           updated_at_iso = Types.now_iso ();
         }));
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "tool-evidence-done");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let report_ok, report_body =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:(`Assoc [ ("session_id", `String session_id); ("force_regenerate", `Bool true) ])
  in
  Alcotest.(check bool) "report ok" true report_ok;
  let report_result = parse_json_exn report_body |> result_field in
  let report_json_path =
    report_result |> Yojson.Safe.Util.member "json_path" |> Yojson.Safe.Util.to_string
  in
  let report_json = Room_utils.read_json config report_json_path in
  let report_evidence = report_json |> Yojson.Safe.Util.member "evidence" in
  Alcotest.(check int) "report spawn tool call count" 3
    Yojson.Safe.Util.(report_evidence |> member "spawn_tool_call_count" |> to_int);
  Alcotest.(check int) "report write-capable spawn count" 1
    Yojson.Safe.Util.(report_evidence |> member "write_capable_spawn_count" |> to_int);
  let report_tool_names =
    Yojson.Safe.Util.(report_evidence |> member "spawn_tool_names" |> to_list |> List.map to_string)
  in
  Alcotest.(check bool) "report contains file_write" true
    (List.mem "file_write" report_tool_names);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:(`Assoc [ ("session_id", `String session_id); ("generate_report_if_missing", `Bool true) ])
  in
  Alcotest.(check bool) "prove ok" true prove_ok;
  let prove_result = parse_json_exn prove_body |> result_field in
  let evidence = prove_result |> Yojson.Safe.Util.member "proof" |> Yojson.Safe.Util.member "evidence" in
  Alcotest.(check int) "proof spawn tool call count" 3
    Yojson.Safe.Util.(evidence |> member "spawn_tool_call_count" |> to_int);
  Alcotest.(check int) "proof write-capable spawn count" 1
    Yojson.Safe.Util.(evidence |> member "write_capable_spawn_count" |> to_int);
  let proof_tool_names =
    Yojson.Safe.Util.(evidence |> member "spawn_tool_names" |> to_list |> List.map to_string)
  in
  Alcotest.(check bool) "proof contains shell_exec" true
    (List.mem "shell_exec" proof_tool_names);
  cleanup_dir base_dir

let test_bootstrap_grace_suppresses_min_agents_violation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"bootstrap-grace"
      ~created_by:"owner" ~agent_names:[ "owner" ] ~min_agents:4
      ~checkpoint_interval_sec:10 ~started_at:(now -. 5.0)
      ~planned_end_at:(now +. 120.0)
      ~fallback_policy:Team_session_types.Fallback_task_only ~model_cascade:[]
  in
  let updated = Team_session_engine_eio.apply_runtime_policy ~config session in
  Alcotest.(check int) "violation streak suppressed" 0
    updated.min_agents_violation_streak;
  Alcotest.(check int) "fallback suppressed" 0 updated.fallback_task_created;
  let events = Team_session_store.read_events config session.session_id in
  let violation_events =
    List.filter
      (fun json ->
        Yojson.Safe.Util.member "event_type" json = `String "min_agents_violation")
      events
  in
  Alcotest.(check int) "no violation events during bootstrap" 0
    (List.length violation_events);
  cleanup_dir base_dir

let test_min_agents_violation_after_bootstrap_grace () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"post-bootstrap-violation"
      ~created_by:"owner" ~agent_names:[ "owner" ] ~min_agents:4
      ~checkpoint_interval_sec:10 ~started_at:(now -. 120.0)
      ~planned_end_at:(now +. 120.0)
      ~fallback_policy:Team_session_types.Fallback_task_only ~model_cascade:[]
  in
  let session = { session with min_agents_violation_streak = 1 } in
  let updated = Team_session_engine_eio.apply_runtime_policy ~config session in
  Alcotest.(check int) "violation streak increments after grace" 2
    updated.min_agents_violation_streak;
  Alcotest.(check int) "fallback not emitted on non-alert tick" 0
    updated.fallback_task_created;
  let events = Team_session_store.read_events config session.session_id in
  let violation_events =
    List.filter
      (fun json ->
        Yojson.Safe.Util.member "event_type" json = `String "min_agents_violation")
      events
  in
  Alcotest.(check int) "violation event recorded after grace" 1
    (List.length violation_events);
  cleanup_dir base_dir

let test_report_uses_participant_and_turn_metrics () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  let now = Time_compat.now () in
  let session =
    make_manual_session config ~goal:"report-participants-turns"
      ~created_by:"owner" ~agent_names:[ "owner"; "ally1"; "ally2" ]
      ~min_agents:3 ~checkpoint_interval_sec:10 ~started_at:(now -. 30.0)
      ~planned_end_at:(now +. 90.0)
      ~fallback_policy:Team_session_types.Fallback_none
      ~model_cascade:[ "llama:qwen3.5-35b-a3b-ud-q8-xl" ]
  in
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"owner" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "owner turn") ~target_agent:None ~task_title:None
          ~task_description:None ~task_priority:3));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"ally1" ~turn_kind:Team_session_types.Turn_note
          ~message:(Some "ally1 turn") ~target_agent:None ~task_title:None
          ~task_description:None ~task_priority:3));
  ignore
    (unwrap_ok
       (Team_session_engine_eio.record_turn ~config ~session_id:session.session_id
          ~actor:"ally2" ~turn_kind:Team_session_types.Turn_task ~message:None
          ~target_agent:None ~task_title:(Some "task from ally2")
          ~task_description:(Some "noop task") ~task_priority:2));
  let reloaded =
    Team_session_store.load_session config session.session_id
    |> Option.get
  in
  let report_json, markdown =
    unwrap_ok (Team_session_report.generate config reloaded)
  in
  let active_agents_count =
    report_json |> Yojson.Safe.Util.member "team_health"
    |> Yojson.Safe.Util.member "active_agents_count"
    |> Yojson.Safe.Util.to_int
  in
  let room_active_agents =
    report_json |> Yojson.Safe.Util.member "summary"
    |> Yojson.Safe.Util.member "room_active_agents"
    |> Yojson.Safe.Util.to_list
  in
  let turn_metrics =
    report_json |> Yojson.Safe.Util.member "agent_turn_metrics"
    |> Team_session_types.assoc_int_of_json
  in
  Alcotest.(check int) "participant count drives team health" 3 active_agents_count;
  Alcotest.(check bool) "participant count exceeds room active count" true
    (active_agents_count > List.length room_active_agents);
  Alcotest.(check int) "owner turn metric" 1
    (List.assoc "owner" turn_metrics);
  Alcotest.(check int) "ally1 turn metric" 1
    (List.assoc "ally1" turn_metrics);
  Alcotest.(check int) "ally2 turn metric" 1
    (List.assoc "ally2" turn_metrics);
  Alcotest.(check bool) "markdown shows turn-based contribution" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "- ally2: turns=1, done_delta=0")
           markdown 0
       in
       true
     with Not_found -> false);
  cleanup_dir base_dir

let test_prove_requires_multi_actor_turn_coverage () =
  with_eio @@ fun env ->
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
      ~min_agents:3 ~agents:participants ~operation_id:None
    |> get_session_id
  in
  let single_turn_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_step"
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
      ~agents:participants ~operation_id:None
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
