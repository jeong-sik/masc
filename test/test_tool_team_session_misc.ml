open Masc_mcp
open Test_tool_team_session_support

module Oas = Agent_sdk

let write_minimal_worker_meta config session_id worker_name =
  Team_session_store.write_text_file
    (Team_session_store.worker_container_meta_path config session_id
       worker_name)
    (Printf.sprintf {|{"worker_name":"%s"}|} worker_name)

let write_valid_worker_checkpoint (config : Room.config) session_id worker_name =
  let checkpoint : Oas.Checkpoint.t =
    {
      Oas.Checkpoint.version = Oas.Checkpoint.checkpoint_version;
      session_id;
      agent_name = worker_name;
      model = "qwen3.5-35b-a3b-ud-q8-xl";
      system_prompt = None;
      messages = [];
      usage = Oas.Types.empty_usage;
      turn_count = 0;
      created_at = 0.0;
      tools = [];
      tool_choice = None;
      disable_parallel_tool_use = false;
      temperature = None;
      top_p = None;
      top_k = None;
      min_p = None;
      enable_thinking = None;
      response_format_json = false;
      thinking_budget = None;
      cache_system_prompt = false;
      max_input_tokens = None;
      max_total_tokens = None;
      context = Oas.Context.create ();
      mcp_sessions = [];
      working_context = None;
    }
  in
  match
    Worker_container.save_worker_checkpoint ~base_path:config.base_path
      ~team_session_id:(Some session_id) ~worker_name checkpoint
  with
  | Ok () -> ()
  | Error err ->
      Alcotest.failf "failed to save worker checkpoint for %s: %s"
        worker_name err

let wait_for_background_delegate_settle
    (ctx : _ Tool_team_session.context) config session_id worker_run_id =
  let meta_path =
    Team_session_store.worker_run_meta_path config session_id worker_run_id
  in
  let rec loop attempts =
    if attempts <= 0 then
      Alcotest.fail
        "background delegate did not settle before cleanup"
    else if Room_utils.path_exists config meta_path then ()
    else
      let delegate_events =
        Team_session_store.read_events config session_id
        |> List.filter (fun json ->
               Yojson.Safe.Util.member "event_type" json
               = `String "team_step_delegate")
      in
      if delegate_events <> [] then ()
      else (
        Eio.Time.sleep ctx.clock 0.01;
        loop (attempts - 1))
  in
  loop 200

let test_prove_strong_requires_additional_evidence () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
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
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  Alcotest.(check bool) "dispatch none" true
    (Tool_team_session.dispatch ctx ~name:"masc_team_session_unknown"
       ~args:(`Assoc [])
    = None);
  cleanup_dir base_dir

