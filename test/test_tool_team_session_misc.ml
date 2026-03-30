open Masc_mcp
open Test_tool_team_session_support

let test_prove_strong_requires_additional_evidence () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"prove-strong-check" |> get_session_id in
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_step"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("turn_kind", `String "note");
             ("message", `String "single-turn");
           ]));
  ignore
    (dispatch_exn ctx ~name:"masc_team_session_stop"
       ~args:
         (`Assoc
           [
             ("session_id", `String session_id);
             ("reason", `String "proof-check");
             ("generate_report", `Bool true);
           ]));
  ignore (wait_until_terminal ctx session_id);
  let prove_ok, prove_body =
    dispatch_exn ctx ~name:"masc_team_session_prove"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("proof_level", `String "strong");
          ])
  in
  Alcotest.(check bool) "prove strong call succeeds" true prove_ok;
  let verdict =
    prove_body |> parse_json_exn |> result_field |> Yojson.Safe.Util.member "proof"
    |> Yojson.Safe.Util.member "verdict" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "strong proof needs stronger evidence"
    "insufficient_evidence_strong" verdict;
  cleanup_dir base_dir

let test_dispatch_unknown () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  Alcotest.(check bool) "dispatch none" true
    (Tool_team_session.dispatch ctx ~name:"masc_team_session_unknown"
       ~args:(`Assoc [])
    = None);
  cleanup_dir base_dir

let test_unauthorized_session_access () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let owner_ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let intruder_ctx : _ Tool_team_session.context =
    { config; agent_name = "intruder"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn owner_ctx ~goal:"authz-check" |> get_session_id in

  let status_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized status denied" false status_ok;

  let report_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [ ("session_id", `String session_id); ("force_regenerate", `Bool false) ])
  in
  Alcotest.(check bool) "unauthorized report denied" false report_ok;

  let stop_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_stop"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized stop denied" false stop_ok;

  let list_ok, list_body =
    dispatch_exn intruder_ctx ~name:"masc_team_session_list"
      ~args:(`Assoc [ ("limit", `Int 10) ])
  in
  Alcotest.(check bool) "unauthorized list filtered" true list_ok;
  let listed_sessions =
    parse_json_exn list_body |> result_field |> Yojson.Safe.Util.member "sessions"
    |> Yojson.Safe.Util.to_list
  in
  Alcotest.(check int) "unauthorized list empty" 0 (List.length listed_sessions);

  let compare_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_compare"
      ~args:
        (`Assoc
          [
            ("base_session_id", `String session_id);
            ("target_session_id", `String session_id);
          ])
  in
  Alcotest.(check bool) "unauthorized compare denied" false compare_ok;

  let turn_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "intruder");
          ])
  in
  Alcotest.(check bool) "unauthorized turn denied" false turn_ok;

  let events_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_events"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized events denied" false events_ok;

  let prove_ok, _ =
    dispatch_exn intruder_ctx ~name:"masc_team_session_prove"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "unauthorized prove denied" false prove_ok;

  let owner_stop_ok, _ =
    dispatch_exn owner_ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "owner_cleanup");
            ("generate_report", `Bool false);
          ])
  in
  Alcotest.(check bool) "owner stop allowed" true owner_stop_ok;
  ignore (wait_until_terminal owner_ctx session_id);
  cleanup_dir base_dir

let test_generated_worker_alias_session_access () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let owner_ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let worker_name = "local-worker-1234" in
  let alias_name = "local-worker-1234-calm-otter" in
  let session_id =
    start_session_custom_exn owner_ctx ~goal:"generated-alias-session-access"
      ~min_agents:1 ~agents:[ worker_name ] ~operation_id:None
    |> get_session_id
  in
  let alias_ctx : _ Tool_team_session.context =
    { config; agent_name = alias_name; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let status_ok, _ =
    dispatch_exn alias_ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "generated alias can read status" true status_ok;
  let turn_ok, _ =
    dispatch_exn alias_ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("turn_kind", `String "note");
            ("message", `String "alias worker note");
          ])
  in
  Alcotest.(check bool) "generated alias can record turn" true turn_ok;
  let team_turn_actor =
    Team_session_store.read_events config session_id
    |> List.find_map (fun json ->
           match
             ( Yojson.Safe.Util.member "event_type" json,
               Yojson.Safe.Util.member "detail" json
               |> Yojson.Safe.Util.member "actor" )
           with
           | `String "team_turn", `String actor -> Some actor
           | _ -> None)
  in
  Alcotest.(check (option string)) "turn actor canonicalized to base worker"
    (Some worker_name) team_turn_actor;
  cleanup_dir base_dir

let test_final_done_delta_snapshot_stable () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"snapshot-stability" |> get_session_id in

  let task_before = add_task_id config ~title:"before-finalize" in
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"claim";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"start";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:"done";

  let stop_ok, _ =
    dispatch_exn ctx ~name:"masc_team_session_stop"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("reason", `String "snapshot_finalize");
            ("generate_report", `Bool true);
          ])
  in
  Alcotest.(check bool) "stop accepted" true stop_ok;
  ignore (wait_until_terminal ctx session_id);

  let status_ok_before, status_body_before =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status before stable check" true status_ok_before;
  let done_before = done_delta_total_of_status_body status_body_before in
  Alcotest.(check int) "done delta before finalize snapshot" 1 done_before;

  let task_after = add_task_id config ~title:"after-finalize" in
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"claim";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"start";
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:"done";

  let status_ok_after, status_body_after =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status after stable check" true status_ok_after;
  let done_after = done_delta_total_of_status_body status_body_after in
  Alcotest.(check int) "done delta should stay frozen after finalize" done_before
    done_after;

  let report_ok, report_body =
    dispatch_exn ctx ~name:"masc_team_session_report"
      ~args:
        (`Assoc
          [ ("session_id", `String session_id); ("force_regenerate", `Bool true) ])
  in
  Alcotest.(check bool) "report regenerate" true report_ok;
  let report_json = parse_json_exn report_body |> result_field in
  let report_json_path =
    report_json |> Yojson.Safe.Util.member "json_path" |> Yojson.Safe.Util.to_string
  in
  let report_doc = Room_utils.read_json config report_json_path in
  let done_in_report =
    report_doc |> Yojson.Safe.Util.member "summary"
    |> Yojson.Safe.Util.member "done_delta_total"
    |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "report uses frozen done delta" done_before done_in_report;
  cleanup_dir base_dir

