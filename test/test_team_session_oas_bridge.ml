(** Test_team_session_oas_bridge — Unit tests for Phase C-1 bridge module.

    LLM 0 — all tests use mock closures, no real model calls.
    Verifies lossy projection correctness and closure wiring.

    @since 2.124.0 *)

open Masc_mcp

module Swarm = Agent_sdk_swarm

(* ================================================================ *)
(* Role mapping tests                                               *)
(* ================================================================ *)

let show_role = Swarm.Swarm_types.show_agent_role

let test_role_of_worker_class_executor () =
  let r = Team_session_oas_bridge.role_of_worker_class
    (Some Team_session_types.Worker_executor) in
  Alcotest.(check string) "executor" "Swarm_types.Execute" (show_role r)

let test_role_of_worker_class_scout () =
  let r = Team_session_oas_bridge.role_of_worker_class
    (Some Team_session_types.Worker_scout) in
  Alcotest.(check string) "scout -> discover" "Swarm_types.Discover" (show_role r)

let test_role_of_worker_class_none () =
  let r = Team_session_oas_bridge.role_of_worker_class None in
  Alcotest.(check string) "none -> execute" "Swarm_types.Execute" (show_role r)

let test_role_of_spawn_role_verify () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:None (Some "verify") in
  Alcotest.(check string) "verify string" "Swarm_types.Verify" (show_role r)

let test_role_of_spawn_role_custom () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:None (Some "code_reviewer") in
  Alcotest.(check string) "custom role"
    "(Swarm_types.Custom_role \"code_reviewer\")" (show_role r)

let test_role_of_spawn_role_none_with_worker_class () =
  let r = Team_session_oas_bridge.role_of_spawn_role
    ~worker_class:(Some Team_session_types.Worker_librarian) None in
  Alcotest.(check string) "fallback to worker_class"
    "Swarm_types.Summarize" (show_role r)

(* ================================================================ *)
(* Orchestration mode tests                                         *)
(* ================================================================ *)

let show_mode = Swarm.Swarm_types.show_orchestration_mode

let test_mode_manual () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Manual in
  Alcotest.(check string) "manual -> supervisor"
    "Swarm_types.Supervisor" (show_mode m)

let test_mode_auto () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Auto in
  Alcotest.(check string) "auto -> decentralized"
    "Swarm_types.Decentralized" (show_mode m)

let test_mode_assist () =
  let m = Team_session_oas_bridge.mode_of_orchestration
    Team_session_types.Assist in
  Alcotest.(check string) "assist -> supervisor"
    "Swarm_types.Supervisor" (show_mode m)

(* ================================================================ *)
(* Cascade resolution tests                                         *)
(* ================================================================ *)

let make_pw ?(spawn_model = None) () : Team_session_types.planned_worker =
  { spawn_agent = "test-agent";
    runtime_actor = None;
    spawn_role = Some "execute";
    spawn_model;
    execution_scope = None;
    thinking_enabled = None;
    thinking_budget = None;
    max_turns = None;
    timeout_seconds = None;
    worker_class = None;
    parent_actor = None;
    capsule_mode = None;
    runtime_pool = None;
    lane_id = None;
    controller_level = None;
    control_domain = None;
    supervisor_actor = None;
    model_tier = None;
    task_profile = None;
    risk_level = None;
    routing_confidence = None;
    routing_reason = None;
    routing_escalated = false;
  }

let test_cascade_explicit_model () =
  let pw = make_pw ~spawn_model:(Some "glm:glm-4.5") () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["llama:qwen3.5"] pw in
  Alcotest.(check string) "explicit model wins" "glm:glm-4.5" c

let test_cascade_session_fallback () =
  let pw = make_pw () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["claude:opus"; "llama:qwen3.5"] pw in
  Alcotest.(check string) "session cascade first" "claude:opus" c