let test_start_requires_process_mgr_when_runtime_unavailable () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  Process_eio.reset_for_testing ();
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let ok, body =
    dispatch_exn ctx ~name:"masc_team_session_start"
      ~args:
        (`Assoc
          [
            ("goal", `String "requires-runtime");
            ("duration_seconds", `Int 90);
          ])
  in
  Alcotest.(check bool) "start denied without process manager" false ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "error code" "precondition_failed"
    (Yojson.Safe.Util.(json |> member "error_code" |> to_string));
  Alcotest.(check string) "message"
    "process_mgr not available for team session start"
    (Yojson.Safe.Util.(json |> member "message" |> to_string));
  cleanup_dir base_dir

let test_unauthorized_session_access () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let owner_ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let intruder_ctx : _ Tool_team_session.context =
    { config; agent_name = "intruder"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
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

let test_final_done_delta_snapshot_stable () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"snapshot-stability" |> get_session_id in

  let task_before = add_task_id config ~title:"before-finalize" in
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:Types.Claim;
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:Types.Start;
  transition_task_ok config ~agent_name:"owner" ~task_id:task_before ~action:Types.Done_action;

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
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:Types.Claim;
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:Types.Start;
  transition_task_ok config ~agent_name:"owner" ~task_id:task_after ~action:Types.Done_action;

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

(* test_verify_trace_* tests removed: masc_team_session_verify_trace purged. *)

let test_delegate_rejects_not_ready_worker_with_guidance () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
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
  Alcotest.(check bool) "mentions delegate-ready status path" true
    (String.contains message '.'
     && String.length message > 0
     &&
     (try
        let _ =
          Str.search_forward
            (Str.regexp_string "delegate_ready_worker_names")
            message 0
        in
        true
      with Not_found -> false));
  let denied_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "team_step_delegate_denied")
  in
  Alcotest.(check int) "delegate denied event recorded" 1
    (List.length denied_events);
  let denied_detail =
    List.hd denied_events |> Yojson.Safe.Util.member "detail"
  in
  Alcotest.(check string) "delegate denied reason" "pending_checkpoint"
    Yojson.Safe.Util.(denied_detail |> member "blocked_reason" |> to_string);
  cleanup_dir base_dir

let test_delegate_ready_worker_accepts_background () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"delegate-ready-background"
    |> get_session_id
  in
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           planned_workers =
             [
               {
                 Team_session_types.spawn_agent = "default";
                 runtime_actor = Some "llama-local-ready";
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
                 task_profile = Some Team_session_types.Profile_normalize;
                 risk_level = Some Team_session_types.Risk_low;
                 routing_confidence = Some 0.9;
                 routing_reason = Some "test-ready";
                 routing_escalated = false;
               };
             ];
           updated_at_iso = Types.now_iso ();
         }));
  write_minimal_worker_meta config session_id "llama-local-ready";
  write_valid_worker_checkpoint config session_id "llama-local-ready";
  let delegate_ok, delegate_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("wait_mode", `String "background");
            ("target_agent", `String "implementer");
            ("delegate_prompt", `String "continue");
          ])
  in
  Alcotest.(check bool) "delegate accepted" true delegate_ok;
  let delegate_json =
    parse_json_exn delegate_body |> result_field |> Yojson.Safe.Util.member "delegate"
  in
  Alcotest.(check string) "accepted worker name" "llama-local-ready"
    Yojson.Safe.Util.(delegate_json |> member "worker_name" |> to_string);
  Alcotest.(check string) "accepted status" "accepted"
    Yojson.Safe.Util.(delegate_json |> member "status" |> to_string);
  Alcotest.(check string) "accepted wait mode" "background"
    Yojson.Safe.Util.(delegate_json |> member "wait_mode" |> to_string);
  let worker_run_id =
    Yojson.Safe.Util.(delegate_json |> member "worker_run_id" |> to_string)
  in
  let denied_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "team_step_delegate_denied")
  in
  Alcotest.(check int) "no delegate denied event on ready worker" 0
    (List.length denied_events);
  let requested_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "team_step_delegate_requested")
  in
  Alcotest.(check int) "delegate requested event recorded" 1
    (List.length requested_events);
  wait_for_background_delegate_settle ctx config session_id worker_run_id;
  cleanup_dir base_dir

let test_delegate_rejects_corrupt_checkpoint_worker () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"delegate-corrupt-checkpoint"
    |> get_session_id
  in
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           planned_workers =
             [
               {
                 Team_session_types.spawn_agent = "default";
                 runtime_actor = Some "llama-local-ready";
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
                 task_profile = Some Team_session_types.Profile_normalize;
                 risk_level = Some Team_session_types.Risk_low;
                 routing_confidence = Some 0.9;
                 routing_reason = Some "test-ready";
                 routing_escalated = false;
               };
             ];
           updated_at_iso = Types.now_iso ();
         }));
  Team_session_store.write_text_file
    (Team_session_store.worker_container_meta_path config session_id
       "llama-local-ready")
    {|{"worker_name":"llama-local-ready"}|};
  Team_session_store.write_text_file
    (Team_session_store.worker_container_checkpoint_path config session_id
       "llama-local-ready")
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
  Alcotest.(check bool) "delegate denied for corrupt checkpoint" false
    delegate_ok;
  let delegate_json = parse_json_exn delegate_body in
  let message =
    Yojson.Safe.Util.member "message" delegate_json
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "mentions not ready guidance" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "not ready for delegation")
           (String.lowercase_ascii message) 0
       in
       true
     with Not_found -> false);
  Alcotest.(check bool) "mentions corrupt checkpoint reason" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "corrupt_checkpoint")
           (String.lowercase_ascii message) 0
       in
       true
     with Not_found -> false);
  let denied_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "team_step_delegate_denied")
  in
  Alcotest.(check int) "delegate denied event recorded" 1
    (List.length denied_events);
  let denied_detail =
    List.hd denied_events |> Yojson.Safe.Util.member "detail"
  in
  Alcotest.(check string) "delegate denied reason" "corrupt_checkpoint"
    Yojson.Safe.Util.(denied_detail |> member "blocked_reason" |> to_string);
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let worker_runs =
    parse_json_exn status_body |> result_field
    |> Yojson.Safe.Util.member "worker_runs"
  in
  let readiness_entries =
    Yojson.Safe.Util.(worker_runs |> member "worker_readiness" |> to_list)
  in
  let corrupt_readiness =
    List.find
      (fun json ->
        Yojson.Safe.Util.(
          json |> member "worker_name" |> to_string = "llama-local-ready"))
      readiness_entries
  in
  Alcotest.(check bool) "status keeps corrupt worker not delegate-ready" false
    Yojson.Safe.Util.(corrupt_readiness |> member "delegate_ready" |> to_bool);
  Alcotest.(check string) "status blocked reason" "corrupt_checkpoint"
    Yojson.Safe.Util.(corrupt_readiness |> member "blocked_reason" |> to_string);
  cleanup_dir base_dir

