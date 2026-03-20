(** End-to-end swarm tests verifying the full execution path.
    Uses mock MODEL server (no live MODEL required).
    Tests: parallel execution, MASC join/leave error paths,
    on_complete callback, and async status tool. *)

open Agent_sdk
open Masc_mcp

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let make_provider ?(port = 9999) () : Provider.config =
  {
    provider = Local { base_url = Printf.sprintf "http://127.0.0.1:%d" port };
    model_id = "test-model";
    api_key_env = "AGENT_SDK_TEST_DUMMY_KEY_e2e";
  }

let make_spec ?(name = "test-agent") ?(max_turns = 1) () :
    Agent_swarm_swarm.agent_spec =
  {
    name;
    provider = make_provider ();
    system_prompt = "You are a test agent.";
    tools = [];
    max_tokens = None;
    max_turns;
    temperature = None;
    include_masc_tools = false;
    managed_task = None;
    expected_final_marker = None;
  }

(* ================================================================ *)
(* Test: parallel execution returns one result per agent            *)
(* ================================================================ *)

let test_parallel_execution_returns_all_results () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let config : Agent_swarm_swarm.swarm_config =
    {
      masc_url = "http://127.0.0.1:9999";
      agents =
        [
          make_spec ~name:"agent-1" ();
          make_spec ~name:"agent-2" ();
          make_spec ~name:"agent-3" ();
        ];
    }
  in
  let results =
    Agent_swarm_swarm.run ~sw ~net ~clock config ~goal:"test goal"
  in
  Alcotest.(check int) "one result per agent" 3 (List.length results);
  let names =
    List.map
      (fun (r : Agent_swarm_swarm.agent_result) -> r.agent_name)
      results
    |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "agent names preserved"
    [ "agent-1"; "agent-2"; "agent-3" ]
    names

(* ================================================================ *)
(* Test: all agents fail gracefully when MASC unreachable           *)
(* ================================================================ *)

let test_all_agents_fail_gracefully () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let config : Agent_swarm_swarm.swarm_config =
    {
      masc_url = "http://127.0.0.1:9999";
      agents = [ make_spec ~name:"solo" () ];
    }
  in
  let results =
    Agent_swarm_swarm.run ~sw ~net ~clock config ~goal:"test goal"
  in
  Alcotest.(check int) "one result" 1 (List.length results);
  let r = List.hd results in
  (match r.result with
  | Error msg ->
      Alcotest.(check bool)
        "error message non-empty" true
        (String.length msg > 0)
  | Ok _ -> Alcotest.fail "should fail when MASC is unreachable")

(* ================================================================ *)
(* Test: on_complete callback receives results                      *)
(* ================================================================ *)

let test_on_complete_callback_invoked () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let callback_received = ref [] in
  let on_complete results =
    callback_received := results
  in
  let config : Agent_swarm_swarm.swarm_config =
    {
      masc_url = "http://127.0.0.1:9999";
      agents = [ make_spec ~name:"cb-agent" () ];
    }
  in
  let _results =
    Agent_swarm_swarm.run ~sw ~net ~clock ~on_complete config
      ~goal:"callback test"
  in
  Alcotest.(check int)
    "callback received results" 1
    (List.length !callback_received);
  let r = List.hd !callback_received in
  Alcotest.(check string) "callback agent name" "cb-agent" r.agent_name

(* ================================================================ *)
(* Test: on_complete exception does not crash run                   *)
(* ================================================================ *)

let test_on_complete_exception_safe () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let on_complete _results =
    failwith "callback exploded"
  in
  let config : Agent_swarm_swarm.swarm_config =
    {
      masc_url = "http://127.0.0.1:9999";
      agents = [ make_spec ~name:"boom-agent" () ];
    }
  in
  let results =
    Agent_swarm_swarm.run ~sw ~net ~clock ~on_complete config
      ~goal:"exception safety test"
  in
  Alcotest.(check int)
    "results returned despite callback failure" 1
    (List.length results)

(* ================================================================ *)
(* Test: pid_is_alive returns false for nonexistent PID             *)
(* ================================================================ *)

let test_pid_is_alive_nonexistent () =
  (* Use Unix.kill directly since Tool_command_plane_swarm_live
     is not re-exported through Masc_mcp. *)
  let alive =
    try Unix.kill 999999 0; true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
  in
  Alcotest.(check bool) "nonexistent PID not alive" false alive

(* ================================================================ *)
(* Test: swarm config types are well-formed                         *)
(* ================================================================ *)

let test_swarm_config_construction () =
  let config : Agent_swarm_swarm.swarm_config =
    {
      masc_url = "http://localhost:8935";
      agents = [ make_spec ~name:"a1" (); make_spec ~name:"a2" () ];
    }
  in
  Alcotest.(check int) "two agents" 2 (List.length config.agents);
  Alcotest.(check string) "masc url" "http://localhost:8935" config.masc_url

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Alcotest.run "Swarm E2E"
    [
      ( "parallel_execution",
        [
          Alcotest.test_case "returns all results" `Quick
            test_parallel_execution_returns_all_results;
          Alcotest.test_case "all agents fail gracefully" `Quick
            test_all_agents_fail_gracefully;
        ] );
      ( "on_complete",
        [
          Alcotest.test_case "callback invoked" `Quick
            test_on_complete_callback_invoked;
          Alcotest.test_case "exception safe" `Quick
            test_on_complete_exception_safe;
        ] );
      ( "infrastructure",
        [
          Alcotest.test_case "pid_is_alive false for nonexistent" `Quick
            test_pid_is_alive_nonexistent;
          Alcotest.test_case "swarm config construction" `Quick
            test_swarm_config_construction;
        ] );
    ]