let test_verify_trace_uses_worker_run_raw_trace () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"verify-trace-raw" |> get_session_id in
  let worker_run_id = "run-trace-1" in
  ignore
    (write_worker_run_raw_trace_exn config ~session_id ~worker_run_id
       ~worker_name:"llama-local-impl");
  let verify_ok, verify_body =
    dispatch_exn ctx ~name:"masc_team_session_verify_trace"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("worker_run_id", `String worker_run_id);
          ])
  in
  Alcotest.(check bool) "verify trace ok" true verify_ok;
  let result = parse_json_exn verify_body |> result_field in
  Alcotest.(check string) "trace capability" "raw"
    Yojson.Safe.Util.(result |> member "trace_capability" |> to_string);
  let verification = Yojson.Safe.Util.member "verification" result in
  Alcotest.(check bool) "verification ok" true
    Yojson.Safe.Util.(verification |> member "ok" |> to_bool);
  Alcotest.(check bool) "summary present" true
    (Yojson.Safe.Util.member "summary" verification <> `Null);
  Alcotest.(check bool) "validation present" true
    (Yojson.Safe.Util.member "validation" verification <> `Null);
  Alcotest.(check bool) "has file_write" true
    Yojson.Safe.Util.(verification |> member "has_file_write" |> to_bool);
  Alcotest.(check bool) "verification pass after file_write" true
    Yojson.Safe.Util.(
      verification |> member "verification_pass_after_file_write" |> to_bool);
  Alcotest.(check int) "paired tool result count" 3
    Yojson.Safe.Util.(verification |> member "paired_tool_result_count" |> to_int);
  Alcotest.(check (list string)) "tool names"
    [ "file_read"; "file_write"; "shell_exec" ]
    Yojson.Safe.Util.(
      verification |> member "tool_names" |> to_list |> List.map to_string);
  cleanup_dir base_dir

let test_verify_trace_reports_summary_only_without_checkpoint () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"verify-trace-summary-only" |> get_session_id in
  let worker_run_id = "run-trace-missing" in
  Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String "llama-local-impl");
      ]);
  let verify_ok, verify_body =
    dispatch_exn ctx ~name:"masc_team_session_verify_trace"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("worker_run_id", `String worker_run_id);
          ])
  in
  Alcotest.(check bool) "verify trace call still succeeds" true verify_ok;
  let result = parse_json_exn verify_body |> result_field in
  Alcotest.(check string) "trace capability" "summary_only"
    Yojson.Safe.Util.(result |> member "trace_capability" |> to_string);
  Alcotest.(check bool) "summary_only ok=false" false
    Yojson.Safe.Util.(result |> member "ok" |> to_bool);
  let error = Yojson.Safe.Util.(result |> member "error" |> to_string) in
  Alcotest.(check bool) "missing checkpoint surfaced" true
    (String.length error > 0);
  cleanup_dir base_dir