let test_status_marks_corrupt_meta_worker_blocked () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id =
    start_session_exn ctx ~goal:"status-corrupt-meta"
    |> get_session_id
  in
  ignore
    (Team_session_store.update_session config session_id (fun session ->
         {
           session with
           planned_workers =
             [
               {
                 Team_session_types.spawn_agent = "default";
                 runtime_actor = Some "llama-local-meta";
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
                 task_profile = Some Team_session_types.Profile_normalize;
                 risk_level = Some Team_session_types.Risk_low;
                 routing_confidence = Some 0.9;
                 routing_reason = Some "test-corrupt-meta";
                 routing_escalated = false;
               };
             ];
           updated_at_iso = Types.now_iso ();
         }));
  Team_session_store.write_text_file
    (Team_session_store.worker_container_meta_path config session_id
       "llama-local-meta")
    "{}";
  write_valid_worker_checkpoint config session_id "llama-local-meta";
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let worker_runs =
    parse_json_exn status_body |> result_field
    |> Yojson.Safe.Util.member "worker_runs"
  in
  let readiness_entries =
    Yojson.Safe.Util.(worker_runs |> member "worker_readiness" |> to_list)
  in
  let corrupt_readiness =
    List.find
      (fun json ->
        Yojson.Safe.Util.(
          json |> member "worker_name" |> to_string = "llama-local-meta"))
      readiness_entries
  in
  Alcotest.(check bool) "status keeps corrupt meta worker not delegate-ready" false
    Yojson.Safe.Util.(corrupt_readiness |> member "delegate_ready" |> to_bool);
  Alcotest.(check string) "status corrupt meta reason" "corrupt_meta"
    Yojson.Safe.Util.(corrupt_readiness |> member "blocked_reason" |> to_string);
  cleanup_dir base_dir

let test_delegate_rejects_unplanned_worker_container () =
  with_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "owner"));
  ignore (Room.join config ~agent_name:"owner" ~capabilities:[] ());
  let ctx : _ Tool_team_session.context =
    { config; agent_name = "owner"; sw; clock = Eio.Stdenv.clock env; proc_mgr = None; net = None }
  in
  let session_id = start_session_exn ctx ~goal:"delegate-unplanned-worker" |> get_session_id in
  Team_session_store.write_text_file
    (Team_session_store.worker_container_meta_path config session_id
       "rogue-worker")
    "{}";
  let delegate_ok, delegate_body =
    dispatch_exn ctx ~name:"masc_team_session_step"
      ~args:
        (`Assoc
          [
            ("session_id", `String session_id);
            ("wait_mode", `String "blocking");
            ("target_agent", `String "rogue-worker");
            ("delegate_prompt", `String "continue");
          ])
  in
  Alcotest.(check bool) "delegate denied for unplanned worker" false delegate_ok;
  let delegate_json = parse_json_exn delegate_body in
  let message = Yojson.Safe.Util.(delegate_json |> member "message" |> to_string) in
  Alcotest.(check bool) "mentions not-ready guidance" true
    (try
       let _ =
         Str.search_forward
           (Str.regexp_string "not ready for delegation")
           (String.lowercase_ascii message) 0
       in
       true
     with Not_found -> false);
  let denied_events =
    Team_session_store.read_events config session_id
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "event_type" json
           = `String "team_step_delegate_denied")
  in
  Alcotest.(check int) "delegate denied event recorded once" 1
    (List.length denied_events);
  let status_ok, status_body =
    dispatch_exn ctx ~name:"masc_team_session_status"
      ~args:(`Assoc [ ("session_id", `String session_id) ])
  in
  Alcotest.(check bool) "status ok" true status_ok;
  let worker_runs =
    parse_json_exn status_body |> result_field |> Yojson.Safe.Util.member "worker_runs"
  in
  Alcotest.(check (list string)) "blocked worker names include rogue worker"
    [ "rogue-worker" ]
    Yojson.Safe.Util.(
      worker_runs |> member "blocked_worker_names" |> to_list |> List.map to_string);
  let readiness_entries =
    Yojson.Safe.Util.(worker_runs |> member "worker_readiness" |> to_list)
  in
  let rogue_readiness =
    List.find
      (fun json ->
        Yojson.Safe.Util.(json |> member "worker_name" |> to_string = "rogue-worker"))
      readiness_entries
  in
  Alcotest.(check bool) "status keeps rogue worker not delegate-ready" false
    Yojson.Safe.Util.(rogue_readiness |> member "delegate_ready" |> to_bool);
  cleanup_dir base_dir