let test_cascade_default () =
  let pw = make_pw () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:[] pw in
  Alcotest.(check string) "default cascade" "keeper_turn" c

let test_cascade_empty_model_string () =
  let pw = make_pw ~spawn_model:(Some "") () in
  let c = Team_session_oas_bridge.cascade_of_worker
    ~session_cascade:["llama:qwen3.5"] pw in
  Alcotest.(check string) "empty model falls through" "llama:qwen3.5" c

(* ================================================================ *)
(* Supported tool runtime tests                                     *)
(* ================================================================ *)

let test_supported_local_worker_tools_present () =
  let schemas = Team_session_oas_bridge.supported_local_worker_tools () in
  let names =
    List.map (fun (schema : Types.tool_schema) -> schema.name) schemas
  in
  Alcotest.(check bool) "masc_status present" true
    (List.mem "masc_status" names);
  Alcotest.(check bool) "masc_code_read present" true
    (List.mem "masc_code_read" names);
  Alcotest.(check bool) "masc_run_init present" true
    (List.mem "masc_run_init" names)

let test_dispatch_supported_tool_status () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tmp = Filename.temp_dir "masc-test" "" in
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ok, message =
    Team_session_oas_bridge.dispatch_supported_tool
      ~sw ~clock:(Eio.Stdenv.clock env) ~config
      ~name:"masc_status"
      ~args:(`Assoc [("agent_name", `String "worker-status")])
  in
  Alcotest.(check bool) "status dispatch succeeded" true ok;
  Alcotest.(check bool) "status payload non-empty" true
    (String.length message > 0)

let test_dispatch_supported_tool_heartbeat_autojoin () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tmp = Filename.temp_dir "masc-test" "" in
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ok, _message =
    Team_session_oas_bridge.dispatch_supported_tool
      ~sw ~clock:(Eio.Stdenv.clock env) ~config
      ~name:"masc_heartbeat"
      ~args:(`Assoc [("agent_name", `String "worker-heartbeat")])
  in
  Alcotest.(check bool) "heartbeat dispatch succeeded" true ok;
  Alcotest.(check bool) "worker auto-joined" true
    (Room.is_agent_joined config ~agent_name:"worker-heartbeat")

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Team Session OAS Bridge" [
    "role_mapping", [
      Alcotest.test_case "worker_class executor" `Quick
        test_role_of_worker_class_executor;
      Alcotest.test_case "worker_class scout" `Quick
        test_role_of_worker_class_scout;
      Alcotest.test_case "worker_class none" `Quick
        test_role_of_worker_class_none;
      Alcotest.test_case "spawn_role verify" `Quick
        test_role_of_spawn_role_verify;
      Alcotest.test_case "spawn_role custom" `Quick
        test_role_of_spawn_role_custom;
      Alcotest.test_case "spawn_role none with worker_class" `Quick
        test_role_of_spawn_role_none_with_worker_class;
    ];
    "orchestration_mode", [
      Alcotest.test_case "manual -> supervisor" `Quick
        test_mode_manual;
      Alcotest.test_case "auto -> decentralized" `Quick
        test_mode_auto;
      Alcotest.test_case "assist -> supervisor" `Quick
        test_mode_assist;
    ];
    "cascade_resolution", [
      Alcotest.test_case "explicit model" `Quick
        test_cascade_explicit_model;
      Alcotest.test_case "session fallback" `Quick
        test_cascade_session_fallback;
      Alcotest.test_case "default cascade" `Quick
        test_cascade_default;
      Alcotest.test_case "empty model string" `Quick
        test_cascade_empty_model_string;
    ];
    "supported_tools", [
      Alcotest.test_case "schemas present" `Quick
        test_supported_local_worker_tools_present;
      Alcotest.test_case "status dispatch" `Quick
        test_dispatch_supported_tool_status;
      Alcotest.test_case "heartbeat autojoin" `Quick
        test_dispatch_supported_tool_heartbeat_autojoin;
    ];
  ]