let test_verify_trace_reports_summary_only_when_direct_evidence_missing () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"verify-trace-direct-missing" |> get_session_id in
  let worker_run_id = "run-direct-missing" in
  Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    (`Assoc
      [
        ("worker_run_id", `String worker_run_id);
        ("worker_name", `String "llama-local-impl");
        ("evidence_session_id", `String "missing-direct-session");
      ]);
  let verify_ok, verify_body =
    dispatch_exn ctx ~name:"masc_team_session_verify_trace"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("worker_run_id", `String worker_run_id);
          ])
  in
  Alcotest.(check bool) "verify trace call still succeeds" true verify_ok;
  let result = parse_json_exn verify_body |> result_field in
  Alcotest.(check string) "trace capability" "summary_only"
    Yojson.Safe.Util.(result |> member "trace_capability" |> to_string);
  Alcotest.(check bool) "summary_only ok=false" false
    Yojson.Safe.Util.(result |> member "ok" |> to_bool);
  let error = Yojson.Safe.Util.(result |> member "error" |> to_string) in
  Alcotest.(check bool) "missing direct evidence surfaced" true
    (String.length error > 0);
  cleanup_dir base_dir

let test_delegate_rejects_not_ready_worker_with_guidance () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None }
  in
  let session_id = start_session_exn ctx ~goal:"delegate-not-ready" |> get_session_id in
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           planned_workers =
             [
               {
                 Team_session_types.spawn_agent = "default";
                 runtime_actor = Some "llama-local-pending";
                 spawn_role = Some "implementer";
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
                 routing_reason = Some "test-pending";
                 routing_escalated = false;
               };
             ];
           updated_at_iso = Types.now_iso ();
         }));
  Team_session_store.write_text_file
    (Team_session_store.worker_container_meta_path config session_id
       "llama-local-pending")
    "{}";
  let delegate_ok, delegate_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("wait_mode", `String "blocking");
            ("target_agent", `String "implementer");
            ("delegate_prompt", `String "continue");
          ])
  in
  Alcotest.(check bool) "delegate denied" false delegate_ok;
  let message =
    parse_json_exn delegate_body |> Yojson.Safe.Util.member "message"
    |> Yojson.Safe.Util.to_string
  in
  let normalized = String.lowercase_ascii message in
  let needle = "not ready for delegation" in
  let needle_len = String.length needle in
  let hay_len = String.length normalized in
  let rec contains idx =
    if idx + needle_len > hay_len then false
    else if String.sub normalized idx needle_len = needle then true
    else contains (idx + 1)
  in
  Alcotest.(check bool) "mentions not ready guidance" true
    (String.length message > 0 && contains 0);
  cleanup_dir base_dir