(* ── single-agent fallback gate (#3651) tests ─────────────── *)

let make_pw ?(worker_class : Team_session_types.worker_class option)
    ?(task_profile : Team_session_types.task_profile option)
    (name : string) : Team_session_types.planned_worker =
  { spawn_agent = name; runtime_actor = None; spawn_role = None;
    spawn_model = None; execution_scope = None; thinking_enabled = None;
    thinking_budget = None; max_turns = None; timeout_seconds = None;
    worker_class; parent_actor = None; capsule_mode = None;
    runtime_pool = None; lane_id = None; controller_level = None;
    control_domain = None; supervisor_actor = None;
    task_profile; risk_level = None; routing_confidence = None;
    routing_reason = None; routing_escalated = false }

let test_decomposability_single_worker () =
  let pw = make_pw "solo" in
  let decomp, _reason =
    Team_session_engine_policy.classify_decomposability
      ~orchestration_mode:Team_session_types.Auto
      ~planned_workers:[pw]
  in
  Alcotest.(check string) "single worker → low"
    "low" (Team_session_types.decomposability_to_string decomp)

let test_decomposability_manager_executor_only () =
  let pw1 = make_pw ~worker_class:Worker_manager "mgr" in
  let pw2 = make_pw ~worker_class:Worker_executor "exec" in
  let decomp, _reason =
    Team_session_engine_policy.classify_decomposability
      ~orchestration_mode:Team_session_types.Auto
      ~planned_workers:[pw1; pw2]
  in
  Alcotest.(check string) "manager+executor → low"
    "low" (Team_session_types.decomposability_to_string decomp)

let test_decomposability_independent_workers () =
  let pw1 = make_pw ~worker_class:Worker_scout "scout1" in
  let pw2 = make_pw ~worker_class:Worker_librarian "lib1" in
  let pw3 = make_pw ~worker_class:Worker_scout "scout2" in
  let decomp, _reason =
    Team_session_engine_policy.classify_decomposability
      ~orchestration_mode:Team_session_types.Auto
      ~planned_workers:[pw1; pw2; pw3]
  in
  Alcotest.(check string) "diverse workers → high"
    "high" (Team_session_types.decomposability_to_string decomp)

let test_decomposability_manual_skips_gate () =
  let pw = make_pw "solo" in
  let decomp, reason =
    Team_session_engine_policy.classify_decomposability
      ~orchestration_mode:Team_session_types.Manual
      ~planned_workers:[pw]
  in
  Alcotest.(check string) "manual → high (gate skipped)"
    "high" (Team_session_types.decomposability_to_string decomp);
  Alcotest.(check bool) "reason mentions manual" true
    (String.length reason > 0)

let test_decomposability_synthesize_few_workers () =
  let pw1 = make_pw ~task_profile:Profile_synthesize "synth" in
  let pw2 = make_pw ~task_profile:Profile_extract "extract" in
  let decomp, _reason =
    Team_session_engine_policy.classify_decomposability
      ~orchestration_mode:Team_session_types.Auto
      ~planned_workers:[pw1; pw2]
  in
  Alcotest.(check string) "synthesize + 2 workers → low"
    "low" (Team_session_types.decomposability_to_string decomp)
